/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ options, config, pkgs, lib, modulesPath, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix; inherit (inputs.installer.inputs.config.rename) installer;
    cfg = config.${prefix}.base;
    nixosVersion = lib.strings.fileContents "${modulesPath}/../../.version"; # (accurate and can be used for imports)
    outputName = config.${installer}.outputName;
    byDefault = { default = true; example = false; };
    ifKnowsSelf = { default = outputName != null && cfg.includeInputs?self.nixosConfigurations.${outputName}; defaultText = lib.literalExpression "config.${prefix}.base.includeInputs?self.nixosConfigurations.\${config.${prefix}.installer.outputName}"; example = false; };
in {

    options.${prefix} = { base = {
        enable = lib.mkEnableOption "saner defaults";
        includeInputs = lib.mkOption { description = "The system's build inputs, to be included in the flake registry, and on the »NIX_PATH« entry, such that they are available for self-rebuilds and e.g. as »pkgs« on the CLI."; type = lib.types.attrsOf lib.types.anything; apply = lib.filterAttrs (k: v: v != null); default = let
            inputs = moduleArgs.inputs or config._module.args.inputs;
        in (
            if (!config.nix.enable) then { }
            else if config.boot.isContainer then builtins.removeAttrs inputs [ "self" ] # avoid changing (and thus restarting) the containers on every trivial change
            else if inputs?self.outputs.outPath then inputs // { self = inputs.self // { outPath = inputs.self.outputs.outPath; }; } # see inputs.functions.lib.imports.importRepo
            else { }
        ); };
        selfInputName = lib.mkOption { description = "name of »config.${prefix}.base.includeInputs.self« flake"; type = lib.types.str; default = "nixos-config"; };
        panic_on_fail = lib.mkEnableOption "Kernel parameter »boot.panic_on_fail«" // byDefault; # It's stupidly hard to remove items from lists ...
        showDiffOnActivation = lib.mkEnableOption "showing a diff compared to the previous system on activation of this new system (generation)" // byDefault;
        autoUpgrade = lib.mkEnableOption "automatic NixOS updates and garbage collection" // ifKnowsSelf;
        bashInit = lib.mkEnableOption "pretty defaults for interactive bash shells" // byDefault;
    }; };

    config = lib.mkIf cfg.enable (lib.mkMerge [ (
        lib.optionalAttrs (options.nix.channel?enable) { nix.channel.enable = lib.mkDefault false; }
    ) ({
        users.mutableUsers = false; users.allowNoPasswordLogin = true; # Don't babysit. Can roll back or redeploy.
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = lib.mkDefault (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # Needs to exist (but may be empty) for systemd not to consider this a fresh installation ("first boot"). Also, is used as identifier in logs (vs. containers/VMs). This works, but it "should be considered "confidential", and must not be exposed in untrusted environments". Guess containers/VMs could send fake host system logs?
        documentation.man.enable = lib.mkDefault config.documentation.enable;

        ## Nix
        nix.settings.auto-optimise-store = lib.mkDefault true; # file deduplication, see https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-store-optimise.html#description
        nix.settings.experimental-features = [ "nix-command" "flakes" ]; # We will probably not ever get rid of these flags.
        programs.git.enable = lib.mkIf config.nix.enable (lib.mkDefault true); # Necessary as external dependency when working with flakes.
        nix.settings.ignore-try = lib.mkDefault true; # »nix --debugger« will not break on errors in »try« branches. Use »--option ignore-try false« on the CLI to revert this.
        nix.settings.flake-registry = lib.mkDefault ""; # Disable the global (online) flake registry.
        nix.settings.allow-dirty-locks = lib.mkDefault true; # Allow locking (and having locked) local inputs. Requires external tooling opr the user to ensure that the locked inputs are present in the store.
        nix.settings.tarball-ttl = lib.mkDefault 0; # Flakes('s inputs) should only be updated when asked explicitly, but then always. ("0 forces Nix to always check")
        #nixpkgs.config.warnUndeclaredOptions = lib.mkDefault true; # warn on undeclared nixpkgs.config.*

        ## Boot
        hardware.cpu = lib.mkIf (pkgs.system == "x86_64-linux") (let
            updateMicrocode = lib.mkOverride 900 { updateMicrocode = true; }; # (enable this even of »config.hardware.enableRedistributableFirmware == false«, but still allow overriding it without force)
        in { amd = updateMicrocode; intel = updateMicrocode; }); # (seems to be perfectly fine to enable both: kernel extracts both and picks the correct one)
        boot.initrd.systemd.enable = lib.mkIf (!config.boot.isContainer) (lib.mkDefault true);
        boot.loader.timeout = lib.mkDefault 1; # save 4 seconds on startup
        boot.kernelParams = lib.mkBefore ([ "panic=10" ] ++ (lib.optional cfg.panic_on_fail "boot.panic_on_fail")); # Reboot on kernel panic (showing the printed messages for 10s), panic if boot fails. »boot.panic_on_fail« also applies to systemd-initrd.
        #boot.kernelParams = [ "systemd.debug_shell" ]; # This is supposed to enable the service (included with systemd) that opens a root shell on tty9. This seems to only work in Stage 2.
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
    }) (if nixosVersion >= "25.11" then { # Show unit names instead of descriptions in systemctl status output and during boot.
        systemd.settings.Manager.StatusUnitFormat = lib.mkDefault "name"; boot.initrd.systemd.settings.Manager.StatusUnitFormat = lib.mkDefault "name";
    } else {
        systemd.extraConfig = "StatusUnitFormat=name"; boot.initrd.systemd.extraConfig = "StatusUnitFormat=name";
    }) ({
        services.getty.helpLine = lib.mkForce "";
        systemd.services.rtkit-daemon = lib.mkIf (config.security.rtkit.enable) { serviceConfig.LogLevelMax = lib.mkDefault "warning"; }; # spams, and probably irrelevant

        boot.kernel.sysctl = {
            # implicit default (Linux 6.6, 40GB) is 128 (or 8192?)
            "fs.inotify.max_user_instances" = lib.mkOptionDefault 524288;
            # "fs.inotify.max_user_watches" is set to min(1%RAM, 1mil) on Linux 5.12+
            # "fs.inotify.max_user_watches" = lib.mkDefault 524288;
        };

        system.extraSystemBuilderCmds = lib.mkIf config.boot.initrd.enable ''
            ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
        ''; # (to deactivate this, set »system.extraSystemBuilderCmds = lib.mkAfter "rm -f $out/boot-stage-1.sh";«)

        wip.base.showDiffOnActivation = lib.mkIf (!config.nix.enable) (lib.mkDefault true);
        system.activationScripts.diff-systems = lib.mkIf cfg.showDiffOnActivation { text = ''
            if [[ -e /run/current-system && -e $systemConfig/sw/bin/nix && $(realpath /run/current-system) != "$systemConfig" ]] ; then
                ${pkgs.nvd}/bin/nvd --nix-bin-dir=$systemConfig/sw/bin diff /run/current-system "$systemConfig"
                #$systemConfig/sw/bin/nix --extra-experimental-features nix-command store diff-closures /run/current-system "$systemConfig"
            fi
        ''; deps = [ "etc" ]; };

        environment.ldso32 = null; # Don't install the /lib/ld-linux.so.2 stub. This saves one instance of nixpkgs.

        virtualisation = lib.fun.mapMerge (vm: { ${vm} = let
            config' = config.virtualisation.${vm};
        in {
            virtualisation.graphics = lib.mkDefault false;
            virtualisation.writableStore = lib.mkDefault false;

            # BUG(PR): When removing all device definitions, also don't use the »resumeDevice«:
            boot.resumeDevice = lib.mkIf (!config'.virtualisation?useDefaultFilesystems || config'.virtualisation.useDefaultFilesystems) (lib.mkVMOverride "");

        }; }) [ "vmVariant" "vmVariantWithBootLoader" "vmVariantExec" ];


    }) (lib.mkIf (cfg.includeInputs != { }) { # flake things

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

        # TODO: gc should depend on upgrade: That will always keep a configuration that has can perform upgrades (i.e., has internet access).

        system.autoUpgrade = {
            enable = lib.mkDefault true; channel = null;
            dates = lib.mkDefault "05:40"; randomizedDelaySec = lib.mkDefault "30min";
            allowReboot = lib.mkDefault false;
            flake = "."; # $flakePath#${config.${installer}.outputName}
            #flags = [ "--no-update-lock-file" ];
        };

        systemd.services.nixos-upgrade.script = let
            # Older versions of Nix (<2.20?) would update indirect inputs from the local flake registry (which points into the store) and would simply use existing store paths when nothing needed to be updated.
            # Newer versions first refused to do the registry lookup, and then started fetching inputs into the "Git cache" even if, according to their pinned narHash, they clearly already exist in the store.
            # The latter is not only slow, but may (completely unnecessarily) fail if the input can't be fetched, for example because it was "indirect" and redirected to a local repo.
            # This attempts to work around that by:
            # * telling Nix to update everything that is not "indirect" (tho the current solution will/can only update direct inputs), and
            # * removing all information other than the narHash from "indirect" inputs where Nix would fail to fetch them to add them to the pointless cache.
            lock = if cfg.includeInputs?self then lib.importJSON "${cfg.includeInputs.self}/flake.lock" else { nodes.root.inputs = [ ]; };
            to-update = lib.remove null (lib.mapAttrsToList (input: alias: if lock.nodes.${alias}.original.type != "indirect" then input else null) lock.nodes.root.inputs);
            #to-update = lib.filter (input: lock.nodes.${input}.locked?rev) lock.nodes.root;
            # github, git+ssh, git+https, https(flakehub) all set a "rev"; but git+file (which could not be updated) also does if the tree was clean
            newLock = builtins.toJSON {
                inherit (lock) version; root = "root";
                nodes = (lib.mapAttrs (k: dep: dep // (lib.optionalAttrs ((dep.original.type or null) == "indirect") {
                    # pretend all inputs were clean, cuz otherwise current (~v2.28) Nix versions fail
                    locked = { inherit (dep.locked) narHash; type = "tarball"; url = "file:///dev/null"; };
                    # (all inputs' paths are prevented from being GCed above)
                })) lock.nodes);
            };
        in (lib.mkMerge [ (lib.mkBefore ''
            # Make flakePath writable and a repo if necessary:
            flakePath=${lib.escapeShellArg config.environment.etc.nixos.source}
            if [[ -e $flakePath/flake.lock && ! -w $( realpath "$flakePath" )/flake.lock ]] ; then
                flakePath=$( realpath "$flakePath" )
                dir= ; if [[ $flakePath == /nix/store/*/* ]] ; then
                    dir="''${flakePath#/nix/store/*/}"
                fi
                tmpdir=$( mktemp -d --tmpdir -- ${lib.escapeShellArg cfg.selfInputName}.XXXXXXXXXX ) && trap "rm -rf $tmpdir" EXIT || exit
                cp -dr -T "$( realpath "''${flakePath%$dir}" )" "$tmpdir" && chmod +w "$tmpdir"/"$dir"/flake.lock || exit
                if [[ $dir ]] ; then
                    ( cd "$tmpdir" && git init --quiet && git add --all ) || exit
                    flakePath=$tmpdir/"$dir" # git+file://$tmpdir?dir="$dir"
                else
                    flakePath=$tmpdir # path://$tmpdir
                fi
                ${lib.optionalString (cfg.includeInputs?self) ''
                    printf %s ${lib.escapeShellArg newLock} > "$flakePath"/flake.lock || exit
                ''}
            fi
            cd "$flakePath" || exit

            # This (implicitly passing »--flake«) requires nix.version > 2.18:
            nix --extra-experimental-features 'nix-command flakes' flake update ${lib.escapeShellArgs to-update} || failed=$?
            # (Since all inputs to the system flake are linked as system-level flake registry entries, even "indirect" references that don't really exist on the target can be "updated" (which keeps the same hash but changes the path to point directly to the nix store).)
            if [[ ''${failed:-} ]] ; then echo >&2 'Updating (some) inputs failed' ; fi
        '') (lib.mkAfter ''
            if [[ ''${failed:-} ]] ; then exit $failed ; fi
        '') ]);

        # TODO: reboots

    }) ({

        # (almost) Free Convenience:
        ${prefix}.profiles.bash.enable = lib.mkIf (cfg.bashInit) true;


    }) ]);

}
