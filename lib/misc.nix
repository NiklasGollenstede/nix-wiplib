dirname: inputs: let
    lib = inputs.self.lib.__internal__;
in {

    # Given a flake input (attribute passed to ta flakes `outputs` function), this returns a flake reference (thing that can be passed to a lockfiles `locked` or registries `to` attribute) to the flake.
    # Specifically, this fixes the reference to flakes that are not in the root of their repository (and thus have the `flake.nix` file in a subdirectory in the nix store).
    toFlakeRef = input: (lib.filterAttrs (n: _: n == "lastModified" || n == "narHash" || n == "rev" || n == "revCount") input) // (let
        match = builtins.match ''(${builtins.storeDir}/.*)/(.*)'' input.outPath;
    in if match != null then {
        type = "git"; url = "file://${builtins.elemAt match 0}"; dir = builtins.elemAt match 1;
    } else {
        type = "path"; path = input.outPath;
    });
}
