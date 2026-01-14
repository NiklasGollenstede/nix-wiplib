set -o pipefail -u

systemDesc='the "'@{config.system.name}'"'; if [[ ! @{config.system.name} ]] ; then systemDesc='a specifically prepared' ; fi
description="Boots into $systemDesc NixOS system via »kexec«.
"
argvDesc='[kexec-args...]'
declare -g -A allowedArgs=(
    [--sudo]="Use »sudo« to run »kexec« and to read key files."
    [--doas]="Use »doas« to run »kexec« and to read key files."
    [-r, --reboot]="Cleanly reboot into the new kernel after running »kexec«."
    [-f, --reset]="Immediately/force boot the new system, without shutting down the host system."
    [--override-kernel=path]="Boot the kernel at »path« instead of the one intended for the system."
    [-i, --inherit-ip-setup]="(Try to) copy the current IP setup (addresses and routes) into the new system."
    [-u, --inherit-user-auth]="Copy the host's SSH user authentication (of root and the sudo/doas user) files into the new system (as root)."
    [-k, --inherit-host-keys]="Copy the host's SSH host keys into the new system. This is orthogonal to decrypting a bundled host/root key (»--decrypt-with«)."
    [--decrypt-with=path]="Decrypt the bundled SSH host (and encryption root) key with this private (SSH/age) key. Otherwise, tries the system's host and sudo/doas user's default keys."
    [-x, --trace]="Enable debug tracing in this script."
)
details='
At minimum, this script simply runs »kexec --load«.
It can, though, optionally prepare some host-based ad-hoc configuration and decrypted/inherited secrets beforehand. See the flags above.
'

exitCodeOnError=2 shortOptsAre=flags generic-arg-parse "$@" || exit
shortOptsAre=flags generic-arg-help "kexec-run" "$argvDesc" "$description" "$details" || exit
exitCodeOnError=2 generic-arg-verify || exit

if [[ ${args[trace]:-} ]] ; then declare -p args argv ; set -x ; fi

if [[ @{args.doTar:-} ]] ; then
    SCRIPT_DIR=$( dirname "$( readlink -f "$0" )" ) # (whe way the script is composed not, this will not point to the root/extracted tar)
    PATH=$SCRIPT_DIR:$PATH # some static utilities (which really should be in a ./bin/ subdir) + basic stuff from the host
    kernel=$SCRIPT_DIR/bzImage
    initrd=$SCRIPT_DIR/initrd
    cmdline=$( cat "$SCRIPT_DIR"/cmdline )
    rootKeyEncrypted=$SCRIPT_DIR/rootKey.age
    rootKeyDecrypted=$( readlink "$SCRIPT_DIR"/rootKey.target )
    hasRootKey= ; if [[ -e $rootKeyEncrypted ]] ; then hasRootKey=1 ; fi
else
    sudoPath=$( which sudo 2>/dev/null || true ) ; doasPath=$( which doas 2>/dev/null || true ) ; systemctlPath=$( which systemctl 2>/dev/null || true )
    PATH=@{pkgs.coreutils}/bin:@{pkgs.kexec-tools}/bin:@{pkgs.iproute2}/bin:@{pkgs.age}/bin:@{pkgs.findutils}/bin:@{pkgs.cpio}/bin:@{pkgs.gzip}/bin:@{pkgs.bash}/bin
    kernel=@{config.system.build.kernel}/@{config.system.boot.loader.kernelFile}
    initrd=@{config.system.build.netbootRamdisk}/initrd
    cmdline=init=@{config.system.build.toplevel}/init$( printf ' %s' "@{config.boot.kernelParams[@]}" )
    rootKeyEncrypted=@{args.rootKeyEncrypted}
    rootKeyDecrypted=@{config.age.identityPaths[0]:-}
    hasRootKey=${rootKeyEncrypted:+1}
fi


cd "$( mktemp -d )" ; trap "rm -rf $( printf %q "$PWD" )" EXIT
mkdir -p -m 755 root/extra

sudo= ; if [[ ${args[sudo]:-} ]] ; then sudo=${sudoPath:-sudo} ; elif [[ ${args[doas]:-} ]] ; then sudo=${doasPath:-doas} ; fi
if [[ $sudo ]] ; then sudo="$sudo env PATH=$( printf %q "$PATH" )" ; fi

if [[ ${args[inherit-user-auth]:-} ]] ; then
    cat \
        /root/.ssh/authorized_keys{,2} \
        /etc/ssh/authorized_keys.d/root \
        "$HOME"/.ssh/authorized_keys{,2} \
        ${SUDO_USER:+/etc/ssh/authorized_keys.d/"$SUDO_USER"} \
        ${SUDO_USER:+"$( sh -c "echo ~$( printf %q "$SUDO_USER" )" )"/.ssh/authorized_keys} \
        ${SUDO_USER:+"$( sh -c "echo ~$( printf %q "$SUDO_USER" )" )"/.ssh/authorized_keys2} \
        ${DOAS_USER:+/etc/ssh/authorized_keys.d/"$DOAS_USER"} \
        ${DOAS_USER:+"$( sh -c "echo ~$( printf %q "$DOAS_USER" )" )"/.ssh/authorized_keys} \
        ${DOAS_USER:+"$( sh -c "echo ~$( printf %q "$DOAS_USER" )" )"/.ssh/authorized_keys2} \
    2> /dev/null > authorized_keys || true
    if [[ -s authorized_keys ]] ; then
        mkdir -p -m 700 root/extra/root{,/.ssh} || exit
        install -m 600 authorized_keys root/extra/root/.ssh/authorized_keys || exit
    fi
fi

if [[ ${args[inherit-host-keys]:-} ]] ; then
    for key in /etc/ssh/ssh_host_*; do
        if [[ -e "$key" ]] ; then
            mkdir -p -m 755 root/extra/etc{,/ssh} || exit
            $sudo cat "$key" | install /dev/stdin -m 600 root/extra/etc/ssh/"$( basename "$key" )" || exit
        fi
    done
fi

if [[ $hasRootKey ]] ; then
    identities=( )
    if [[ ${args[decrypt-with]:-} ]] ; then
        identities+=( --identity="${args[decrypt-with]}" )
    else for file in \
        /etc/ssh/ssh_host_{ed25519,rsa}_key \
        "$HOME"/.ssh/id_{ed25519,rsa} \
        ${SUDO_USER:+"$( sh -c "echo ~$( printf %q "$SUDO_USER" )" )"/.ssh/id_ed25519} \
        ${SUDO_USER:+"$( sh -c "echo ~$( printf %q "$SUDO_USER" )" )"/.ssh/id_rsa} \
        ${DOAS_USER:+"$( sh -c "echo ~$( printf %q "$DOAS_USER" )" )"/.ssh/id_ed25519} \
        ${DOAS_USER:+"$( sh -c "echo ~$( printf %q "$DOAS_USER" )" )"/.ssh/id_rsa} \
    ; do if [[ -s $file ]] ; then
        identities+=( --identity="$file" )
    fi ; done ; fi
    if [[ $rootKeyDecrypted == /root/* ]] ; then mkdir -p -m 700 root/extra/root || exit ; fi
    if [[ $rootKeyDecrypted == /root/.ssh/* ]] ; then mkdir -p -m 700 root/extra/root/.ssh || exit ; fi
    mkdir -p =m 755 root/extra/"$( dirname "$rootKeyDecrypted" )" || exit
    $sudo age --decrypt "${identities[@]}" ${rootKeyEncrypted} | install /dev/stdin -m 600 root/extra/"$rootKeyDecrypted" || exit
fi

if [[ ${args[inherit-ip-setup]:-} ]] ; then
    mkdir -p -m 700 root/extra/root{,/network} || exit
    ip --json addr > root/extra/root/network/addrs.json || exit
    ip -4 --json route > root/extra/root/network/routes-v4.json || exit
    ip -6 --json route > root/extra/root/network/routes-v6.json || exit
fi

cp -T "$initrd" initrd && chmod 700 initrd || exit
( cd root/extra ; echo "Including extra files:" >&2 ; find . ! -type d -not -path ./dummy.json -not -path ./ssh/ssh_host_dummy -printf '- /%P\n' )
( cd root && find . -print0 | cpio --null --quiet --create --format=newc --reproducible --owner=+0:+0 | gzip -9 >> ../initrd ) || exit

kexec=( $sudo kexec --load "${args[override-kernel]:-${kernel}}" --initrd=./initrd --command-line "$cmdline" )
if printf "%s\n" "6.1" "$(uname -r)" | sort -c -V 2>&1 ; then kexec+=( --kexec-syscall-auto ) ; fi # https://github.com/nix-community/nixos-anywhere/issues/264
"${kexec[@]}" "${argv[@]}" || exit

if [[ ${args[reboot]:-} ]] ; then
    $sudo ${systemctlPath:-systemctl} kexec
elif [[ ${args[reset]:-} ]] ; then
    echo "Resetting into kexec kernel" >&2
    $sudo kexec --exec
else
    echo "System loaded. Run 'systemctl kexec' or 'kexec --exec' to reboot into the new kernel."
fi
