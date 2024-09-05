
declare-flag install-system no-root-key "" 'Skip decryption and installation of the hosts root key (`config.wip.services.secrets.rootKeyEncrypted` to `builtins.head config.age.identityPaths`), even if the `secrets` module is enabled and configured.'

function prepare-installer--secrets {
    if [[ ! @{config.wip.services.secrets.enable:-} || ! @{config.wip.services.secrets.rootKeyEncrypted:-} || ${args[no-root-key]:-} ]] ; then return ; fi
    if [[ ${args[no-vm]:-} && "$(id -u)" == '0' && -e /tmp/shared/ssh_host_ed25519_key ]] ; then # inside vm
        rootKeyDir=/tmp/shared
    else
        rootKeyDir=$( mktemp -d ) && prepend_trap 'rm -rf $rootKeyDir' EXIT || exit
        @{native.nix}/bin/nix --extra-experimental-features 'nix-command flakes' run @{inputs.self}'#'secrets -- --decrypt @{config.wip.services.secrets.secretsDir:?}/@{config.wip.services.secrets.rootKeyEncrypted:?}.age | install /dev/stdin -m 600 $rootKeyDir/ssh_host_ed25519_key || exit
        args[vm-shared]=$rootKeyDir
    fi
}

function post-mount--secrets {
    if [[ ! @{config.wip.services.secrets.enable:-} || ! @{config.wip.services.secrets.rootKeyEncrypted:-} || ${args[no-root-key]:-} ]] ; then return ; fi
    if [[ ! ${rootKeyDir:-} || ! -e $rootKeyDir/ssh_host_ed25519_key ]] ; then echo "Root key is missing: »$rootKeyDir«" >&2 ; \return 1 ; fi
    #local target=/etc/ssh/ssh_host_ed25519_key ; if [[ -L $target ]] ; then target=$( readlink @{config.system.build.toplevel}$target ) ; fi
    local target=@{config.age.identityPaths!head:?}
    mkdir -p $mnt/$( dirname "$target" )
    ( ${_set_x:-:} ; install -m 600 -o root -g root -T $rootKeyDir/ssh_host_ed25519_key $mnt/"$target" ) || exit
}

copy-function prompt-for-user-passwords{,--before-secrets}
function prompt-for-user-passwords { # (void)
    if [[ ! @{config.wip.services.secrets.enable:-} ]] ; then prompt-for-user-passwords--before-secrets ; return ; fi
    declare -g -A userPasswords=( ) # (this ends up in the caller's scope)
    local user ; for user in "@{!config.users.users!catAttrSets.password[@]}" ; do # Also grab any plaintext passwords for testing setups.
        userPasswords[$user]=@{config.users.users!catAttrSets.password[$user]}
    done
    #assume that other (hashed) passwords are in secrets # TODO: read those (not hashed)?
    #"@{!config.users.users!catAttrSets.hashedPasswordFile[@]}"
    #"@{!config.users.users!catAttrSets.passwordFile[@]}"
}
