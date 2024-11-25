set -o pipefail -u

PATH=@{pkgs.nixVersions.nix_2_20}/bin:@{pkgs.jq}/bin:@{pkgs.coreutils}/bin:@{pkgs.git}/bin

# Use the oldest version of Nix that doesn't choke on "dirty" local git inputs for the update:
nix flake update "$@" || exit
# (This will always show all local git inputs as having changed, because it will revert the below patching.)

# Then pretend the git trees have all been clean:
jq '(.nodes |= with_entries(
    .value |= if .locked.dirtyRev then
        (.locked.dirtyRev as $rev | del(.locked.dirtyRev) | del(.locked.dirtyShortRev) | .locked.rev = ($rev | sub("-dirty$"; "")))
    else . end
))' flake.lock > flake.lock.tmp || exit
mv flake.lock.tmp flake.lock || exit
# (Claiming that the former dirtyRev is the locked input's rev is not really correct, but on a local input the rev has no function (other than being printed) anyway.)

# So that new versions of Nix accept the lockfile (should be a no-op):
@{pkgs.nixVersions.latest}/bin/nix flake lock || exit
# (This only works if and because the store paths matching the modified input definitions' narHash exists in the (local) store.)
