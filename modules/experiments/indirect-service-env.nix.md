/*

# Indirect Unit Environment

Currently, *each* generated service unit file individually lists the environment variables `LOCALE_ARCHIVE` and `TZDIR` and 5 default packages for their `PATH`.
This is not only verbose, but also (intentionally) causes most units to change (and thus usually be reloaded/restarted) whenever any of those system dependencies change.
While that may be closer to "correct" semantics, those basic dependencies usually do not change in semantically relevant ways.
The only theoretically correct way to reload units on-large is rebooting anyway.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, name, modulesPath, modulesVersion, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.experiments.indirect-service-env;
    systemBuilderCommands = if modulesVersion >= "25.11" then "systemBuilderCommands" else "extraSystemBuilderCmds";
    packages = [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused config.systemd.package ];
    env = pkgs.buildEnv { name = "default-unit-path"; paths = packages; };
in {

    options.${prefix} = { experiments.indirect-service-env = {
        enable = lib.mkEnableOption "avoid large-scale unit reloading when basic system dependencies change";
    }; };

    options.systemd.services = lib.mkOption { type = moduleArgs.lib.types.attrsOf (moduleArgs.lib.types.submodule [ {
        config = lib.mkIf cfg.enable { path = lib.mkAfter (moduleArgs.lib.mkApply (all: let
            tail = lib.takeEnd 5; head = lib.dropEnd 5;
        in if tail == packages then if lib.length all == 5 then null else ( # TODO: This does not seem to ever be true. Why?
            head ++ [ "/run/current-system/default-unit-path" ]
        ) else (
            (lib.subtractLists packages all) ++ [ "/run/current-system/default-unit-path" ]
        ))); };
    } ]); };

    config = lib.mkIf cfg.enable (lib.mkMerge [ ({

        system.${systemBuilderCommands} = ''ln -sT ${env} $out/default-unit-path''; # could also be in /etc
        systemd.globalEnvironment = { LOCALE_ARCHIVE = lib.mkForce null; TZDIR = lib.mkForce null; };

	}) (if modulesVersion >= "25.11" then { # Show unit names instead of descriptions in systemctl status output and during boot.
        systemd.settings.Manager.DefaultEnvironment = "LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive TZDIR=/etc/zoneinfo";
    } else {
        systemd.extraConfig = "DefaultEnvironment=LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive TZDIR=/etc/zoneinfo";
    }) ]);

}
