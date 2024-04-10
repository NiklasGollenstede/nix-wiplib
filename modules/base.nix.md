/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix; inherit (inputs.installer.inputs.config.rename) installer;
    cfg = config.${prefix}.base;
    outputName = config.${installer}.outputName;
    byDefault = { default = true; example = false; };
    ifKnowsSelf = { default = outputName != null && cfg.includeInputs?self.nixosConfigurations.${outputName}; defaultText = lib.literalExpression "config.${prefix}.base.includeInputs?self.nixosConfigurations.\${config.${prefix}.installer.outputName}"; example = false; };
in {

    options.${prefix} = { base = {
        enable = lib.mkEnableOption "saner defaults";
        includeInputs = lib.mkOption { description = "The system's build inputs, to be included in the flake registry, and on the »NIX_PATH« entry, such that they are available for self-rebuilds and e.g. as »pkgs« on the CLI."; type = lib.types.attrsOf lib.types.anything; apply = lib.filterAttrs (k: v: v != null); default = let
            inputs = moduleArgs.inputs or config._module.args.inputs;
        in ((
            if config.boot.isContainer then builtins.removeAttrs inputs [ "self" ] else inputs # avoid changing (and thus restarting) the containers on every trivial change
        ) // (
            if inputs?self.outputs.outPath then { self = inputs.self // { outPath = inputs.self.outputs.outPath; }; } else { } # see inputs.functions.lib.imports.importRepo
        )); };
        selfInputName = lib.mkOption { description = "name of »config.${prefix}.base.includeInputs.self« flake"; type = lib.types.str; default = "nixos-config"; };
        panic_on_fail = lib.mkEnableOption "Kernel parameter »boot.panic_on_fail«" // byDefault; # It's stupidly hard to remove items from lists ...
        showDiffOnActivation = lib.mkEnableOption "showing a diff compared to the previous system on activation of this new system (generation)" // byDefault;
        autoUpgrade = lib.mkEnableOption "automatic NixOS updates and garbage collection" // ifKnowsSelf;
        bashInit = lib.mkEnableOption "pretty defaults for interactive bash shells" // byDefault;
    }; };

    imports = lib.optional ((builtins.substring 0 5 inputs.nixpkgs.lib.version) <= "22.05") (lib.fun.overrideNixpkgsModule "misc/extra-arguments.nix" { } (old: { config._module.args.utils = old._module.args.utils // {
        escapeSystemdPath = s: let n = builtins.replaceStrings [ "/" "-" " " ] [ "-" "\\x2d" "\\x20" ] (lib.removePrefix "/" s); in if lib.hasPrefix "." n then "\\x2e" (lib.substring 1 (lib.stringLength (n - 1)) n) else n; # (a better implementation has been merged in 22.11)
    }; }));

    config = let

    in lib.mkIf cfg.enable (lib.mkMerge [ (
        lib.optionalAttrs (options.nix.channel?enable) { nix.channel.enable = lib.mkDefault false; }
    ) ({
        users.mutableUsers = false; users.allowNoPasswordLogin = true; # Don't babysit. Can roll back or redeploy.
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = lib.mkDefault (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # this works, but it "should be considered "confidential", and must not be exposed in untrusted environments" (not sure _why_ though)
        documentation.man.enable = lib.mkDefault config.documentation.enable;
        nix.settings.auto-optimise-store = lib.mkDefault true; # file deduplication, see https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-store-optimise.html#description
        nix.settings.ignore-try = lib.mkDefault true; # Use »--option ignore-try false« on the CLI to revert this.
        boot.loader.timeout = lib.mkDefault 1; # save 4 seconds on startup
        boot.kernelParams = [ "panic=10" ] ++ (lib.optional cfg.panic_on_fail "boot.panic_on_fail"); # Reboot on kernel panic (showing the printed messages for 10s), panic if boot fails.
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
        systemd.extraConfig = "StatusUnitFormat=name"; boot.initrd.systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.
        services.getty.helpLine = lib.mkForce "";
        systemd.services.rtkit-daemon = lib.mkIf (config.security.rtkit.enable) { serviceConfig.LogLevelMax = lib.mkDefault "warning"; }; # spams, and probably irrelevant

        system.extraSystemBuilderCmds = lib.mkIf config.boot.initrd.enable ''
            ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
        ''; # (to deactivate this, set »system.extraSystemBuilderCmds = lib.mkAfter "rm -f $out/boot-stage-1.sh";«)

        system.activationScripts.diff-systems = lib.mkIf cfg.showDiffOnActivation { text = ''
            if [[ -e /run/current-system && -e $systemConfig/sw/bin/nix && $(realpath /run/current-system) != "$systemConfig" ]] ; then $systemConfig/sw/bin/nix --extra-experimental-features nix-command store diff-closures /run/current-system "$systemConfig" ; fi
        ''; deps = [ "etc" ]; };

        virtualisation = lib.fun.mapMerge (vm: { ${vm} = let
            config' = config.virtualisation.${vm};
        in {
            virtualisation.graphics = lib.mkDefault false;
            virtualisation.writableStore = lib.mkDefault false;

            # BUG(PR): When removing all device definitions, also don't use the »resumeDevice«:
            boot.resumeDevice = lib.mkIf (!config'.virtualisation?useDefaultFilesystems || config'.virtualisation.useDefaultFilesystems) (lib.mkVMOverride "");

        }; }) [ "vmVariant" "vmVariantWithBootLoader" "vmVariantExec" ];


    }) (lib.mkIf (cfg.includeInputs != { }) { # flake things

        # "input" to the system build is definitely also a nix version that works with flakes:
        nix.settings.experimental-features = [ "nix-command" "flakes" ]; # apparently, even nix 2.8 (in nixos-22.05) needs this
        environment.systemPackages = [ pkgs.git ]; # necessary as external dependency when working with flakes

        # »inputs.self« does not have a name (that is known here), so just register it as »/etc/nixos/« system config:
        environment.etc.nixos = lib.mkIf (cfg.includeInputs?self) (lib.mkDefault { source = "/run/current-system/config"; }); # (use this indirection to prevent every change in the config to necessarily also change »/etc«)
        system.extraSystemBuilderCmds = lib.mkIf (cfg.includeInputs?self) ''
            ln -sT ${cfg.includeInputs.self} $out/config # (build input for reference)
        '';

        # Add all (direct) inputs to the flake registry:
        nix.registry = lib.mapAttrs (name: input: lib.mkDefault { to = lib.wip.toFlakeRef input; }) (
            (lib.optionalAttrs (cfg.includeInputs?self) { ${cfg.selfInputName} = cfg.includeInputs.self; })
            // (builtins.removeAttrs cfg.includeInputs [ "self" ])
        );
        system.extraDependencies = let # Make sure to also depend on nested inputs, to ensure they are already available in the host's nix store (in case the source identifiers don't resolve in the context of the host).
            getInputs = flake: [ flake ] ++ (map getInputs (lib.attrValues (flake.inputs or { })));
        in map (input: {
            type = "derivation"; outPath = toString input; # required when using newer versions of Nix (~1.14+) with older versions of nixpkgs (pre 23.05?)
        }) (lib.flatten (map getInputs (lib.attrValues cfg.includeInputs)));


    }) (lib.mkIf (ifKnowsSelf.default) {

        nix.syspkgs.enable = true;
        nix.syspkgs.hostName = outputName;
        nix.syspkgs.nixos-config.name = cfg.selfInputName;
        nix.syspkgs.nixos-config.flake = cfg.includeInputs.self;


    }) (lib.mkIf (cfg.autoUpgrade) {

        nix.gc = { # gc everything older than 30 days, before updating
            automatic = lib.mkDefault true;
            options = lib.mkDefault "--delete-older-than 30d";
            dates = lib.mkDefault "Sun *-*-* 03:15:00";
        };
        nix.settings = { keep-outputs = true; keep-derivations = true; }; # don't GC build-time dependencies

        system.autoUpgrade = {
            enable = lib.mkDefault true; channel = null;
            flake = "$flakePath#${config.${installer}.outputName}";
            flags = map (dep: if dep == "self" then "" else "--update-input ${dep}") (builtins.attrNames cfg.includeInputs); # there is no "--update-inputs"
            # (Since all inputs to the system flake are linked as system-level flake registry entries, even "indirect" references that don't really exist on the target can be "updated" (which keeps the same hash but changes the path to point directly to the nix store).)
            dates = lib.mkDefault "05:40"; randomizedDelaySec = lib.mkDefault "30min";
            allowReboot = lib.mkDefault false;
        };

        systemd.services.nixos-upgrade.script = lib.mkBefore ''
            # Make flakePath writable and a repo if necessary:
            flakePath=${lib.escapeShellArg config.environment.etc.nixos.source}
            if [[ -e $flakePath/flake.lock && ! -w $( realpath "$flakePath" )/flake.lock ]] ; then
                flakePath=$( realpath "$flakePath" )
                dir= ; if [[ $flakePath == /nix/store/*/* ]] ; then
                    dir=''${flakePath#/nix/store/*/}
                fi
                tmpdir=$( mktemp -d --tmpdir -- ${lib.escapeShellArg cfg.selfInputName}.XXXXXXXXXX ) && trap "rm -rf $tmpdir" EXIT &&
                cp -dr -T "$( realpath "''${flakePath%$dir}" )" "$tmpdir" ; chmod +w "$tmpdir"/"$dir"/flake.lock
                if [[ $dir ]] ; then
                    ( cd "$tmpdir" ; git init --quiet ; git add --all )
                    flakePath=git+file://$tmpdir?dir=$dir
                else
                    flakePath=path://$tmpdir
                fi
            fi
        '';

    }) ({

        # (almost) Free Convenience:
        ${prefix}.profiles.bash.enable = lib.mkIf (cfg.bashInit) true;

    }) ]);

}
