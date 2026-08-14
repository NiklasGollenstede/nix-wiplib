dirname: inputs: final: prev: { blesh = prev.blesh.overrideAttrs (old: let
    lib = inputs.self.lib.__internal__;
in if lib.hasSuffix ".tar.xz" old.src.url then {
    # instead of using the patched sources in cwd, the blesh build explicitly copies the $src input -.-
    src = final.applyPatches { src = old.src; patches = [ ../patches/blesh/ignore-owner.patch ]; };
} else {
    # starting with nixpkgs/854bc198f2d3b2c047fe8bfcc42f7665c7cf2d56 (2026-05-28), blesh is built from source
    patches = (old.patches or [ ]) ++ [ ../patches/blesh/ignore-owner-src.patch ];
}); }
