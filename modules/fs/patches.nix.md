/*

# FS Nixpkgs "Patches"

Filesystem related "patches" of options in nixpkgs, i.e. additions of options that are *not* prefixed.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, utils, ... }: let inherit (inputs.self) lib; in let
in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
            preMountCommands = lib.mkOption { description = ""; type = lib.types.nullOr lib.types.str; default = null; };
        }; } ]);
    }; };

    config = let
    in ({

        systemd.services = lib.wip.mapMerge (target: { device, preMountCommands, depends, ... }: if (preMountCommands != null) then let
            isDevice = lib.wip.startsWith "/dev/" device;
            target' = utils.escapeSystemdPath target;
            device' = utils.escapeSystemdPath device;
        in { "pre-mount-${target'}" = {
            description = "Prepare mounting (to) ${target}";
            wantedBy = [ "${target'}.mount" ]; before = [ "${target'}.mount" ]
            ++ (lib.optional isDevice "systemd-fsck@${device'}.service"); # TODO: Does this exist for every device? Does depending on it instantiate the template?
            requires = lib.optional isDevice "${device'}.device"; after = lib.optional isDevice "${device'}.device";
            unitConfig.RequiresMountsFor = depends ++ [ (builtins.dirOf device) (builtins.dirOf target) ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot"; script = preMountCommands;
        }; } else { }) config.fileSystems;

    });

}
