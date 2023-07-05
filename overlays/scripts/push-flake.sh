# 1: targetStore, 2?: flakePath

set -o pipefail -u
targetStore=${1:?} ; if [[ $targetStore != *://* ]] ; then targetStore='ssh://'$targetStore ; fi
flakePath=$( @{pkgs.coreutils}/bin/realpath "${2:-.}" ) || exit

storePaths=( $( PATH=@{pkgs.git}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' eval --impure --expr 'let
    lock = builtins.fromJSON (builtins.readFile "'"$flakePath"'/flake.lock");
    flake = builtins.getFlake "'"$flakePath"'"; inherit (flake) inputs;
    to-outPath = builtins.listToAttrs (map (input: { name = input.narHash; value = input.outPath; }) (let getInputs = flake: [ flake ] ++ (map getInputs (builtins.attrValues flake.inputs)); in flatten (map getInputs (builtins.attrValues inputs))));
    flatten = x: if builtins.isList x then builtins.concatMap (y: flatten y) x else [ x ];
in builtins.concatStringsSep " " ([ flake.outPath ] ++ (map (name: (
    to-outPath.${lock.nodes.${name}.locked.narHash}
)) (
    builtins.filter (name: lock.nodes.${name}?original && (lock.nodes.${name}.original.type == "indirect" || lock.nodes.${name}.original.type == "path")) (builtins.attrNames lock.nodes)
)))' --raw ) ) || exit
: ${storePaths[0]:?}

PATH=@{pkgs.openssh}/bin:@{pkgs.hostname-debian}/bin:@{pkgs.gnugrep}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' copy --to "$targetStore" ${storePaths[@]} || exit ; echo ${storePaths[0]}
# ¿¿Why does something there call »hostname -I«, which is apparently only available in the debian version of hostname??
