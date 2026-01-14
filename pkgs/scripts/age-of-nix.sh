set -o pipefail -u ; callerPATH=$PATH ; PATH=@{pkgs.coreutils}/bin

## Note that to work completely, this script expects @{args.*} to be passed in by the »mkSecretsApp« function in `../../lib/secrets.nix`.
## Without those, it works (untested) in `agenix` compatibility mode.

secretsDirText=@{args.secretsDir:-'${SECRETS_DIR:-./secrets}'}

binaryName=age-of-nix ; if [[ @{args.appName:-} ]] ; then binaryName='nix run .#'@{args.appName}' --' ; fi
description="»age-of-nix« is a management tool for age(nix) secrets. It is an extended (and mostly backwards-compatible) reimplementation of the »agenix« tool, which is a Nix wrapper around the »age« encryption tool.
"
argvDesc='[[operation:[options:]]secret ...]'
declare -g -A allowedArgs=(
    [--identity=privateKeyPath]='Explicitly provide the private key to use for »decrypt«, »edit« and »rekey« operations.'
    [-e, --edit]='Set the default operation to »edit«, which decrypts the secret (if it existed) to a temporary file, opens it in the »$EDITOR«, and (re-)encrypts it afterwards.'
    [-r, --rekey]='Set the default operation to »rekey«, which decrypts the secret and re-encrypts it for the currently declared targets.'
    [-d, --decrypt]='Set the default operation to »decrypt«, which decrypts the secret to the path in »options« (with mode 0600) or stdout.'
    [-E, --encrypt]='Set the default operation to »encrypt«, which encrypts the file (path) in »options« (which could be a substituted command: »<( echo foo )«) or the entirety of stdin to the secret.'
    [-s, --genkey-ssh]='Set the default operation to »genkey-ssh«, which generates and encrypts an (ed25519) SSH private key and saves the public key in »${secret%.age}.pub«. »options«, if set, becomes the pub keys comment.'
    [-t, --genkey-tls]='Set the default operation to »genkey-tls«, which generates and encrypts a TLS private key (result untested)'
    [-w, --genkey-wg]='Set the default operation to »genkey-wg«, which generates and encrypts a WireGuard private key and saves the public key in »${secret%.age}.pub«.'
    [-p, --genkey-mkpasswd]='Set the default operation to »genkey-mkpasswd«, which prompts for a password or reads it from file »options«, hashes it with »mkpasswd« and encrypts it.'
    [-R, --genkey-random]='Set the default operation to »genkey-random«, which generates a random string using openssh (32 base64 chars) and encrypts it. »options« may override the arguments to openssh (default: »-base64 32«).'
    [-x, --trace]="Enable debug tracing in this script."
)
details='
Compared to »agenix«, this version allows inferring the »$RULES«/»./secrets.nix« directly from your NixOS configurations, and supports various key generation schemes, and manipulating multiple keys in one call.

The positional arguments are a sequence of secrets manipulation operations, each consisting of the »operation« name, an optional »options« string, and the »secret« path.
The »'"$secretsDirText"'« prefix and ».age« suffix in the »secret« paths are optional.
The operation names are the operations »edit«, »rekey«, »de-«/»encrypt« and various »genkey-*« operations, as documented above. If a default-operation option is provided, the individual secret'"'"'s operation may be omitted in favor of the default operation.
Whether the »options« string may be provided and what it means depends on the operation.

Examples:
# For a new host, generate the host key and some secrets it can decrypt with it:
$ age-of-nix -- genkey-ssh:ssh/hosts/host@host1 genkey-ssh::ssh/service/backup@host1 genkey-wg::wg/wg0@host1 genkey-mkpasswd::shadow/user1

# Write some fixed text to encrypted secrets:
$ age-of-nix encrypt:<( echo secret-foo ):dummy/foo encrypt:<( echo secret-bar ):dummy/bar

# Rekey all user passwords for a new host:
$ age-of-nix --rekey -- genkey-ssh::ssh/hosts/host@newHost $secretsDir/shadow/*
'

invalidArgs=2
missingFile=3

exitCodeOnError=$invalidArgs shortOptsAre=flags generic-arg-parse "$@" || exit
shortOptsAre=flags generic-arg-help "$binaryName" "$argvDesc" "$description" "$details" || exit
exitCodeOnError=$invalidArgs generic-arg-verify || exit

if [[ ${args[trace]:-} ]] ; then declare -p args argv ; set -x ; fi

exitCodeOnError=$missingFile ; eval "@{inputs.functions.lib.intoFlakeDir}" ; unset exitCodeOnError

secretsDir=@{args.secretsDir:-${SECRETS_DIR:-./secrets}}
if [[ ! -d $secretsDir ]] ; then echo "Secrets directory »$secretsDir« does not exist." >&2 ; exit $missingFile ; fi

function operation-unset { # 1: secretFullPath
    echo "Neither default operation nor explicit operation for »$1« is set." >&2 ; exit $invalidArgs
}
function no-options { # 1: secretFullPath, 2?: options
    if [[ $2 ]] ; then echo "No options allowed for »$1«." >&2 ; exit $invalidArgs ; fi
}

needReEval= # a previous operation changed the (public) secret files
secretsJSON=@{args.secretsJSON}
agenixCompat= ; if [[ ! $secretsJSON ]] ; then agenixCompat=1 ; {
    secretsJSON=$( @{pkgs.nix}/bin/nix-instantiate --json --eval --strict -E '{ rules, }: import rules' --argstr rules "$RULES" ) || exit
} ; fi
function get-recipients { # 1: secretFullPath
    if [[ $needReEval && ! $agenixCompat ]] ; then
        secretsJSON=$( @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' eval --raw .#.apps.@{pkgs.stdenv.hostPlatform.system}.@{args.appName}.derivation.secretsJSON ) || return
    fi
    recipients=$( <<<$secretsJSON @{pkgs.jq!getExe} -r --arg path "$1" '.[$path].publicKeys[]' ) || true
    if [[ ! $recipients ]] ; then
        echo "No recipients declared for secret »$1«." >&2 ; exit $missingFile
    fi
    printf '%s\n' "$recipients"
}

identity=
function init-identity {
    if [[ $identity ]] ; then return 0 ; fi
    if [[ ${args[identity]:-} ]] ; then
        identity=${args[identity]}
        if [[ $identity == rsa ]] ; then identity="$HOME"/.ssh/id_rsa ; fi
        if [[ $identity == ed || $identity == ed25519 ]] ; then identity="$HOME"/.ssh/id_ed25519 ; fi
    else
        if [[ ! @{args.fallbackPrivateKeyPath} ]] ; then
            echo "No identity file provided, and no fallback configured." >&2 ; exit $invalidArgs
        fi
        identity=$( eval "@{args.fallbackPrivateKeyPath}" )

        if [[ ! $identity ]] ; then
            echo "Fallback identity generation failed." >&2 ; exit $invalidArgs
        fi
    fi
    if [[ ! -r $identity ]] ; then echo "Identity file »$identity« does not exist or is not readable." >&2 ; exit $missingFile ; fi
}

tmpFile=
function init-tmpFile {
    if [[ $tmpFile ]] ; then return 0 ; fi
    # Use XDG_RUNTIME_DIR as it is a tmpfs and readable by the current user only.
    tmpFile=$XDG_RUNTIME_DIR/age-of-nix-tmpfile-$RANDOM # should only be called from environments where XDG_RUNTIME_DIR exists
    trap "rm -f $( printf %q "$tmpFile")" EXIT || return
}

function git-track { # 1: path
    if @{pkgs.git!getExe} ls-files --error-unmatch "$1" &>/dev/null ; then return 0 ; fi
    touch "$1" || return ; @{pkgs.git!getExe} update-index --add "$1" || return
}

function encrypt-stdin-to { # 1: secretFullPath
    mkdir -p "$( dirname "$1" )" || return
    @{pkgs.age}/bin/age --encrypt --recipients-file <( get-recipients "$1" ) --output "$1" || return
}
function decrypt-to-stdout { # 1: secretFullPath
    init-identity || return
    @{pkgs.age}/bin/age --decrypt --identity "$identity" "$1" || return
}

function operation-edit { # 1: secretFullPath, 2?: options=
    init-tmpFile || return ; no-options "$1" "$2" || return
    if [[ -s $1 ]] ; then
        decrypt-to-stdout "$1" >"$tmpFile" || return
    else : >"$tmpFile" ; fi
    PATH=$callerPATH ${EDITOR:?} "$tmpFile" || return
    encrypt-stdin-to "$1" <"$tmpFile" || return ; rm -f "$tmpFile" || true
}
function operation-rekey { # 1: secretFullPath, 2?: options=
    init-tmpFile || return ; no-options "$1" "$2" || return
    decrypt-to-stdout "$1" >"$tmpFile" || return
    encrypt-stdin-to "$1" <"$tmpFile" || return ; rm -f "$tmpFile" || true
}
function operation-decrypt { # 1: secretFullPath, 2?: options=path
    if [[ $2 ]] ; then
        decrypt-to-stdout "$1" | @{pkgs.coreutils}/bin/install /dev/stdin -m 600 "$2" || return
    else
        decrypt-to-stdout "$1" || return
    fi
}
function operation-encrypt { # 1: secretFullPath, 2?: options=path
    if [[ $2 ]] ; then
        encrypt-stdin-to "$1" <"$2" || return
    else
        encrypt-stdin-to "$1" || return
    fi
}

function operation-genkey-ssh { # 1: secretFullPath, 2?: options=comment
    comment=${2:-${1%.age}} ; init-tmpFile || return
    @{pkgs.openssh}/bin/ssh-keygen -q -N "" -t ed25519 -f "$tmpFile" -C "$comment" || return
    encrypt-stdin-to "$1" <"$tmpFile" || return ; rm -f "$tmpFile" || true
    git-track "${1%.age}".pub || return
    needReEval=1 # some other secret may use this pub key
    mv -f "$tmpFile".pub "${1%.age}".pub || return
}
function operation-genkey-tls { # 1: secretFullPath, 2?: options=hostname
    hostname=$2 ; keyOpts=( -algorithm ED25519 ) #; keyOpts=( -algorithm RSA -pkeyopt rsa_keygen_bits:2048 )
    private=$( @{pkgs.openssl!getExe} genpkey "''${keyOpts[@]}" -out - ) || return
    encrypt-stdin-to "$1" <<<"$private" || return
    #read -p "For a self-signed CA with a signed server certificate, enter the certs hostname. If empty, an unnamed (client) certificate will be created: " hostname
    # Not sure this makes any sense:
    ext=ca ; [[ $hostname ]] || ext=crt
    git-track "${1%.age}".$ext || return
    @{pkgs.openssl!getExe} req -new -x509 -days 36500 -subj "/CN=-" -key /dev/stdin <<<"$private" -out "${1%.age}".$ext || return
    if [[ $hostname ]] ; then
        git-track "${1%.age}".crt || return
        @{pkgs.openssl!getExe} req -new -subj "/CN=$hostname" -key /dev/stdin <<<"$private" |
        @{pkgs.openssl!getExe} x509 -req -CA "${1%.age}".ca -CAkey <( cat <<<"$private" ) -set_serial 01 -out "${1%.age}".crt -days 36500
    fi
}
function operation-genkey-wg { # 1: secretFullPath, 2?: options=
    no-options "$1" "$2" || return
    private=$( @{pkgs.wireguard-tools}/bin/wg genkey ) || return
    encrypt-stdin-to "$1" <<<"$private" || return
    git-track "${1%.age}".pub || return
    @{pkgs.wireguard-tools}/bin/wg pubkey <<<"$private" >${1%.age}.pub || return
}
function operation-genkey-mkpasswd { # 1: secretFullPath, 2?: options=path
    if [[ $2 ]] ; then
        private=$( @{pkgs.mkpasswd!getExe} --method=sha-512 --stdin <"$2" ) || return
    else
        private=$( @{pkgs.mkpasswd!getExe} --method=sha-512 ) || return
    fi
    encrypt-stdin-to "$1" <<<"$private" || return
}
function operation-genkey-random { # 1: secretFullPath, 2?: options=args
    private=$( @{pkgs.openssl!getExe} rand ${2:- -base64 32 } ) || return
    printf "Generated random key in %s: %s\n" "$1" "$private"
    encrypt-stdin-to "$1" <<<"$private" || return
}

defaultOperation=
for operation in edit rekey decrypt genkey-ssh genkey-tls genkey-wg genkey-mkpasswd genkey-random ; do
    if [[ ${args[$operation]:-} ]] ; then
        if [[ $defaultOperation ]] ; then echo "Multiple default operations specified: »$defaultOperation« and »$operation«" >&2 ; exit $invalidArgs ; fi
        defaultOperation=$operation
    fi
done
defaultOperation=${defaultOperation:-unset}

if [[ $defaultOperation == rekey && ${#argv[@]} == 0 ]] ; then
    echo "Rekeying of all secrets not implemented yet." >&2 ; exit 4 # TODO!
fi

for spec in "${argv[@]}" ; do
    # parse [[operation:[options:]]secret
    [[ $spec =~ ^([^:]*:)?([^:]*:)?(.+)$ ]] || true
    operation=${BASH_REMATCH[1]%:}
    options=${BASH_REMATCH[2]%:}
    secret=${BASH_REMATCH[3]}

    if [[ $secret != $secretsDir/* ]] ; then secret=$secretsDir/$secret ; fi
    if [[ $secret != *.age ]] ; then secret=$secret.age ; fi

    if [[ ! -s $secret ]] ; then
        if [[ $operation == rekey || $operation == decrypt ]] ; then
            echo "Can't $operation non-existing secret »$secret«." >&2 ; exit $missingFile
        fi
        if [[ ! -e $secret ]] ; then
            mkdir -p "$( dirname "$secret" )" || exit
            needReEval=1 # got to find out which recipients need this
        fi
        git-track "$secret" || exit
    fi

    operation-"${operation:-$defaultOperation}" "$secret" "$options" || exit

done
