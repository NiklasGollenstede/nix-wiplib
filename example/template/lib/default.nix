dirname: inputs: let
    categories = inputs.functions.lib.importAll inputs dirname;
    self = (builtins.foldl' (a: b: a // (if builtins.isAttrs b && ! b?__functor then b else { })) { } (builtins.attrValues categories)) // categories;
in self // { __internal__ = inputs.nixpkgs.lib // {
    self = self; # might want to name this differently
    fun = inputs.functions.lib; inst = inputs.installer.lib; wip = inputs.wiplib.lib;
}; }
