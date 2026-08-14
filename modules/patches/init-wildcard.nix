dirname: inputs: { config, pkgs, lib, modulesVersion, ... }: let lib = inputs.self.lib.__internal__; in let
    description = "Allow a (prepended) custom `init=` parameter as a glob pattern of the form `*`, `$pathHash`, `$systemName`, `$systemName-$nixosVersion`, `$systemName-$nixosVersion.$releaseDate`, or any other pattern, and try to find the most appropriate closure present in the store. This is, of course, only meant for debugging and system recovery.";
in { # except for that, this is a copy of the script from nixpkgs/nixos/modules/system/boot/systemd/initrd.nix

    config.boot.initrd.systemd.services.initrd-find-nixos-closure = lib.mkIf (!config.system.nixos-init.enable) { script = lib.mkForce (let
        cfg = config.boot.initrd.systemd;
    in ''
        set -uo pipefail
        export PATH="/bin:${
          lib.makeBinPath [
            cfg.package.util-linux
            config.system.nixos-init.package
          ]
        }"

        # Figure out what closure to boot
        closure=
        for o in $(< /proc/cmdline); do
            case $o in
                init=*)
                    IFS="=" read -r -a initParam <<< "$o"
                    closure="''${initParam[1]}"
                    ;;
            esac
        done

        # Sanity check
        if [ -z "''${closure:-}" ]; then
          echo 'No init= parameter on the kernel command line' >&2
          exit 1
        fi

        # NEW: ${description}
        if [[ $closure != /* ]] ; then
          if [[ $closure == '*' ]] ; then closure=*-nixos-system-*/ ; fi
          if [[ $closure =~ [[:alnum:]]{32} ]] ; then closure=$closure-nixos-system-*/ ; fi
          if [[ $closure != *-nixos-system-* ]] ; then closure=*-nixos-system-$closure ; fi
          if [[ $closure != */ ]] ; then
              if [[ $closure == *'*' ]] ; then closure=$closure/
            elif [[ $closure == *'.' || $closure == *'-' ]] ; then closure=$closure*/
            elif [[ $closure =~ [[:digit:]]{2}[.][[:digit:]]{2}([.][[:digit:]]{8})?$ ]] ; then closure=$closure.*/
            else closure=$closure-*/ ; fi
          fi
          closures=( $( shopt -s nullglob ; echo /sysroot/nix/store/$closure ) )
          closures=( $( printf '%s\n' ''${closures[@]} | LC_ALL=C sort --reverse --field-separator=. --key=3 ) )
          closure=''${closures[0]#/sysroot}init
        fi
        # end NEW

        # Resolve symlinks in the init parameter. We need this for some boot loaders
        # (e.g. boot.loader.generationsDir).
        closure="$(resolve-in-root /sysroot "$closure")"

        # Assume the directory containing the init script is the closure.
        closure="$(dirname "$closure")"

        ln --symbolic "$closure" /nixos-closure

        # If we are not booting a NixOS closure (e.g. init=/bin/sh),
        # we don't know what root to prepare so we don't do anything
        if ! [ -x "/sysroot$(readlink "/sysroot$closure/prepare-root" || echo "$closure/prepare-root")" ]; then
          echo "NEW_INIT=''${initParam[1]}" > /etc/switch-root.conf
          echo "$closure does not look like a NixOS installation - not activating"
          exit 0
        fi
        echo 'NEW_INIT=' > /etc/switch-root.conf
    ''); };

}
