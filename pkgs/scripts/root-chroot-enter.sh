set -o pipefail -u

## Called as root, this sets up »/run/nixos-root« as a NixOS environment according to »/nix/var/nix/profiles/system« and then »chroot«s into that system/env executing »"$@"«.
#  To do this as a different user: $ [exec] sudo ${pkgs.root-chroot-enter} /run/current-system/sw/bin/su - $USER [-s ...] ''${COMMANDS:+-c "$COMMANDS"}

# /nix exists on the host, so nix packages (@{pkgs...) are available before entering the chroot.

root=/run/nixos-root
system=$( @{pkgs.coreutils}/bin/readlink -m /nix/var/nix/profiles/system )
unset LANGUAGE LANG

doActivate= ; if ! test -e $root/activated ; then doActivate=1 ; fi
mountError= ; if test $doActivate ; then (
    if [ -e $root ] ; then
        ! @{pkgs.util-linux}/bin/mountpoint -q $root || @{pkgs.util-linux}/bin/umount --lazy --recursive $root || exit
        @{pkgs.coreutils}/bin/rmdir $root || exit
    fi
    @{pkgs.util-linux}/bin/mount -t tmpfs --mkdir tmpfs $root || exit
    ( cd $root && @{pkgs.coreutils}/bin/mkdir -p -m 755 bin etc host nix run run/user usr ) || exit
    @{pkgs.coreutils}/bin/ln -sfT "$system" $root/run/booted-system || exit
    @{pkgs.util-linux}/bin/mountpoint -q $root/host || @{pkgs.util-linux}/bin/mount --rbind / $root/host || exit
    (   fstab=$( @{pkgs.coreutils}/bin/mktemp ) && trap "rm $fstab" EXIT &&
        LC_ALL=C @{pkgs.perl}/bin/perl -pe 's;^/host/;/;' <"$system"/etc/fstab >$fstab && # »--target-prefix« does not apply to bind (or probably also overlay) sources. This fixes that for bind mounts. (Also, »mount« does not like reading »--fstab« from a pipe.)
        @{pkgs.util-linux}/bin/mount --all --fstab $fstab --target-prefix $root --mkdir=755
    ) || exit
) || mountError=$? ; fi
if test $mountError ; then
    if test -e "${NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC:-}" ; then
        echo 1>&2 'Failed to create NixOS root chroot, running on host' ; exec "$@"
    else exit $mountError ; fi
fi

set +x ; . "$system"/etc/set-environment || exit

if test $doActivate ; then
    if ! @{pkgs.coreutils}/bin/chroot -- $root "$system"/activate 1>&2 ; then
        if ! test -e "${NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC:-}" ; then exit 1 ; fi
        echo 1>&2 'Proceeding after (partially) failed activation'
    fi
    @{pkgs.coreutils}/bin/touch $root/activated || exit
fi

# Called with sudo for interactive sessions, one ends up with a pts (and thus /dev/std{in,out,err}) owned by root. Fix that:
if [[ ${SUDO_USER:-} ]] ; then
    stdin=$( @{pkgs.coreutils}/bin/realpath /dev/stdin )
    if [[ $stdin == /dev/pts/* && $( @{pkgs.coreutils}/bin/stat -c '%U' "$stdin" ) == root ]] ; then
        @{pkgs.coreutils}/bin/chown "$SUDO_USER" "$stdin" || true
    fi
fi

if (( $# > 0 )) ; then
    unset NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC
    exec @{pkgs.coreutils}/bin/chroot -- $root "$@"
fi
