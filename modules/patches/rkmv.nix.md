/*

# Fixes for RKVM

I wrote a PR for this, it was ignored and is now outdated after a bunch of formatting changes.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.services.rkvm;
    toml = pkgs.formats.toml { };
in {

    options.services.rkvm = lib.genAttrs [ "client" "server" ] (component: {
        passwordFile = lib.mkOption {
            description = ''
                Path to a file whose contents will be substituted for {option}`.settings.password` at runtime, to avoid placing the password in the nix store.

                The password (i.e., contents of this file) must natch between the server and all connecting clients.
            '';
            type = lib.types.nullOr lib.types.path; default = null;
        };
        useOwnSlice = lib.mkEnableOption ''
            running the rkvm ${component} service with higher priority.
            You can try this on the server and/or client when the forwarding, esp. the cursor, stutters even on a stable network connection.

            Specifically, this moves the server and/or client from `system.slice` into a new `rkvm.slice`, that is on the same hierarchical level as `system.slice` and `user.slice`.
            In case of resource contention, the `rkvm-${component}.service` will thus (by default) have the same priority as all other services (or user processes) combined.
        '';
    });

    config = lib.mkIf cfg.enable {
        assertions = [ {
            assertion = cfg.client.settings.password == "" && cfg.server.settings.password == "";
            message = ''Don't use `cfg.client.settings.password` or `cfg.server.settings.password`, see `.passwordFile`.'';
        } ];
        services.rkvm = lib.genAttrs [ "client" "server" ] (component: {
            settings.password = lib.mkOptionDefault "";
        });
        systemd.services = (lib.flip lib.fun.mapMerge) [ "client" "server" ] (component: let
            compCfg = cfg.${component};
        in { "rkvm-${component}" = lib.mkIf compCfg.enable { serviceConfig = {
            ExecStart = lib.mkForce (pkgs.writeShellScript "rkvm-${component}-start" ''
                ${cfg.package}/bin/rkvm-${component} ${if compCfg.passwordFile == null then (
                    toml.generate "rkvm-${component}.toml" compCfg.settings
                ) else ''<(
                    settings=$( cat ${
                        toml.generate "rkvm-${component}.toml" (compCfg.settings // { password = "REPLACE_PASSWORD"; })
                    } )
                    printf '%s\n' "''${settings/REPLACE_PASSWORD/$(
                        cat ${lib.escapeShellArg compCfg.passwordFile}
                    )}"
                )''}
            '');
            Slice = lib.mkIf cfg.${component}.useOwnSlice "rkvm.slice";
            # No reason to wait 5s in the beginning:
            RestartSec = lib.mkForce "25ms"; RestartSteps = 20; RestartMaxDelaySec = "5s"; # apparently, this does not decrease again: https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdResettingUnitBackoff
        }; unitConfig = {
            StartLimitIntervalSec = 0;
        }; }; });

        systemd.slices.rkvm = lib.mkIf (cfg.client.useOwnSlice || cfg.server.useOwnSlice) { };
    };
}
