# To use -i, instead of calling this script as a program, source it inside a function and call that: function with { local supportInline=1 ; source .../with.sh ; }
if local &>/dev/null ; then local declare=local return=return ; else declare declare=declare return=exit ; fi

#[[ $( </etc/nix/registry.json jq '.flakes[]|select(.from.id == "syspkgs")|any' 2>/dev/null ) ]]
$declare nixpkgs=nixpkgs ; if grep -qe '"from":{"id":"syspkgs","type":"indirect"' -- /etc/nix/registry.json 2>/dev/null ; then nixpkgs=syspkgs ; fi

$declare help="Synopsys:
    With the Nix packages »PKG«s, run »CMD« with »ARG«s.
Usage:
    $ with PKG... [-- [CMD [ARG...]]]
    $ with PKG... [. [ARG...]]
    $ with [-e]${supportInline:+ [-i]} [-l] [-t] PKG...
    $ with [-h?|--help] ...
Details:
    Each »PKG« may be a name (or attribute path) of a package in »$nixpkgs«, or an explicit flake output reference.
    If no »CMD« is supplied in the first form, it defaults to the current »\$SHELL«.
    The second form is a slight shortcut, where »CMD« is the same as the last »PKG« entry.
    ${supportInline:+"With »-i«, the packages are added to the »\$PATH« of the current shell. "}With »-e«/»-l«/»-t«, the package paths are echoed, their »bin/« dirs are listed, or their outputs are listed recursively with »tree«, respectively.
"

$declare -a pkgs ; pkgs=( ) ; $declare last= eval= echo= inline= list= tree= ; while (( "$#" > 0 )) ; do {
    if [[ $1 == -h || $1 == '-?' || $1 == --help ]] ; then echo "$help" ; $return 0 ; fi
    if [[ $1 == -e ]] ; then shift ; eval=1 ; echo=1 ; continue ; fi
    if [[ $1 == -i && ${supportInline:-} ]] ; then shift ; eval=1 ; inline=1 ; continue ; fi
    if [[ $1 == -l ]] ; then shift ; eval=1 ; list=1 ; continue ; fi
    if [[ $1 == -t ]] ; then shift ; eval=1 ; tree=1 ; continue ; fi
    if [[ $1 == -- ]] ; then shift ; break ; fi
    if [[ $1 == -* ]] ; then echo "Unknown option: $1, see »with --help«." >&2 ; $return 1 ; fi
    if [[ $1 == . ]] ; then shift ; last=${last##*#} ; last=${last##.#} set -- "$last" "$@" ; break ; fi
    last="$1" ; if [[ $1 != */* && $1 != *#* ]] ; then pkgs+=( flake:"$nixpkgs"'#'"$1" ) ; else pkgs+=( "$1" ) ; fi
} ; shift ; done
if (( ${#pkgs[@]} == 0 )) ; then echo "No packages specified, see »with --help«." 1>&2 ; $return 1 ; fi

$declare features ; features=( --extra-experimental-features 'nix-command flakes' )
if [[ $eval ]] ; then
    if (( "$#" != 0 )) ; then echo "No command/arguments allowed with -e${supportInline:+/-i}/-l/-t, see »with --help«." >&2 ; $return 1 ; fi
    $declare paths ; paths=( $( nix "${features[@]}" build --no-link --print-out-paths "${pkgs[@]}" ) ) || $return
    if [[ $echo ]] ; then
        printf '%s\n' "${paths[@]}"
    fi
    if [[ $list ]] ; then
        ls ${paths[@]/%/'/bin'} || true
    fi
    if [[ $tree ]] ; then
        tree -a -p -g -u -s -D -F --timefmt '%Y-%m-%d %H:%M:%S' "${paths[@]}" || $return
    fi
    if [[ $inline ]] ; then
        PATH=$( printf '%s/bin:' ${paths[@]} )$PATH
    fi
else
    if (( "$#" == 0 )) ; then set -- "${SHELL:-/bin/sh}" ; fi
    nix "${features[@]}" shell "${pkgs[@]}" --command "$@"
fi
