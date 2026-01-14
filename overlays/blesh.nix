dirname: inputs: final: prev: { blesh = prev.blesh.overrideAttrs (old: {

    # instead of using the patched sources in cwd, the blesh build explicitly copies the $src input -.-
    src = final.applyPatches { src = old.src; patches = [ ../patches/blesh/ignore-owner.patch ]; };

}); }
