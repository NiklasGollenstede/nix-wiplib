# To use -i, instead of calling this script as a program, source it inside a function and call that: function with { local supportInline=1 ; source .../with.sh ; }
if local &>/dev/null ; then local declare=local ; else declare declare=declare ; fi

#[[ $( </etc/nix/registry.json jq '.flakes[]|select(.from.id == "syspkgs")|any' 2>/dev/null ) ]]
$declare nixpkgs=nixpkgs ; if </etc/nix/registry.json grep -qe '"from":{"id":"syspkgs","type":"indirect"' 2>/dev/null ; then nixpkgs=syspkgs ; fi

$declare help="Synopsys: With the Nix packages »PKGS« (implicitly as flake build outputs from $nixpkgs, or explicitly from other flakes), run »CMD« with »ARGS«, or ${SHELL##*/} if no »CMD« is supplied. In the second form, »CMD« is the same as the last »PKGS« entry. ${supportsInline:+"With »-i«, add the packages to the current shell's »\$PATH«. "}With »-l«, ls the »bin/« dir of each package output.
Usage: with [-h] PKGS... [-- [CMD [ARGS...]]]
       with [-h] PKGS... [. [ARGS...]]
       ${supportInline:+with [-h] PKGS... -i
       }with [-h] PKGS... -l"

$declare -a pkgs ; pkgs=( ) ; $declare last= inline= list= ; while (( "$#" > 0 )) ; do {
    if [[ $1 == -h || $1 == --help ]] ; then echo "$help" ; return 0 ; fi
    if [[ $1 == -i && ${supportInline:-} ]] ; then shift ; inline=1 ; continue ; fi
    if [[ $1 == -l ]] ; then shift ; list=1 ; continue ; fi
    if [[ $1 == -- ]] ; then shift ; break ; fi
    if [[ $1 == -* ]] ; then echo "$help" >&2 ; return 1 ; fi
    if [[ $1 == . ]] ; then shift ; last=${last##*#} ; last=${last##.#} set -- "$last" "$@" ; break ; fi
    last="$1" ; if [[ $1 != */* && $1 != *#* ]] ; then pkgs+=( flake:"$nixpkgs"'#'"$1" ) ; else pkgs+=( "$1" ) ; fi
} ; shift ; done
if (( ${#pkgs[@]} == 0 )) ; then echo "$help" 1>&2 ; return 1 ; fi

$declare features ; features=( --extra-experimental-features 'nix-command flakes' )
if [[ $inline || $list ]] ; then
    if (( "$#" != 0 )) ; then echo "$help" >&2 ; return 1 ; fi
    $declare paths ; paths=( $( nix "${features[@]}" build --no-link --print-out-paths "${pkgs[@]}" ) ) || return
    if [[ $inline ]] ; then
        PATH=$( printf '%s/bin:' ${paths[@]} )$PATH
    else
        ls ${paths[@]/%/'/bin'} || true
    fi
else
    if (( "$#" == 0 )) ; then set -- "${SHELL:-/bin/sh}" ; fi
    nix "${features[@]}" shell "${pkgs[@]}" --command "$@"
fi
