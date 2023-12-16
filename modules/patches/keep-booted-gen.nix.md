/*

# Don't Delete the Booted System

When doing automatic (updates and) garbage collection (GC), one would usually include something like `--delete-older-than 30d`, because the GC would otherwise never automatically remove any of the automatically created updated systems.

The problem is that if the system is up for longer than the specified period, the `/run/booted-system` will prevent the booted system to be removed from the Nix store, but it will not prevent it to removed from the system generations list (profile), which is used to generate the bootloader entries.

The currently booted system is usually the only (or at least latest) system generation that is actually known not boot (or have booted) successfully, but the automatic GC can remove it from the bootloader entries.

That has the potential to make the system unbootable. This module/patch therefore backs up the system generation list (profile) entry pointing to the same system as `/run/booted-system`, and restores it after the GC if it was deleted by the `--delete-older-than` logic.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.nix.gc;
in {

    options = { nix.gc = {
        preserveBootedGeneration = lib.mkEnableOption "a workaround to ensure that the currently booted system always remains available as a boot loader entry (even if it is older than the GC limit)" // { default = true; example = false; };
    }; };

    config = lib.mkIf (config.nix.enable) {
        systemd.services.nix-gc.script = lib.mkIf (cfg.preserveBootedGeneration) (lib.mkForce ''
            source ${inputs.functions.lib.bash.prepend_trap}

            # The booted generation is the only one _known_ to actually boot.
            # Therefore, save the booted-generation link:
            backupLink=$( mktemp --dry-run ) && prepend_trap 'rm -rf $backupLink' EXIT
            bootedSystem=$( readlink /run/booted-system ) || true
            bootedGen= ; if [[ $bootedSystem ]] ; then for gen in /nix/var/nix/profiles/system-*-link ; do
                if [[ $( readlink "$gen" ) == "$bootedSystem" ]] ; then bootedGen=$gen ; break ; fi
            done ; fi
            if [[ $bootedGen ]] ; then
                cp -aT "$bootedGen" "$backupLink"
            fi

            # Ad _if_ the booted generation was deleted, restore it after GC'ing (the store path was preserved by the /run/booted-system gc-root):
            prepend_trap '
                if [[ $bootedGen && ! -e $bootedGen ]] ; then
                    cp -aT "$backupLink" "$bootedGen"
                fi
            ' EXIT

            # (do the normal GC stuff (without »exec«):)
            ${config.nix.package.out}/bin/nix-collect-garbage ${config.nix.gc.options} || exit
        '');
    };

}
