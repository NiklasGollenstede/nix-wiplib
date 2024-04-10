dirname: inputs: final: prev: let
    inherit (final) pkgs; lib = inputs.self.lib.__internal__;
in lib.mapAttrs (name: path: let
    scripts = lib.fun.substituteImplicit { inherit pkgs; scripts = [ path ]; context = { inherit dirname inputs pkgs lib; }; };
in (
    (pkgs.writeShellScriptBin name ''
        source ${inputs.functions.lib.bash.generic-arg-parse}
        source ${inputs.functions.lib.bash.generic-arg-verify}
        source ${inputs.functions.lib.bash.generic-arg-help}
        ${scripts}
    '').overrideAttrs (old: { passthru = { inherit scripts; }; })
)) (lib.fun.getFilesExt "sh(.md)?" dirname)
