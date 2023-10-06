#!/usr/bin/env -S bash -u -o pipefail

target=$1 ; prop=$2 ; snap=$3

## Used as »syncoid --no-sync-snap --sync-snap-cmd-after=.../mark-snap-as-sent.sh $target $prop« when forwarding ZFS datasets, this removes $target from the list of pending targets in the ZFS property $prop of the snapshot $snap immediately after it has been sent there.
## This prepares the snaps to be pruned by »./prune-sync-snaps.sh«. See »../README.nix.md#backup-forwarding« for more information.

before=$( zfs get -H -o value "$prop" "$snap" ) || exit

if [[ "$before" == - ]] ; then exit 0 ; fi
if [[ "$before" == "$target" ]] ; then
    now=:-: # inheriting would restore the full list
else
    now=:$before: ; now=${now//:$target:/:}
fi
zfs set "$prop"=${now:1:(-1)} "$snap" || exit
