dirname: inputs@{ nixpkgs, functions, installer, ...}: let
    categories = functions.lib.importAll inputs dirname;
    categories' = (builtins.removeAttrs categories [ "setup-scripts" ]);
    self = (builtins.foldl' (a: b: a // (if builtins.isAttrs b && ! b?__functor then b else { })) { } (builtins.attrValues categories')) // categories;
in self // { __internal__ = nixpkgs.lib // { wip = self; fun = functions.lib; inst = installer.lib; }; }
