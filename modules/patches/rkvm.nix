dirname: inputs: { config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.services.rkvm;
    toml = pkgs.formats.toml { };
in {

    options = { services.rkvm = let mkCommonOptions = component: {
        #settings.password = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        settings.password = lib.mkOption { default = "REPLACE_PASSWORD"; };
        passwordFile = lib.mkOption {
            description = ''Path to a file whose contents will be substituted for `.settings.password` at runtime, to avoid placing the password in the nix store.'';
            type = lib.types.nullOr lib.types.path; default = null;
        };
        increasePriority = lib.mkEnableOption "";
    }; in {
        server = mkCommonOptions "server";
        client = mkCommonOptions "client";
    }; };

    config = lib.mkIf cfg.enable {
        systemd.services = let mkBase = component: {
            # (when upstreaming): should use ..script
            serviceConfig = {
                ExecStart = lib.mkIf (cfg.${component}.passwordFile != null) (lib.mkForce (pkgs.writeShellScript "rkvm-${component}-start" ''
                    ${cfg.package}/bin/rkvm-${component} <(
                        settings=$( cat ${toml.generate "rkvm-${component}.toml" (cfg.${component}.settings // { password = "REPLACE_PASSWORD"; })} )
                        printf '%s\n' "''${settings/REPLACE_PASSWORD/$( cat ${lib.escapeShellArg cfg.${component}.passwordFile} )}"
                    )
                ''));
                Slice = lib.mkIf cfg.${component}.increasePriority "rkvm.slice";
            };
        }; in {
            rkvm-server = lib.mkIf cfg.server.enable (mkBase "server");
            rkvm-client = lib.mkIf cfg.client.enable (mkBase "client");
        };
        systemd.slices.rkvm = lib.mkIf (cfg.client.increasePriority || cfg.server.increasePriority) { };
    };

}
