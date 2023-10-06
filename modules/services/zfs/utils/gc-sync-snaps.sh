#!/usr/bin/env -S bash -u -o pipefail

root=${1:?'First arg must be the ZFS dataset to recursively prune'}
pendingLabel=${2:-non:existing} # On forwarding hosts/datasets, the ZFS property that pending next-host IDs are recorded in.
[[ $pendingLabel =~ ^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$ ]] || { echo 'Second arg must be a ZFS custom property label (or empty/omitted)' >&2 ; exit 1 ; }

## For each child dataset in »$root«, this removes all »@syncoid_${name}_${date}« snapshot that are older than the newest of any given »${name}« which has »${pendingLabel}=-« (i.e. that was forwarded to all required destinations). On a final receive destination (where »$pendingLabel« should always be »-«), this simply means "delete all but the latest sync snap (from any source)", which for a single source is what »syncoid« itself does. For the behavior of forwarding hosts, see »../README.md#backup-forwarding«.

failed= # exit code of the last failed command

printf 'Keeping the newest snapshot with »'"$pendingLabel"'=-« and anything newer.\n'
zfs list -r "$root" -H -o name | tail -n +2 | while read dataset ; do
    printf 'Garbage collecting »@syncoid_*« snaps in »%s«:\n' "$dataset"
    snaps=$( zfs list "$dataset" -t snapshot -S creation -H -o "$pendingLabel",name | grep -P '@syncoid_' ) || true
    declare -A had=( ) ; sent= ; while read -r holds snap ; do
        desc=$( <<<"$snap" grep -oP '@syncoid_\K.*(?=_20\d\d-\d\d-\d\d:\d\d:\d\d:\d\d-)' ) || true
        if [[ ! $desc ]] ; then continue ; fi
        if [[ $holds == - ]] ; then sent=true ; fi
        if [[ ! $sent ]] ; then continue ; fi # don't delete anything that hasn't been sent
        if [[ ! ${had[$desc]:-} ]] ; then # don't delete the most recant snap per source (if there are multiple remotes that alternatingly pull from and then push to this dataset, then each remote needs its latest common snap kept)
            printf 'keeping  %s\n' "${snap/$dataset/}"
            had[$desc]=true ; continue
        fi
        printf 'deleting %s\n' "${snap/$dataset/}"
        zfs destroy "$snap" || failed=$?
    done <<<"$snaps"
done

exit "${failed:-0}"
