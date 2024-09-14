dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
in {

    options.containers = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
        reloadIfChanged = lib.mkOption { type = lib.types.bool; default = true; description = ''
            When true, reload the container when its `.path` changed (because its `.config` changed).
            This makes the container internally switch to the new configuration.
            Other changes to the container definition still kill and restart it.
        ''; };
    }; } ]); };

    config.systemd.services = lib.mkMerge (lib.mapAttrsToList (name: cfg: lib.optionalAttrs cfg.reloadIfChanged { "container@${name}" = let
        conf = config.environment.etc."${lib.optionalString (lib.versionAtLeast config.system.stateVersion "22.05") "nixos-"}containers/${name}.conf".text;
        confWithoutPath = builtins.unsafeDiscardStringContext (lib.fun.extractLineAnchored ''SYSTEM_PATH='' true false conf).without;
    in {
        reloadTriggers = [ cfg.path ]; restartTriggers = lib.mkForce [ confWithoutPath ];
    }; }) config.containers);

}
