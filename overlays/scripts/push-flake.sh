set -o pipefail -u

description="Pushes a Nix »flake« (default: .) and its local inputs to a remote »target« host's /nix/store.
"
argvDesc='target [flake]'
declare -g -A allowedArgs=(
    [--types=indirect,path]="The types of input flakes that will be pushed. Should include all types that the remote won't be able to pull itself."
)
details="
»target« can be a plain (SSH) hostname/IP or any valid Nix store URL.
»flake« should be a local filesystem path. It can also be a »git+file://«-URL, but in that case »dir« is the only supported parameter. Defaults to ».«.
"

generic-arg-parse "$@" || exit
generic-arg-help "push-flake" "$argvDesc" "$description" "$details" || exit
exitCode=2 generic-arg-verify || exit

targetStore=${argv[0]:?}
if [[ $targetStore != *://* ]] ; then
    targetStore='ssh://'$targetStore
fi

flakeSpec=${argv[1]:-.}
if [[ $flakeSpec == git+file:///* ]] ; then
    flakeLock=${flakeSpec##git+file://}
    flakeLock=${flakeLock/?dir=//}/flake.lock
else
    flakeSpec=$( @{pkgs.coreutils}/bin/realpath "$flakeSpec" ) || exit
    flakeLock=$flakeSpec/flake.lock
fi

storePaths=( $( PATH=@{pkgs.git}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' eval --impure --expr '{ flakeLock, flakeSpec, localTypes, }: { result = let
    lock = builtins.fromJSON (builtins.readFile flakeLock);
    flake = builtins.getFlake flakeSpec; inherit (flake) inputs;
    to-outPath = builtins.listToAttrs (map (input: { name = input.narHash; value = input.outPath; }) (let getInputs = flake: [ flake ] ++ (map getInputs (builtins.attrValues (flake.inputs or { }))); in flatten (map getInputs (builtins.attrValues inputs))));
    flatten = x: if builtins.isList x then builtins.concatMap (y: flatten y) x else [ x ];
    types = builtins.filter builtins.isString (builtins.split "," localTypes);
in builtins.concatStringsSep " " ([ flake.outPath ] ++ (map (name: (
    to-outPath.${lock.nodes.${name}.locked.narHash}
)) (
    builtins.filter (name: lock.nodes.${name}?original && (builtins.elem lock.nodes.${name}.original.type types)) (builtins.attrNames lock.nodes)
))); }' --argstr flakeLock "$flakeLock" --argstr flakeSpec "$flakeSpec" --argstr localTypes "${args[types]:-indirect,path}" --raw -- result ) ) || exit
: ${storePaths[0]:?}

PATH=@{pkgs.openssh}/bin:@{pkgs.hostname-debian}/bin:@{pkgs.gnugrep}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' copy --to "$targetStore" ${storePaths[@]} || exit ; echo ${storePaths[0]}
# ¿¿Why does something there call »hostname -I«, which is apparently only available in the debian version of hostname??
