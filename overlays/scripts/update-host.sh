# 1: targetHost

set -o pipefail -u

targetHost=${1:?}
predicate=${2:-switch}

storePath=$( @{pkgs.push-flake!getExe} ssh://"$1" . )

ssh "$1" -- nixos-rebuild --flake path://"$storePath" "$predicate"
