/*

# `mount -a -o noexec` Experiment

This is an ongoing, but so far successful, experiment to mount (almost) all filesystems as `noexec`, `nosuid` and `nodev` -- and to then deal with the consequences.
This currently requires the [mkApply](patches/nixpkgs/mkApply-25-11.patch) patch to nixpkgs.


## Exceptions

* `/dev` and `/dev/pts` need `dev`
* `/run/wrappers` needs `exec` and `suid`
* `/nix` (specifically the `/nix/store` and the build directories now in `/nix/var/nix/builds`) need `exec`
* `/run` and `/run/user/*` may need `exec`
* Some parts of `/home/<user>/` will need `exec`


## TODO

* The auto-created `/run/netns` needs `noexec` (its automatic child-mounts are files).
* More testing on what breaks and how to fix it.


## Problems Encountered

* Local development often requires executable repositories.
* `~/.local/share/Steam` needs `exec` for Steam and its games.
* WideVine in Firefox breaks. See fix below.
* ...


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, options, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.experiments.noexec;
    opts = options.${prefix}.experiments.noexec;
    specialFileSystems = [ "/dev" "/dev/pts" "/dev/shm" "/proc" "/run" "/run/keys" "/sys" ];
in {

    options.${prefix} = { experiments.noexec = {
        enable = lib.mkEnableOption "(almost) all filesystems being mounted as »noexec« (and »nosuid« and »nodev«)";
        execPaths = lib.mkOption {
            type = lib.types.addCheck (lib.types.attrsOf (lib.types.bool)) (def: builtins.all (x: builtins.substring 0 1 (toString x) == "/") (builtins.attrNames def));
            apply = lib.filterAttrs (path: exec: exec);
            default = { }; defaultText = lib.literalExpression ''{ "/nix/store" = true; ''${if config.nix.enable then config.nix.settings.build-dir or "/nix/var/nix/builds" else null} = true; }'';
        };
        fix.firefox = lib.mkEnableOption "workaround for Firefox WideVine DRM not working with »noexec« homes" // { default = true; example = false; };
    }; };

    # Default all filesystems to noexec,nosuid,nodev unless explicitly specified otherwise:
    options.fileSystems = lib.mkOption { type = moduleArgs.lib.types.attrsOf (moduleArgs.lib.types.submodule [ {
        config = lib.mkIf cfg.enable { options = lib.mkAfter (moduleArgs.lib.mkApply (options: options
            ++ lib.optional (!(lib.elem "exec" options) && !(lib.elem "noexec" options)) "noexec"
            ++ lib.optional (!(lib.elem "suid" options) && !(lib.elem "nosuid" options)) "nosuid"
            ++ lib.optional (!(lib.elem "dev"  options) && !(lib.elem "nodev"  options)) "nodev"
        )); };
    } ]); };
    options.boot.specialFileSystems = lib.mkOption { type = moduleArgs.lib.types.attrsOf (moduleArgs.lib.types.submodule [ {
        config = lib.mkIf cfg.enable { options = lib.mkAfter (moduleArgs.lib.mkApply (options: options
            ++ lib.optional (!(lib.elem "exec" options) && !(lib.elem "noexec" options)) "noexec"
            ++ lib.optional (!(lib.elem "suid" options) && !(lib.elem "nosuid" options)) "nosuid"
            ++ lib.optional (!(lib.elem "dev"  options) && !(lib.elem "nodev"  options)) "nodev"
        )); };
    } ]); };

    config = lib.mkMerge [ {

        ${prefix}.experiments.noexec = {
            # Never enable this for the installer VM (which it breaks):
            enable = lib.mkIf (config.system.build?isVmExec || config.system.build?isVmExec-aarch64-linux?isVmExec-x86_64-linux) (lib.mkVMOverride false);
            execPaths = opts.execPaths.default; # (enabling other paths as exec should not remove the defaults)
        };

    } (lib.mkIf cfg.enable (rec { # enforcement for mounts that are not created by fileSystems / boot.specialFileSystems:

        systemd.services."user-runtime-dir@" = {
            overrideStrategy = "asDropin";
            serviceConfig.ExecStartPost = lib.mkBefore [ "/run/current-system/sw/bin/mount -o remount,noexec /run/user/%i" ];
        };

        # Nix(OS) itself does not know about /dev/hugepages (defined by systemd):
        systemd.packages = [ (lib.fun.mkSystemdOverride pkgs "dev-hugepages.mount" "[Mount]\nOptions=nosuid,nodev,noexec\n") ];

        # agenix mounts this without »noexec«, but only if it does not exist yet:
        fileSystems."/run/agenix.d" = lib.mkIf (config.age.secrets or { } != { }) {
            device = "none"; fsType = "ramfs"; options = [ "nosuid" "noexec" "nodev" "mode=751" ];
            neededForBoot = true; # activation (with agenix) happens before stage-2 mounts
        };

        boot.nixStoreMountOpts = lib.mkOptionDefault [ "exec" ]; # This does not always get applied early enough, so we still need `execPaths."/nix/store" = true`.

        # Make the /nix/store non-iterable, to make it harder for unprivileged programs to search the store for programs they should not have access to:
        fileSystems."/nix".postMountCommands = ''
            chmod -f 1771 $root/nix/store || true # root owned (usually 1775; should still be writable by the build group, and needs to be traversable by everyone)
            chmod -f  750 $root/nix/store/.links || true # root owned (was 755), but no one but the nix daemon should directly access these (and finding an executable file by content hash could be a risk)
        '';
        fileSystems."/nix/store".options = [ "ro" ]; # without setting this a bit earlier, stage-2-init resets the permissions again

        nix.settings.allowed-users = [ "root" "@wheel" ]; # This goes hand-in-hand with setting mounts as »noexec«. Cases where a user other than root should build stuff are probably fairly rare. A "real" user might want to, but that is either already in the wheel(/sudo) group, or explicitly adding that user is pretty reasonable.


    })) (lib.mkIf cfg.enable { # exceptions

        fileSystems = lib.mapAttrs (where: _: fsCfg: { config = {
            options = [ "exec" ]
            # This needs to be a mount point. If it is not otherwise defined as such, make it a bind mount onto itself:
            ++ (lib.optional (fsCfg.config.device == where) "bind"); device = lib.mkDefault where;
        }; }) (lib.filterAttrs (where: _: !lib.hasPrefix "/run/user/" where) (builtins.removeAttrs cfg.execPaths specialFileSystems));

        boot.specialFileSystems = lib.fun.mapMerge (where: if cfg.execPaths?${where} then {
            ${where}.options = [ "exec" ];
        } else { }) specialFileSystems;

    }) (lib.mkIf cfg.enable { # exceptions

        boot.specialFileSystems = {
            "/dev" = { options = [ "dev" ]; };
            "/dev/pts" = { options = [ "dev" ]; };
        };
        # /run/wrappers is implemented as a systemd.mounts unit, which would be hard to modify, but its options are already correct.
        ${prefix}.experiments.noexec.execPaths = {
            "/nix/store" = true;
            ${if config.nix.enable then config.nix.settings.build-dir or "/nix/var/nix/builds" else null} = true;
        };
        # Adding /run or paths in /home/* to execPaths is easy enough.

        # Optionally re-enable exec on /run/user/<uid>:
        systemd.services = lib.fun.mapMerge (where: let
            uid = lib.hasPrefix "/run/user/" where;
        in { "user-runtime-dir@${uid}" = {
            overrideStrategy = "asDropin";
            serviceConfig.ExecStartPost = [ "/run/current-system/sw/bin/mount -o remount,exec /run/user/uid" ];
        }; }) (lib.filterAttrs (where: _: lib.hasPrefix "/run/user/" where) cfg.execPaths);


    }) ({ # (the overlay's presence should not depend on cfg(.enable))

        # (`programs.firefox.*` can set preferences, but not GMP paths (or environment variables), so override all firefox variants(' wrappers, so this is actually fast))
        nixpkgs.overlays = [ (final: prev: let
            arch = { "x86_64-linux" = "linux_x64"; "aarch64-linux" = "linux_arm64"; }."${prev.stdenv.hostPlatform.system or ""}" or null;
        in if arch == null then { } else  {
            wrapFirefox = if !cfg.enable || !cfg.fix.firefox then prev.wrapFirefox else browser: opts: let
                version = "${final.widevine-cdm.version}-system";
                extraPrefs = opts.extraPrefs or "" + ''
                    lockPref("media.gmp-widevinecdm.version", ${builtins.toJSON version});
                    lockPref("media.gmp-widevinecdm.visible", true);
                    lockPref("media.gmp-widevinecdm.enabled", true);
                    lockPref("media.gmp-widevinecdm.autoupdate", false);
                    lockPref("media.eme.enabled", true);
                    lockPref("media.eme.encrypted-media-encryption-scheme.enabled", true);
                '';
                src = "${final.widevine-cdm}/share/google/chrome/WidevineCdm";
                dst = "$out/gmp-widevinecdm/${version}"; # path must match $out/gmp-$name/$version
            in (prev.wrapFirefox browser (opts // { inherit extraPrefs; })).overrideAttrs (old: {
                buildCommand = ''
                    makeWrapperArgs+=( --set MOZ_GMP_PATH "${dst}" )
                '' + old.buildCommand + ''
                    mkdir -p "${dst}"
                    ln -s "${src}/_platform_specific/${arch}/libwidevinecdm.so" "${dst}/libwidevinecdm.so"
                    ln -s "${src}/manifest.json" "${dst}/manifest.json"
                '';
            });
        }) ];

    }) ];

}
