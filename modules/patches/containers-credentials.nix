dirname: inputs: { config, pkgs, lib, modulesVersion, ... }: let lib = inputs.self.lib.__internal__; in let
in {

    options.containers = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ ({ config, ... }: { options = {

        credentials = lib.mkOption {
            description = ''
                Host files to be exposed inside the container as read-only systemd credentials.
            '';
            type = lib.fun.types.attrsOfSubmodules ({ name, ... }: { options = {
                name = lib.mkOption { description = "Symbolic name, taken from the config attribute name."; type = lib.types.str; default = name; readOnly = true; };
                hostPath = lib.mkOption { description = ''
                    Path of the root-readable credential file on the host.
                    Changing the path value trigger a container reload, changing the content of the referenced file does not.
                ''; type = lib.types.types.pathWith { inStore = false; absolute = true; }; };
                containerPath = lib.mkOption { description = "Output path of the credential file inside the container."; type = lib.types.types.path; readOnly = true; default = "/run/credentials/@system/nixos-${name}"; };
            }; });
            default = { };
        };

    }; config = {

        extraFlags = lib.mapAttrsToList (name: cfg: "--load-credential=nixos-${name}:${cfg.hostPath}") config.credentials;

    }; }) ]); };

}
