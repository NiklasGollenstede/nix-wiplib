function with { # (this script needs to be "source"d)

#[[ $( </etc/nix/registry.json jq '.flakes[]|select(.from.id == "syspkgs")|any' 2>/dev/null ) ]]
nixpkgs=nixpkgs ; if </etc/nix/registry.json grep -qe '"from":{"id":"syspkgs","type":"indirect"' 2>/dev/null ; then nixpkgs=syspkgs ; fi

local help="Synopsys: With the Nix packages »PKGS« (implicitly as flake build outputs from $nixpkgs, or explicitly from other flakes), run »CMD« with »ARGS«, or »$SHELL« if no »CMD« is supplied. In the second form, »CMD« is the same as the last »PKGS« entry. With »-i«, add the packages to the current shell's »$PATH«
Usage: with [-h] PKGS... [-- [CMD [ARGS...]]]
       with [-h] PKGS... [. [ARGS...]]
       with [-h] PKGS... -i"

local pkgs=( ) last= inline= ; while (( "$#" > 0 )) ; do {
    if [[ $1 == -h ]] ; then echo "$help" ; return 0 ; fi
    if [[ $1 == -i ]] ; then shift ; inline=1 ; continue ; fi
    if [[ $1 == -- ]] ; then shift ; break ; fi
    if [[ $1 == -* ]] ; then echo "$help" >&2 ; return 1 ; fi
    if [[ $1 == . ]] ; then shift ; set -- "${last##*#}" "$@" ; break ; fi
    last="$1" ; if [[ $1 != */* && $1 != *#* ]] ; then pkgs+=( flake:"$nixpkgs"'#'"$1" ) ; else pkgs+=( "$1" ) ; fi
} ; shift ; done
if (( ${#pkgs[@]} == 0 )) ; then echo "$help" 1>&2 ; return 1 ; fi

local features=( --extra-experimental-features 'nix-command flakes' )
if [[ $inline ]] ; then
    if (( "$#" != 0 )) ; then echo "$help" >&2 ; return 1 ; fi
    local paths ; paths=( $( nix "${features[@]}" build --no-link --print-out-paths "${pkgs[@]}" ) ) || return
    PATH=$( printf '%s/bin:' ${paths[@]} )$PATH
else
    if (( "$#" == 0 )) ; then set -- "${SHELL:-/bin/sh}" ; fi
    nix "${features[@]}" shell "${pkgs[@]}" --command "$@"
fi

} # /with
