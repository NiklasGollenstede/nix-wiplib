/*

# [`tuxedo-control-center`](https://github.com/tuxedocomputers/tuxedo-control-center)

This module activates and allows configuration of the `tccd` system daemon.

It can also autostart (to tray) the Tuxedo Control Center GUI, though, given the read-only daemon configuration, that GUI is pretty much read-only.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, extraModules, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.services.tuxedo-control-center;
in let module = {

    options.${prefix} = { services.tuxedo-control-center = {
        enable = lib.mkEnableOption "the `tccd` system daemon" // { defaultText = "`.autostartUsers != [ ]`"; default = cfg.autostartUsers != [ ]; };
        profiles = lib.mkOption {
            description = ''
                `tccd` profiles that can be referenced from the `.settings` (trying to change them in the UI currently doesn't work).
                The top-level attribute names are the profiles' IDs, which can be set as `.settings.stateMap.*` values.
                The free-form values are the profiles themselves. Each profile has these implicit defaults:
                ```json
                ${builtins.toJSON extra.profileDefaults}
                `${"``"}
            '';
            example = { myProfile = { fan.maximumFanspeed = 30; fan.customFanCurve.tableCPU = [ 10 12 14 22 30 30 30 30 35 40 ]; }; };
            type = lib.types.attrsOf lib.types.anything; default = { };
            apply = value: lib.mapAttrs (id: profile: extra.expandProfile (
                { name = id; } // (lib.recursiveUpdate extra.profileDefaults profile) // { inherit id; }
            )) (lib.filterAttrs (k: v: v != null) value);
        };
        settings = lib.mkOption {
            description = ''
                `tccd` settings (w/o profiles). Implicit defaults are:
                ```json
                ${extra.defaultSettings}
                `${"``"}
            '';
            example = { stateMap = { power_ac = "myProfile"; power_bat = "myProfile"; }; };
            type = lib.types.attrsOf lib.types.anything; default = { };
            apply = value: lib.recursiveUpdate (builtins.fromJSON extra.defaultSettings) (lib.filterAttrs (k: v: v != null) value);
        };
        autostartUsers = lib.mkOption {
            description = ''
                Names of users for whom to auto-start `tuxedo-control-center` into the tray.
                The UI is currently pretty much read-only. Trying to change anything has no real effect and usually makes it hang.
            '';
            type = lib.types.listOf lib.types.str; default = [ ];
        };
    }; };

    config = lib.mkIf cfg.enable (lib.mkMerge [ (let
        package = pkgs.tuxedo-control-center;
    in {

        hardware.tuxedo-drivers.enable = true;
        boot.kernelModules = [ "clevo_acpi" "tuxedo_io" ]; # (These seem to be related to hotkeys, but weren't loaded on my Ubuntu laptop: "clevo_wmi" "uniwill_wmi")

        systemd.packages = [ package ]; systemd.services.tccd = {
            wantedBy = [ "multi-user.target" ];
            restartTriggers = [ config.environment.etc."tcc/profiles".source config.environment.etc."tcc/settings".source ];
        };
        services.dbus.packages = [ package ];
        services.udev.packages = [ package ];

        environment.etc."tcc/profiles".text = builtins.toJSON (lib.attrValues cfg.profiles);
        environment.etc."tcc/settings" = { text = builtins.toJSON cfg.settings; mode = "644"; };

        ${prefix}.services.tuxedo-control-center.profiles.__default_custom_profile__ = { # = lib.mkForce null; # to remove this
            name = lib.mkOptionDefault "TUXEDO Defaults";
            description = lib.mkOptionDefault "Set »${prefix}.services.tuxedo-control-center.profiles.__default_custom_profile__.*« in your nixos config to change its behavior (or add new profiles there)";
        };

        users.users = lib.genAttrs cfg.autostartUsers (user: { packages = [ package package.autostart ]; });

    }) ]);

}; extra = rec {
    defaultSettings = ''
        {
            "stateMap": { "power_ac": "__default_custom_profile__", "power_bat": "__default_custom_profile__" },
            "shutdownTime": null, "chargingProfile": null, "chargingPriority": null,
            "cpuSettingsEnabled": true, "fanControlEnabled": true, "keyboardBacklightControlEnabled": true,
            "ycbcr420Workaround": [{"DP-1":false,"DP-2":false,"DP-3":false,"DP-4":false,"HDMI-A-1":false,"eDP-1":false}],
            "keyboardBacklightStates": [{"mode":0,"brightness":2}]
        }
    '';
    profileDefaults = {
        #name = "";
        description = "";
        display = {
            brightness = 100;
            useBrightness = false;
            refreshRate = -1;
            useRefRate = false;
            xResolution = -1;
            yResolution = -1;
            useResolution = false;
        };
        cpu = {
            useMaxPerfGov = false;
            governor = "powersave";
            energyPerformancePreference = "balance_performance";
            noTurbo = false;
        };
        webcam = {
            status = true;
            useStatus = true;
        };
        fan = {
            useControl = true;
            fanProfile = "Balanced";
            minimumFanspeed = 0;
            maximumFanspeed = 100;
            offsetFanspeed = 0;
            customFanCurve = {
                tableCPU = defaultFanCurve;
                tableGPU = defaultFanCurve;
            };
        };
        odmProfile = { };
        odmPowerLimits = {
            tdpValues = [ ];
        };
    };
    defaultFanCurve = [ 10 12 14 22 35 44 56 79 85 90 ];
    expandFanCurve = curve: let step = 100 / builtins.length curve; in lib.imap1 (i: s: { temp = builtins.floor (i*step); speed = s; }) curve;
    expandProfile = profile: profile // { fan = profile.fan // { customFanCurve = lib.mapAttrs (_: expandFanCurve) profile.fan.customFanCurve; }; };
}; in module
