dirname: inputs: moduleArgs@{ name, config, lib, pkgs, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.services.secrets;
in {

    # If the top-level flake does not explicitly use `agenix`, add its nixosModule and overlay from our own inputs.
    # If it uses `agenix` and passes it along, we do nothing.
    # If it uses `agenix` and without passing it along, adding the module/overlay here has no effect iff our input is the same (via `follows`).
    imports = if moduleArgs?inputs.agenix then [ ] else [ inputs.agenix.nixosModules.default { nixpkgs.overlays = lib.mkBefore [ inputs.agenix.overlays.default ]; } ];

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
            Content-addressed copy of the `.secretsDir`, to be used when integrating (encrypted) secrets (or their accompanying public keys) into the config.
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
        age.identityPaths = lib.mkDefault [ (config.environment.etc."ssh/ssh_host_ed25519_key".source or "/etc/ssh/ssh_host_ed25519_key") ];
        # and then don't generate any other SSH host keys:
        services.openssh.hostKeys = lib.mkDefault [ { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; } ];

        installer.scripts.init-secrets = { path = "${inputs.self}/lib/installer-secrets.sh"; };
        installer.commands.prepareInstaller = ''prepare-installer--secrets'';
        installer.commands.postMount = ''post-mount--secrets'';

    });
}
