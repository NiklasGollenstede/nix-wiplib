dirname: inputs: final: prev: let
    inherit (final) pkgs; lib = inputs.self.lib.__internal__;
    defaultContext = { inherit dirname inputs pkgs lib; };
    # E.g.: .override { pkgs = pkgs // { nix = pkgs.nixVersions.nix_2_20; }; }
in lib.mapAttrs (name: path: (lib.makeOverridable (context: let
    scripts = lib.fun.substituteImplicit { inherit pkgs; scripts = [ path ]; inherit context; };
in (
    (pkgs.writeShellScriptBin name ''
        source ${inputs.functions.lib.bash.generic-arg-parse}
        source ${inputs.functions.lib.bash.generic-arg-verify}
        source ${inputs.functions.lib.bash.generic-arg-help}
        ${scripts}
    '').overrideAttrs (old: { passthru = { inherit scripts; }; })
))) defaultContext) (lib.fun.getFilesExt "sh(.md)?" dirname)
