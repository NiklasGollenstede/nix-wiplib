/*

# The system's `pkgs` for the CLI, accurately

Make `nixpkgs`/`pkgs`, exactly as configured, applied with overlays, and otherwise modified during the current system's build process, available to the system's `nix` CLI as `syspkgs`(`.legacyPackages`).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }@moduleArgs: let lib = inputs.self.lib.__internal__; in let
    cfg = config.nix.syspkgs;
in {

    options = { nix.syspkgs = {
        enable = lib.mkEnableOption ''
            making `nixpkgs`/`pkgs`, exactly as configured, applied with overlays, and otherwise modified during the current system's build process, available to the system's (flake-based) `nix` CLI as `syspkgs`(`.legacyPackages`).
            For flake-defined systems only. This makes the system depend on all it's evaluation flake inputs.
            An additional (`legacyPackages.`)`unfree` exposes `pkgs` with `config.allowUnfree = true`. `bad` additionally also allows using packages that are marked as insecure, unsupported-system, or broken.
            This works ell together with the `with` shell alias/function.

            Usage examples:
            `nix run syspkgs#patched-prog`
            `nix run syspkgs#added-package`
            `nix run syspkgs#unfree.google-chrome`
            `nix run syspkgs#bad.python27`
            `with patched-prog unfree.google-chrome bad.python27 -- python ./...`
        '';
        legacy = lib.mkOption { description = ''
            Also make `nixpkgs`/`pkgs`, exactly as configured, applied with overlays, and otherwise modified during the current system's build process, available as `nixpkgs=` on the `NIX_PATH`, so that it can be used in legacy/non-flake nix CLI calls and programs.
            This still requires the system to be configured as a flake.
        ''; type = lib.types.bool; default = true; };
        hostName = lib.mkOption { description = ''The name of this systems configuration as attribute of `''${nixos-config.flake}#nixosConfigurations`.''; type = lib.types.str; defaultText = config.networking.hostName; };
        nixos-config.flake = lib.mkOption { description = ''
            The flake that this system is configured in. This should be `inputs.self`, or something equivalent.
        ''; type = lib.types.package; defaultText = lib.literalMD ''`config._module.args.inputs.self`, if set''; };
        nixos-config.name = lib.mkOption { description = ''
            The name of `.flake`. Defaults to `nixos-config` and can be changed for vanity or if a (transitive) input of `.flake` is already named `nixos-config`.
        ''; type = lib.types.strMatching "[a-zA-Z_][a-zA-Z0-9_'-]*"; defaultText = "nixos-config"; };
    }; };

    config = lib.mkIf (cfg.enable) {
        nix.syspkgs.nixos-config.flake = lib.mkIf (config?_module.args.inputs.self || moduleArgs?inputs.self) (lib.mkOptionDefault (config._module.args.inputs.self or moduleArgs.inputs.self));

        nix.registry = { syspkgs.flake = pkgs.runCommandLocal "syspkgs" {
            flake_nix = ''{ outputs = { ${cfg.nixos-config.name}, ... }: { # (no need to say how to get this, because it will already be in the store)
                legacyPackages.${lib.strings.escapeNixIdentifier pkgs.system} = let
                    system = ${cfg.nixos-config.name}.nixosConfigurations.${lib.strings.escapeNixIdentifier cfg.hostName};
                in system.pkgs // { # (this is probably slower than `import nixpkgs { }`, since it partially evaluates the system configuration as well)
                    # This allows you to use unfree packages (and individually acknowledge their "unfree" nature) on the CLI:
                    unfree = (system.extendModules { modules = [ { nixpkgs.config.allowUnfree = true; } ]; }).pkgs; # (using packages from the base package set and this one will cause two evaluations)
                    # This allows you to use bad packages (broken, insecure, unsupported platform) on the CLI:
                    bad = (system.extendModules { modules = [ { nixpkgs.config = { allowUnfree = true; allowInsecurePredicate = _: true; allowUnsupportedSystem = true; allowBroken = true; }; } ]; }).pkgs; # (using packages from the base package set and this one will cause two evaluations)
                };
            }; }'';
            flake_lock = let
                lock = lib.importJSON "${cfg.nixos-config.flake}/flake.lock";
            in if lock.nodes?${cfg.nixos-config.name} then
                throw ''`config.nix.syspkgs.nixos-config.flake`'s lockfile already has an entry `${cfg.nixos-config.name}`. (Change `config.nix.syspkgs.nixos-config.name` to something else.)''
            else builtins.toJSON {
                inherit (lock) version; root = "root";
                nodes = (lib.mapAttrs (k: dep: dep // (lib.optionalAttrs (dep?inputs) {
                    # all "follows" are relative to the previous root, so the new name of that needs t be prepended to all follows-paths
                    inputs = lib.mapAttrs (k: ref: if lib.isString ref then ref else [ cfg.nixos-config.name ] ++ ref) dep.inputs;
                })) lock.nodes) // {
                    ${cfg.nixos-config.name} = { # this was the "root"
                        inputs = lock.nodes.root.inputs; original = { id = cfg.nixos-config.name; type = "indirect"; };
                        locked = lib.wip.toFlakeRef cfg.nixos-config.flake;
                    };
                    root.inputs = { ${cfg.nixos-config.name} = cfg.nixos-config.name; };
                };
            };
        } ''
            mkdir $out
            <<<"$flake_nix" cat > $out/flake.nix
            <<<"$flake_lock" cat > $out/flake.lock
        ''; };

        environment.etc = lib.mkIf cfg.legacy ({ "nix/nixpkgs/default.nix".text = ''
            # Provide the exact same version (except for modifications by »args«) of (nix)pkgs on the CLI as in the NixOS-configuration (this may be quite a bit slower than merely »import inputs.nixpkgs«, as it partially evaluates the host's configuration):
            let
                system = (builtins.getFlake ${builtins.toJSON "${cfg.nixos-config.flake}"}).nixosConfigurations.${lib.strings.escapeNixIdentifier cfg.hostName};
                nixpkgs = import ${builtins.toJSON "${cfg.nixos-config.flake.inputs.nixpkgs}"};
            in args: if !(builtins?getFlake) then nixpkgs args else if args == { } then system.pkgs else nixpkgs (args // {
                config = system.config.nixpkgs.config // (args.config or { }); # TODO: some better merging logic on this would be nice
                overlays = system.config.nixpkgs.overlays ++ (args.overlays or [ ]);
            })
            # args: (system.extendModules { modules = [ { config.nixpkgs = args; _file = "<nixpkgs-args>"; } ]; }).pkgs # this has marginally better merging logic for `args.config`, but also changes the interpretation of `args`
        ''; } // {
            "nix/nixpkgs/lib".source = "${cfg.nixos-config.flake.inputs.nixpkgs}/lib"; # some legacy Nix code may import <nixpkgs/lib>
            "nix/nixpkgs/pkgs".source = "${cfg.nixos-config.flake.inputs.nixpkgs}/pkgs"; # ... which imports this
            "nix/nixpkgs/nixos".source = "${cfg.nixos-config.flake.inputs.nixpkgs}/nixos"; # also import <nixpkgs/nixos>
        });

        nix.settings.nix-path = lib.mkIf (cfg.legacy && !(config.nix.channel?enable && config.nix.channel.enable)) [
            # This seems to take precedence over »nix.nixPath«, and it is is set if »!config.nix.channel.enable«.
            "nixpkgs=/etc/nix/nixpkgs" # (here, this could directly point to the nix file)
        ];
        nix.nixPath = lib.mkIf (cfg.legacy && (config.nix.channel?enable && config.nix.channel.enable)) ([
            "nixpkgs=/etc/nix/nixpkgs" # (use indirection so that all open shells update automatically)
            "nixos-config=/etc/nixos/configuration.nix"
            "/nix/var/nix/profiles/per-user/root/channels"
        ]);
        nixpkgs.flake.source = lib.mkForce null;

        system.extraDependencies = let # Make sure to also depend on nested inputs, to ensure they are already available in the host's nix store (in case the source identifiers don't resolve in the context of the host).
            getInputs = flake: [ flake ] ++ (map getInputs (lib.attrValues (flake.inputs or { })));
        in map (input: {
            type = "derivation"; outPath = toString input; # required when using newer versions of Nix (~1.14+) with older versions of nixpkgs (pre 23.05?)
        }) (getInputs cfg.nixos-config.flake);

    };
}
