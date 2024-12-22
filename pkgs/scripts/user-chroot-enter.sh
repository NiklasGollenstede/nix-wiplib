#!/usr/bin/env bash
set -o pipefail -u

## Called as normal user, this sets up »/run/user/$UID/root« as a NixOS environment according to »$NIX_DIR/var/nix/profiles/system« and then »bwrap«-"chroot"s into that system/env executing »"$@"«.
# For example: $ NIX_DIR=${nixDir} [exec] ${nixDir}${lib.removePrefix "/nix" pkgs.user-chroot-enter.src} ${lib.getExe user.shell} ''${COMMANDS:+-c "$COMMANDS"}

# /nix does not exist on the host, so nix packages (@{pkgs...) are not available before entering the chroot, and this script can't be called by it's notmal path either.

nixDir=$NIX_DIR ; unset NIX_DIR

#for mnt in /var/* ; do bind+=( --bind $mnt $mnt ) ; done
#bind+=( --dir /var/empty ) # --perms 0555

root=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/root
system=$( readlink -m "$nixDir"/var/nix/profiles/system )
doActivate= ; if [[ ! -e $root/activated ]] ; then doActivate=1 ; fi
if [[ $doActivate ]] ; then
    mkdir -p -m 755 $root/{,etc,run,var} || exit # /{,bin,etc,run,usr}
    ln -sfT "$system" $root/run/booted-system || exit
    ln -sfT "$system" $root/run/current-system || exit
fi

function resolve { local link ; link=$( readlink -m "$1" ) && echo "$nixDir"/"${link#/nix/}" ; }
_system=$( resolve "$system" ) || exit
_etc=$( resolve "$_system"/etc ) || exit

_fstab=$( resolve "$_etc"/fstab ) || exit
bind=( )
bind+=( --bind $root / )
bind+=( --bind / /host --bind "$nixDir" /nix )
bind+=( --bind "$HOME" "$HOME" )
#for mnt in bin etc run usr ; do bind+=( --bind $root/$mnt /$mnt ) ; done # TODO:?
while read -u3 source target type options numbers ; do
    if [[ ! $target || $target == none ]] ; then continue ; fi # (swap)
    if [[ $options == rbind && $source == /host/* ]] ; then
        mkdir -p ${source#/host} || exit
        bind+=( --bind ${source#/host} $target )
    elif [[ $type == tmpfs || $type == ramfs ]] ; then
        bind+=( --tmpfs $target )
    elif [[ $type == proc ]] ; then
        bind+=( --proc $target )
    elif [[ $type == sysfs ]] ; then
        bind+=( --bind /sys $target )
    elif [[ $type == devtmpfs ]] ; then
        bind+=( --dev-bind /dev $target ) # --dev
    else
        echo 'Ignoring unsupported fstab mount:' $source $target $type $options $numbers >&2 ; continue
    fi
done 3< <( <$_fstab grep -v '^#' )

#bind+=( --bind "$HOME" "$HOME" ) # TODO: necessary if $HOME is a mount point?

_setEnv=$( resolve "$_etc"/set-environment ) || exit
bwrap=$( which bwrap ) && touch=$( which touch ) && true=$( which true ) || true
source "$_setEnv" || exit # ($PATH is now useless outside bwrap)

if [[ $doActivate ]] ; then
    if ! "$bwrap" --die-with-parent "${bind[@]}" -- /run/current-system/activate 1>&2 ; then
        if ! test -e "${NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC:-}" ; then exit 1 ; fi
        if "$bwrap" --die-with-parent "${bind[@]}" -- "$true" ; then
            echo 1>&2 'Proceeding after (partially) failed activation'
        else
            echo 1>&2 'Failed to create NixOS root chroot, running on host' ; exec "$@"
        fi
    fi
    "$touch" $root/activated || exit
fi

unset NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC
exec "$bwrap" --die-with-parent "${bind[@]}" -- "$@"
# --unshare-user --uid $(id -u) --gid $(id -g)
