dirname: inputs: { config, options, pkgs, lib, name, modulesPath, modulesVersion, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.experiments.no-state-version;
in {
    options = { ${prefix}.experiments.no-state-version = {
        enable = lib.mkEnableOption "making access of `config.system.stateVersion` an error, and setting some defaults to avoid doing so";
    }; };

    config = lib.mkIf cfg.enable {
        system.stateVersion = lib.mkMerge [
            (lib.mkForce modulesVersion) # Set a value that passes the type checking, then replace it with something that throws on access:
            (lib.mkForce (lib.mkApply (_: throw "`config.system.stateVersion` has been disabled. Do not depend on it!\nYou probably need to explicitly set the option that appears above `system.stateVersion` in the stack trace.")))
        ];
        assertions = lib.wip.removeAssertionsFrom "${modulesPath}/misc/version.nix";

        # Set defaults for options that should not have used `system.stateVersion` in the first place:
        boot.swraid.enable = lib.mkDefault false; # was true before 23.11
        services.xserver.desktopManager.xterm.enable = lib.mkDefault false; # possibly true before 19.09
    };

    # Some modules use `system.stateVersion` in cross-cutting ways that can't be fixed by overriding their outputs.
    # So pin stateVersion to some fixed value (and not the current version, so that things do not change without announcement) for those modules:
    imports = let
        overrides = {
            "virtualisation/nixos-containers.nix" = "25.11";
            "services/web-apps/hedgedoc.nix" = "25.11";
        };
        abs = path: "${modulesPath}/${path}";
    in [ {
        disabledModules = map abs (lib.attrNames overrides);
    } ] ++ (lib.mapAttrsToList (path: stateVersion: let
        function = import (abs path);
        wrapped = args: function (args // { config = args.config // { system = args.config.system // { stateVersion = stateVersion; }; }; });
        module = { _file = "${path}#wrapped"; imports = [ (lib.setFunctionArgs wrapped (lib.functionArgs function)) ]; };
    in module) overrides);
}
