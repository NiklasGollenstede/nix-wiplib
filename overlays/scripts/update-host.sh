# 1: targetHost

set -o pipefail -u

targetHost=${1:?} ; shift
predicate=${1:-switch} ; shift

#[[ targetHost =~ ^[a-z0-9-]+$ ]]
hostname=$( ssh "$targetHost" -- hostname ) || exit

drvPath=$( nix eval --raw .#nixosConfigurations."$hostname".config.system.build.toplevel.drvPath "$@" ) || exit

PATH=@{pkgs.openssh}/bin:@{pkgs.hostname-debian}/bin:@{pkgs.gnugrep}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' copy --to ssh://"$targetHost" --derivation "$drvPath^*" || exit

ssh -q -t "$targetHost" -- "$( function remote { set -o pipefail -u
	drvPath=$1 ; shift ; predicate=$1 ; shift
	function version-gr-eq { printf '%s\n%s' "$1" "$2" | LC_ALL=C sort -C -V -r ; }
    output= ; if version-gr-eq "$( nix --version | grep -Poe '\d+.*' )" '2.14' ; then output='^out' ; fi
	systemPath=$( nix build --no-link --print-out-paths "$drvPath"$output "$@" ) || exit
	nix-env -p /nix/var/nix/profiles/system --set "$systemPath" || exit
	"$systemPath"/bin/switch-to-configuration "$predicate" || exit
} ; declare -f remote ) ; remote $( printf ' %q' "$drvPath" "$predicate" "$@" )" || exit

exit

while true ; do
	if [[ -e flake.nix ]] ; then flakePath=$PWD ; break ; fi
	cd .. ; if [[ $PWD == / ]] ; then echo 'Unable to locate flake.nix in (parent of) CWD' >&2 ; exit 2 ; fi
done
while true ; do
	if [[ -e .git/config ]] ; then repoPath=$PWD ; break ; fi
	cd .. ; if [[ $PWD == / ]] ; then echo 'Unable to locate .git/config in (parent of) CWD' >&2 ; exit 2 ; fi
done

flakeArgs= ; if [[ $repoPath != "$flakePath" ]] ; then
	flakeArgs=?dir="${flakePath/$repoPath'/'/}"
fi

storePath=$( @{pkgs.push-flake!getExe} ssh://"$targetHost" git+file://"$repoPath""$flakeArgs" )

ssh "$targetHost" -- nixos-rebuild --flake path://"$storePath""$flakeArgs" "$predicate" # XXX: flakeArgs (dir) does not work with »path://« -.-
# could copy the dir on the target and call: git init && git add --all ...
