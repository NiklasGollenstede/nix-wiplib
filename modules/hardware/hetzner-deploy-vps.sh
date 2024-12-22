
declare-command deploy-system-to-hetzner-vps '-- --name=<name> --type=<serverType> [...hcloud_server_create_args]' << 'EOD'
Builds the current system's (single »partitionDuringInstallation«ed) disk image and calls »deploy-image-to-hetzner-vps«. The installation heeds any »args« / CLI flags set.
All positional args are passed to »hcloud server create« to decide the new server's properties. Mandatory arguments are »--name« and »--type« (note that positional args starting with »--*« have to be preceded by a »--« argument to be interpreted as such).
Requires the »HCLOUD_TOKEN« environment variable to be set.
EOD
declare-flag deploy-system-to-hetzner-vps parallel-build-deploy '' "Start initializing the VPS while its image is still being built. This is faster, but the server will be billed for the first hour even if the image build fails."
function deploy-system-to-hetzner-vps {
    if [[ ! ${args[quiet]:-} ]] ; then echo 'Building the worker image' ; fi
    local image ; image=$( mktemp -u ) && prepend_trap "rm -f '$image'" EXIT || return
    local buildPid ; args[no-inspect]=1 ; args[disks]=$image install-system & buildPid=$!
    if [[ ! ${args[parallel-build-deploy]:-} ]] ; then wait $buildPid || return ; buildPid= ; fi

    args_waitPid=$buildPid deploy-image-to-hetzner-vps "$image" "$@" || return
}

declare-command deploy-image-to-hetzner-vps imagePath '-- --name=<name> --type=<serverType> [...hcloud_server_create_args]' << 'EOD'
Creates a new Hetzner Cloud VPS, copies the system image from the local »imagePath« to the new VPS, boots it, and waits until its port 22 is open.
For the arguments after »imagePath«, see the »deploy-system-to-hetzner-vps« command.
Requires the »HCLOUD_TOKEN« environment variable to be set.
If the variable »arg_waitPid« is set, it waits for that process to exit in between creating the server and copying the image to it.
EOD
declare-flag deploy-system/image-to-hetzner-vps vps-keep-on-build-failure '' "Do not delete the VPS if the deployment fails. Useful only for debugging (and dangerous otherwise, because the server resource is simply being \"leaked\")."
declare-flag deploy-system/image-to-hetzner-vps vps-suppress-create-email '' "Prevent hetzner from sending an email with a (useless) root password for the new server to the account owner by setting the server's »ssh-key« option to »dummy«. A key of that name has to exist in »HCLOUD_TOKEN«'s cloud project."
function deploy-image-to-hetzner-vps { # 1: imagePath
    local imagePath=$1 ; shift 1 || exit
    local stdout=/dev/stdout ; if [[ ${args[quiet]:-} ]] ; then stdout=/dev/null ; fi

    local name ; for ((i = 0; i < $#; i++)) ; do
        if [[ ${!i} == "--name" ]] && (( i + 1 < $# )) ; then
            name="${!((i+1))}" ; break
        elif [[ ${!i} == --name=* ]] ; then
            name="${!i#--name=}" ; break
        fi
    done ; if [[ ! $name ]] ; then echo '»--name[=]« argument missing!' >&2 ; \return 1 ; fi

    local work ; work=$( mktemp -d ) && prepend_trap "rm -rf $work" EXIT || return
    local keyName ; for keyName in host login ; do
        @{native.openssh}/bin/ssh-keygen -q -N "" -t ed25519 -f $work/$keyName -C $keyName || return
    done

    echo 'Creating the VPS:' >$stdout
    if [[ ! ${args[vps-keep-on-build-failure]:-} ]] ; then prepend_trap "if [[ ! -e $work/buildSucceeded ]] ; then @{native.hcloud}/bin/hcloud server delete '$name' ; fi" EXIT || return ; fi
    cat <<EOC | # TODO: simply use JSON?
#cloud-config
chpasswd: null
#ssh_pwauth: false
package_update: false
package_upgrade: false
ssh_authorized_keys:
    - '$( cat $work/login.pub )'
ssh_genkeytypes: [ ]
ssh_keys:
    ed25519_public: '$( cat $work/host.pub )'
    ed25519_private: |
$( cat $work/host | @{native.perl}/bin/perl -pe 's/^/        /' )
EOC
    ( PATH=@{native.hcloud}/bin ; ${_set_x:-:} ; hcloud server create --image=ubuntu-22.04 --user-data-from-file - ${args[vps-suppress-create-email]:+--ssh-key dummy} "$@" >$stdout ) || return
    # @{native.hcloud}/bin/hcloud server poweron "$name" || return # --start-after-create=false

    local ip ; ip=$( @{native.hcloud}/bin/hcloud server ip "$name" ) || ip=$( @{native.hcloud}/bin/hcloud server ip --ipv6 "$name" ) && echo "$ip" >$work/ip || return
    printf "%s %s\n" "$ip" "$( cat $work/host.pub )" >$work/known_hosts || return
    local sshCmd ; sshCmd="@{native.openssh}/bin/ssh -oUserKnownHostsFile=$work/known_hosts -i $work/login root@$ip"

    printf %s 'Preparing the VPS/worker for image transfer ' >$stdout
    sleep 5 ; local i ; for i in $(seq 20) ; do sleep 1 ; if $sshCmd -- true &>/dev/null ; then break ; fi ; printf . >$stdout ; done ; printf ' ' >$stdout
    # The system takes a minimum of time to boot, so might as well chill first. Then the loop fails (loops) only before the VM is created, afterwards it blocks until sshd is up.
    $sshCmd 'set -o pipefail -u -e
        # echo u > /proc/sysrq-trigger # remount all FSes as r/o (did not cut it)
        mkdir /tmp/tmp-root ; mount -t tmpfs -o size=100% none /tmp/tmp-root
        umount /boot/efi ; rm -rf /var/lib/{apt,dpkg} /var/cache /usr/lib/firmware /boot ; printf . >'$stdout'
        cp -axT / /tmp/tmp-root/ ; printf . >'$stdout'
        mount --make-rprivate / ; mkdir -p /tmp/tmp-root/old-root
        pivot_root /tmp/tmp-root /tmp/tmp-root/old-root
        for i in dev proc run sys ; do mkdir -p /$i ; mount --move /old-root/$i /$i ; done
        systemctl daemon-reexec ; systemctl restart sshd
    ' || return ; echo . >$stdout

    if [[ ${arg_waitPid:-} ]] ; then wait $buildPid || return ; fi
    echo 'Writing worker image to VPS' >$stdout
    @{native.zstd}/bin/zstd -c "$imagePath" | $sshCmd 'set -o pipefail -u -e
        </dev/null fuser -mk /old-root &>/dev/null ; sleep 2
        </dev/null umount /old-root
        </dev/null blkdiscard -f /dev/sda &>/dev/null
        </dev/null sync # this seems to be crucial
        zstdcat - >/dev/sda
        </dev/null sync # this seems to be crucial
    ' || return
    @{native.hcloud}/bin/hcloud server reset "$name" >$stdout || return

    printf %s 'Waiting for the worker to boot ' >$stdout
    sleep 2 ; local i ; for i in $(seq 20) ; do sleep 1 ; if ( exec 2>&- ; echo >/dev/tcp/"$ip"/22 ) ; then touch $work/buildSucceeded ; break ; fi ; printf . >$stdout ; done ; echo >$stdout

    if [[ ! -e $work/buildSucceeded ]] ; then echo 'Unable to connect to VPS worker, it may not have booted correctly ' 1>&2 ; \return 1 ; fi
}
