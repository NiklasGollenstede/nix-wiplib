dirname: inputs: moduleArgs@{ name, config, options, lib, pkgs, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.services.secrets;
    identityPath = config.environment.etc."ssh/ssh_host_ed25519_key".source or "/etc/ssh/ssh_host_ed25519_key";
    esc = lib.escapeShellArg;
in {

    # If the top-level flake does not explicitly use `agenix`, add its nixosModule and overlay from our own inputs.
    # If it uses `agenix` and passes it along, we do nothing.
    # If it uses `agenix` and without passing it along, adding the module/overlay here has no effect iff our input is the same (via `follows`).
    imports = if moduleArgs?inputs.agenix then [ ] else [ inputs.agenix.nixosModules.default /* (lib.mkIf cfg.enable { nixpkgs.overlays = lib.mkBefore [ inputs.agenix.overlays.default ]; }) */ ];

    options.${prefix} = { services.secrets = {
        enable = (lib.mkEnableOption "handling of secrets via agenix. This should usually not be enabled in containers") // { example = lib.literalExpression "!config.boot.isContainer"; };
        include = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; example = [ "wg/.*@<name>" "ssh/service/.*@<name>" ]; description = ''
            List of regular expressions. `.age` files in `.secretsDir` whose relative path is matched by any of these are considered required for the current host. They therefore will be configured to be decrypted by it and to be accessible in its configuration. By default, the `secrets` CLI command will also know to encrypt the matched secrets for decryption by this host (when editing or re-keying).
        ''; };
        secretsDir = lib.mkOption { type = lib.types.strMatching "^[^/].*[^/]$"; default = "secrets"; description = ''
            Relative path in the top-level flake that (is to) contain encrypted `.age` files (and related `.pub`lic keys).
        ''; };
        rootKeyEncrypted = lib.mkOption { type = lib.types.nullOr (lib.types.strMatching "^[^/].*[^/]$"); default = null; example = "ssh/host/host@<name>"; description = ''
            Relative path in `.secretsDir` of the secret file that holds this host's private root decryption key.
            This can usually only be decrypted with an admin identity, usually during host installation.
            `config.installer.scripts.init-secrets` deploys this to `lib.head config.age.identityPaths` during installation.
        ''; };
        rootKeyExtraOwners = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; example = "ssh/host/host@<name>"; description = ''
            Values of additional public keys to decrypt the `.rootKeyEncrypted` file with. Useful for example when one host needs to be able install/deploy/launch another that is not necessarily permanent part of the same configuration.
        ''; };
        secretsPath = lib.mkOption { type = lib.types.path; readOnly = true; description = ''
            Content-addressed copy of the `.secretsDir`, to be used when integrating encrypted secrets (or their accompanying (unencrypted) public keys) into the config.
        '';};
        appName = lib.mkOption { type = lib.types.str; default = "secrets"; description = ''
            Name (or absolute output path) as which the flake that defines the system exports the secrets management app. If defined, this has to match the »appName« argument to »lib.${prefix}.mkSecretsApp { ... }«.
        '';};
    }; };

    config = lib.mkIf cfg.enable ({

        age.secrets = lib.mkIf (cfg.include != [ ]) (lib.genAttrs (map (lib.removeSuffix ".age") (
            builtins.filter (file: lib.hasSuffix ".age" file && (
                (builtins.match "(${cfg.secretsDir}/)?(${lib.concatStringsSep "|" cfg.include})(.age)?" "${cfg.secretsDir}/${file}") != null
            )) (lib.wip.listDirRecursive "${cfg.secretsPath}" "")
        )) (file': { file = "${cfg.secretsPath}/${file'}.age"; }));

        ${prefix}.services.secrets.secretsPath = lib.mkOptionDefault (
            let path = "${moduleArgs.inputs.self}/${cfg.secretsDir}"; in if ! builtins.pathExists path then pkgs.emptyDirectory else
            builtins.path { path = "${moduleArgs.inputs.self}/${cfg.secretsDir}"; name = "secrets"; } # create a content-addressed copy so that secrets' paths won't change every time _anything_ about the configuration changes
        );

        # default to using the root decryption key as SSH host key (or vice versa):
        age.identityPaths = lib.mkDefault [ identityPath ];
        # and then don't generate any other SSH host keys:
        services.openssh.hostKeys = lib.mkDefault [ { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; } ]; # (given this, modules/setup/temproot.nix.md sets a symlink in config.environment.etc)
        services.openssh.generateHostKeys = lib.mkDefault false;

        installer.scripts.init-secrets = { path = "${inputs.self}/lib/installer-secrets.sh"; };
        installer.commands.prepareInstaller = ''prepare-installer--secrets'';
        installer.commands.postMount = ''post-mount--secrets'';

        # Pass the root decryption key into VMs:
        virtualisation = lib.optionalAttrs ((options.virtualisation?credentials) && (moduleArgs?inputs)) (lib.mkIf (cfg.rootKeyEncrypted != null) {
            credentials.${utils.escapeSystemdPath identityPath} = { source = let
                #app = "nix --extra-experimental-features 'nix-command flakes' run ${moduleArgs.inputs.self}'#'${esc cfg.appName} --";
                split = lib.splitString "." cfg.appName;
                path = if lib.head split == "" then lib.tail split else [ "apps" config.virtualisation.host.pkgs.stdenv.hostPlatform.system ] ++ split ++ [ "program"];
                app = lib.attrByPath path (throw "inputs.self.${lib.concatStringsSep "." path} not found") moduleArgs.inputs.self;
            in "'${''<(
                ${app} --repo=${moduleArgs.inputs.self} ''${AGENIX_IDENTITY:+ --identity "$AGENIX_IDENTITY" } decrypt::${esc cfg.secretsDir}/${esc cfg.rootKeyEncrypted}.age || { echo "Failed to decrypt root key" >/dev/stderr; kill $$ ; }
            )''}'"; };
        });
        # The restore service has to run before agenix runs. "Traditionally" agenix runs during system activation, so that secrets can be used during user file generation (later in the activation). As activation on boot happens at the end of the initrd phase, that would mean to run the restore service in the initrd. However, systemd-creds does not work in the initrd (https://github.com/NixOS/nixpkgs/issues/475305), so we we can't support systems with legacy user file generation.
        # With systemd-sysusers and userborn run as (post initrd) systemd services, and static user generation can't access secrets at all. So for those cases, we can run in the real system:
        systemd.services.restore-age-identity = lib.mkIf (cfg.rootKeyEncrypted != null){
            description = "Restore Age-Nix Identities";
            wantedBy = [ "sysinit.target" ]; before = (lib.optional (config.systemd.sysusers.enable) "systemd-sysusers.service") ++ (lib.optional (config.services.userborn.enable && !config.services.userborn.static) "userborn.service") ++ [ "agenix-install-secrets.service" ];
            unitConfig = {
                ConditionFileNotEmpty = "|!${identityPath}";
                RequiresMountsFor = builtins.dirOf identityPath;
            };
            serviceConfig = { Type = "oneshot"; };
            script = ''
                mkdir -p "$( dirname ${esc identityPath} )"
                : >${esc identityPath} ; chmod 600 ${esc identityPath}
                systemd-creds --system cat ${utils.escapeSystemdPath identityPath} >${esc identityPath}
            '';
        };

    });
}
