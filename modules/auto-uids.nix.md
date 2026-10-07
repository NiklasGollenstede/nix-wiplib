/*

# Default UID/GID Assignment

Automatically assign declared users and groups the UID/GID from `config.ids.uids`/`config.ids.gids` if available.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: { config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.users;
in {

    options = {
        ${prefix}.users.autoIDs = lib.mkEnableOption "automatic assignment of user and group IDs (`config.users.users.<name>.uid`/`config.users.groups.<name>.gid`) from `config.ids.uids/config.ids.gids` where available.";
        users.users = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }@args: {
                config.uid = lib.mkIf (cfg.autoIDs && config.ids.uids?${name}) (lib.mkDefault config.ids.uids.${name});
            }));
        };
        users.groups = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }@args: {
                config.gid = lib.mkIf (cfg.autoIDs && config.ids.gids?${name}) (lib.mkDefault config.ids.gids.${name});
            }));
        };
    };

}
