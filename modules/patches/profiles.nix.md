/*

# `nixpkgs` Profiles as Options

The "modules" in `<nixpkgs>/nixos/modules/profile/` define sets of option defaults to be used in certain contexts.
Unfortunately, they apply their options unconditionally once included, and NixOS' module system does not allow conditional imports.
This wrapper makes it possible to apply a profile based on the value of `config.profiles.<profile>.enable` (defaulting to `false`).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: { config, pkgs, lib, modulesPath, ... }: let lib = inputs.self.lib.__internal__; in {

    imports = lib.remove null (lib.mapAttrsToList (file: type: if type == "regular"
        && file != "hardened.nix" # only(!) this one has an enable option
        && file != "macos-builder.nix" # importing does not work; don't care
        && file != "nix-builder-vm.nix" # uses disabledModules to "solve" the no-state-version problem
    then lib.fun.mkOptionalModule [ "profiles" (lib.removeSuffix ".nix" file) "enable" ] "${modulesPath}/profiles/${file}" else null) (builtins.readDir "${modulesPath}/profiles/"));

}
