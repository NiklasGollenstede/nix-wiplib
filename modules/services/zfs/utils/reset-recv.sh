#!/usr/bin/env -S bash -u -o pipefail

root=${1:?'First arg must be the ZFS dataset to recursively abort receives on and roll back'}
snapPrefix=${2:-} # Optional posix regex. If supplied, only snapshots whose names are matched by this (anchored at the start) are accepted as latest snapshots, causing a rollback to a matching one otherwise.

#printf 'Starting rollback of %s/*.\n' "$1"


zfs list -r "$1" -H -o name | while read dataset ; do
    # Resuming a receive fails if the last complete snapshot in the receive stream got pruned from the target, so partial receives should get reset if they idle for too long:
    if zfs list -H -o name "$dataset"/%recv &>/dev/null ; then # This should be quick.
        ( set -x ; zfs receive -A "$dataset" ) || continue # This fails if a receive operation is running. Partial receives thus get reset only if they have not been resumed yet. Also, skip the steps below, because rolling back cancels receives.
    fi

    # In general, the send/receive can't be done if the last snapshot locally (on the target) is no longer held (back for it) by the sender.
    # With sanoid/syncoid, all snapshots should either be time-based "autosnap"s or "syncsnap"s.
    # Auto-snaps should generally not be the latest local snaps, but it can happen when the sync got interrupted and not resumed.
    # If most recent snaps get pruned here (target), the source will send them again. If they got pruned on the sending side first, then sync will be stuck.
    # Similarly, if the sender made a sync snap that is not related to this target but still ends up as the latest snap here for the same reasons, then the sender may delete that snap on its side once it no longer needs it for its intended purpose.
    # The former case only occurs when sync is interrupted for a long time, and even then is unlikely, the latter can only happen with direct sending to multiple targets.
    # So an optional filter of safe latest snapshots may be supplied, and everything lese that's later than one of those will be discarded. This is slow to check, and may discard significant sync progress:
    if [[ $snapPrefix ]] ; then
        snapshots=$( zfs list -t snapshot -H -o name -S creation "$dataset" ) # This is quite slow, esp. if may snapshots exist.
        latest=${snapshots%%$'\n'*}
        if [[ $latest && ! $latest =~ .*@$snapPrefix.* && $snapshots == *$'\n'* ]] ; then
            echo "Outdated snapshot $latest, attempting rollback"
            while IFS= read -r syncSnap ; do if [[ $syncSnap =~ .*@$snapPrefix.* ]] ; then
                ( set -x ; zfs rollback -r "$syncSnap" || true )
            break ; fi ; done <<< "$snapshots"
        fi
    fi

    # If the most recent snapshot got pruned from the target / locally (e.g. because a stream interruption meant the most recent snapshot is not a persistent one, or because there was a race between creating and sending the persistent snapshot and a temporary one being created in between), then the dataset needs to be rolled back to its latest snapshot, in order to be able to receive any updates onto it:
    if [[ $( zfs get -pH -o value written "$dataset" ) != 0 ]] ; then # If a most recent snapshot that had no data was destroyed, then the receive still works. The /%recv things are listed as separate FSes, not snapshots, so they should take their data with them when deleted.
        [[ ${latest:-} ]] || latest=$( zfs list -t snapshot -H -o name -S creation "$dataset" | head -n1 ) # This is quite slow, esp. if may snapshots exist.
        if [[ $latest ]] ; then ( set -x ; zfs rollback "$latest" || true ) ; fi # This is even slower, even if nothing needs to be rolled back. (Hence the »written« check.)
    fi
done
#printf 'Completed rollback of %s/*.\n' "$1"
