#!/usr/bin/env -S bash -u -o pipefail

root=${1:?'First arg must be the ZFS dataset to recursively abort receives on and roll back'}

#printf 'Starting rollback of %s/*.\n' "$1"

zfs list -r "$1" -H -o name | while read dataset ; do
    # Resuming a receive fails if the last complete snapshot in the receive stream got pruned from the target, so partial receives should get reset if they idle for too long:
    if zfs list -H -o name "$dataset"/%recv &>/dev/null ; then # This should be quick.
        ( set -x ; zfs receive -A "$dataset" || true ) # This fails if the recv operation is still running. It gets cancelled only if it was not yet resumed since the last interruption.
    fi
    # If the most recent snapshot is a sync snap to a different host that has since been deleted from the source, then sync will be permanently stuck.
    # TODO: solve that ...
    # If the most recent snapshot got pruned (e.g. because a stream interruption meant the most recent snapshot is not a persistent one, or because there was a race between creating and sending the persistent snapshot and a temporary one being created in between), then the dataset needs to be rolled back to its latest snapshot, in order to be able to receive any updates onto it:
    if [[ $( zfs get -pH -o value written "$dataset" ) != 0 ]] ; then # If a most recent snapshot that had no data was destroyed, then the receive still works. The /%recv things are listed as separate FSes, not snapshots, so they should take their data with them when deleted.
        snapshot=$( zfs list -t snapshot -H -o name -s creation "$dataset" | tail -n1 ) # This is quite slow, esp. if may snapshots exist.
        if [[ $snapshot ]] ; then ( set -x ; zfs rollback "$snapshot" || true ) ; fi # This is even slower, even if nothing needs to be rolled back. (Hence the »written« check.)
    fi
done
#printf 'Completed rollback of %s/*.\n' "$1"
