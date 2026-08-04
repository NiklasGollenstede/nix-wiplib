set -o pipefail -u

# using nix from the surrounding env
PATH=@{pkgs.jq}/bin:@{pkgs.coreutils}/bin:@{pkgs.git}/bin:$PATH
eval "@{inputs.functions.lib.intoFlakeDir}" # need flake.lock in CWD

nix flake update "$@" || exit
# (This will always show all local git inputs as having changed, because it will revert the below patching.)

# Then pretend the git trees have all been clean:
jq '(.nodes |= with_entries(
    .value |= if .locked.dirtyRev then
        ( del(.locked.dirtyRev) | del(.locked.dirtyShortRev) | .locked.url = "file:///dev/null" )
    else . end
))' flake.lock > flake.lock.tmp || exit # '.locked.dirtyRev as $rev | .locked.rev = ($rev | sub("-dirty$"; "")) | '
mv flake.lock.tmp flake.lock || exit
# (Claiming that the former dirtyRev is the locked input's rev is not really correct, but on a local input the rev has no function (other than being printed) anyway.)

# Test that nix accepts the lock file (should be a no-op):
nix flake lock || exit
# (This only works if and because the store paths matching the modified input definitions' narHash exists in the (local) store.)
