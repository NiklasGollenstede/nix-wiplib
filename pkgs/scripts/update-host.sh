set -o pipefail -u

description="Updates the NixOS configuration running on a host via SSH.
"
argvDesc='[sshHostname=$(hostname)] [verb=switch] [...nix options]'
declare -g -A allowedArgs=(
    [--name=<string>]="Optional name of the »nixosConfigurations« attribute to use as the target host's configuration. Uses the output of »hostname« run on the target, if not supplied."
    [--remote-eval]="Perform the evaluation on the target system after using »push-flake«"
    [--spec=<string>]='"Specialisation" to switch to.'
)
details="
This script uses Nix locally (and when exported by a flake that flake's nixpkgs' Nix version) to evaluate the host configuration, then pushes the build instructions (derivation files) to the target, and builds (derives) them there, before applying them according to »verb« (this means that the command fails quickly and without traces when the evaluation fails, but copying derivation files, if many derivations have changed, can be oddly slow).

»sshHostname« can be a »[user@]hostname/IP« combo that will be used as host argument for OpenSSH and as a Nix »ssh://«-URL; if not provided, it and »--name« default to »\$( hostname )« run locally.
»verb« can be »build« to only build the configuration (on the target in »~/result«), »activate« to only call it's »result/activate« script, or any verb accepted by »result/bin/switch-to-configuration«. »verb« defaults to »switch«, which is the default NixOS update mode, handling changes to systemd units and calling »switch-to-configuration« but not rebooting.
Any extra arguments are passed to the nix eval and build commands, so something like »-- --debugger --keep-going« can be useful.
"

PATH=@{pkgs.coreutils}/bin:@{pkgs.openssh}/bin:@{pkgs.git}/bin:@{pkgs.hostname-debian}/bin:@{pkgs.gnugrep}/bin:@{pkgs.nix}/bin

generic-arg-parse "$@" || exit
generic-arg-help "update-host" "$argvDesc" "$description" "$details" || exit # requires coreutils
exitCode=2 generic-arg-verify || exit
#if [[ ${argv[0]:-} == -* ]] ; then echo 'Hostname may not start with a dash' >&2 ; exit 1 ; fi
if [[ ${argv[0]:-} == -* ]] ; then argv=( '' "${argv[@]}" ) ; exit 1 ; fi
if [[ ${argv[1]:-} == -* ]] ; then argv=( "${argv[0]:-}" '' "${argv[@]:1}" ) ; fi
targetHost=${argv[0]:-$( hostname )}
predicate=${argv[1]:-switch}

#[[ targetHost =~ ^[a-z0-9-]+$ ]]
if [[ ! ${argv[0]:-} && ! ${args[name]:-} ]] ; then args[name]=$targetHost ; fi
hostname=${args[name]:-$( ssh "$targetHost" -T -- hostname )} || exit

if [[ ! ${args[remote-eval]:-} ]] ; then
    drvPath=$( nix eval --extra-experimental-features 'nix-command flakes' --raw .#nixosConfigurations."$hostname".config.system.build.toplevel.drvPath "${argv[@]:2}" ) || exit
    nix --extra-experimental-features nix-command copy --to ssh://"$targetHost" --derivation "$drvPath^*" || exit
else
    drvPath=path:$( @{pkgs.push-flake!getExe} "$targetHost" . )#nixosConfigurations."$hostname".config.system.build.toplevel || exit
fi

ssh -q -t "$targetHost" -- "$( function remote { set -o pipefail -u
    drvPath=$1 ; shift ; predicate=$1 ; shift ; spec=$1 ; shift
    function version-gr-eq { printf '%s\n%s' "$1" "$2" | LC_ALL=C sort -C -V -r ; }
    output= ; if version-gr-eq "$( nix --version | grep -Poe '\d+.*' )" '2.14' ; then output='^out' ; fi
    if [[ $predicate == build ]] ; then
        nix --extra-experimental-features nix-command build --keep-going "${drvPath/.drv/.drv$output}" "$@" || return
        return
    else
        systemPath=$( nix --extra-experimental-features nix-command build --keep-going --no-link --print-out-paths "${drvPath/.drv/.drv$output}" "$@" ) || return
    fi
    sudo= ; if [[ ${UID:-0} != "$( stat -c %u /nix 2>/dev/null || echo 0 )" ]] ; then sudo=sudo ; fi
    $sudo nix-env -p /nix/var/nix/profiles/system --set "$systemPath" || return
    if [[ $predicate == activate ]] ; then
        $sudo "$systemPath"/"${spec:+specialisation/"$spec"/}"activate || return
    else
        $sudo "$systemPath"/"${spec:+specialisation/"$spec"/}"/bin/switch-to-configuration "$predicate" || return
    fi
} ; declare -f remote ) ; remote $( printf ' %q' "$drvPath" "$predicate" "${args[spec]:-}" "${argv[@]:2}" )" || exit
