
# This script is meant to be used as a `config.installer.scripts.*` entry, and »check-restore-zfs-backups« should be called while the pool is imported but the datasets aren't mounted (e.g. from »installer.commands.postFormat«).
function check-restore-zfs-backups { [[ ! ''${args[zfs-restore]:-} ]] || restore-zfs-backups "$@" ; }

declare-command restore-zfs-backups syncoidOptions << 'EOD'
Restores the system's ZFS backups, which would usually include »rpool-.../remote«.
The pool is expected to be imported at prefix »$mnt«; »syncoidOptions« (like »--force-delete«) may be passed as space-separated list.
EOD

declare-flag install-system zfs-restore "" "Restore the system's ZFS backups during the installation."
declare-flag install-system,restore-zfs-backups zfs-restore-host "hostname" "The name of the host from which to load the backups. Must be one of »config.wip.services.zfs.send.datasets.*.locations.*« or the name of the host to restore (to clone the living system, instead of restoring a backup). Defaults to the first host for each »config.wip.services.zfs.send.datasets.*.locations.*«."
declare-flag install-system,restore-zfs-backups zfs-restore-user "username" "The SSH user name to use to log in at the restore host. Defaults to »root«."
declare-flag install-system,restore-zfs-backups zfs-restore-local "" "Instead of loading the backups via SSH, assume that the explicit »--zfs-restore-host« points to the host running this script as »root«, and load the backups directly."

function restore-zfs-backups {
    local syncoidOptions=$1
    local dataset ; for dataset in "@{!config.wip.services.zfs.send.datasets!catAttrSets.locations[@]}" ; do

        local parent=$( dirname "$dataset" ) ; if [[ $parent == . ]] ; then echo "Restoring into the root of a pool ($dataset) is not supported (or even possible?)" ; \return 1 ; fi
        if [[ ! @{config.setup.zfs.pools!catAttrSets.createDuringInstallation[${dataset%%/*}]} ]] ; then continue ; fi

        eval 'declare -a locations='"@{config.wip.services.zfs.send.datasets!catAttrSets.locations[$dataset]}"
        local source= ; local noSnap=1 ; if [[ ${args[zfs-restore-host]:-} ]] ; then
            for it in "${locations[@]}" ; do if [[ $it == "${args[zfs-restore-host]}":* ]] ; then source=${args[zfs-restore-user]:-root}@$it ; break ; fi ; done
            if [[ ${args[zfs-restore-host]:-} == "@{config.networking.hostName}" ]] ; then source=${args[zfs-restore-user]:-root}@@{config.networking.hostName}:"$dataset" ; noSnap=1 ; fi
        else
            source=${args[zfs-restore-user]:-root}@${locations[0]}
        fi
        if [[ ${args[zfs-restore-local]:-} ]] ; then source=${source##*:} ; fi
        if [[ ! $source ]] ; then echo "No available restore source for dataset $dataset available from host ${args[zfs-restore-host]:-<any>}" ; fi

        restore-zfs-dataset "$source" "$dataset" ${noSnap:+--no-sync-snap} --sendoptions='w' --recvoptions='u' $syncoidOptions
    done
}

declare-command restore-zfs-dataset source target ...syncoidOptions << 'EOD'
Syncs the ZFS dataset »source« to the target »dataset«, and (assuming »dataset« is a dataset of the current host whose »/« is imported at »$mnt«) restores the ZFS properties on »dataset«.
EOD
function restore-zfs-dataset { # 1: source, 2: dataset, ...: syncoidOptions
    local source=$1 dataset=$2 ; shift ; shift # (Do not change these names, they may be used in the »postRestoreCommands«.)
    local syncoid=( syncoid --no-privilege-elevation --recursive --compress=none "$@" "$source" "$dataset" )

    echo "Restoring $dataset from $source with command:"
    ( set -x ; : "${syncoid[@]}" )
    read -p 'Enter to continue, or Ctrl+C to abort:' || return

    if [[ ${SUDO_USER:-} ]] ; then
        @{native.zfs}/bin/zfs allow -u "$SUDO_USER" create,receive,mount,destroy "$parent" || return
        PATH=$hostPath su - "$SUDO_USER" -c "$(declare -p syncoid SSH_AUTH_SOCK PATH)"' ; PATH='"@{native.sanoid}"'/bin/:$PATH LC_ALL=C "${syncoid[@]}"' || return
        @{native.zfs}/bin/zfs unallow -u "$SUDO_USER" create,receive,mount,destroy "$parent" || return
    else
        PATH=@{native.sanoid}/bin/:$PATH "${syncoid[@]}" || return
    fi

    PATH=@{native.zfs}/bin/:$PATH run-hook-script 'Post Restore Commands' @{config.wip.services.zfs.send.postRestoreCommands!writeText.postRestoreCommands} || return

    ensure-datasets "${mnt:-/}" "^$dataset($|[/])" || return
    : | @{native.zfs}/bin/zfs load-key -r "$dataset" || true
}
