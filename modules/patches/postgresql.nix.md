/*

# Auto-upgrade for PostgreSQL

This extends module `services.postgresql` with options to automatically upgrade the databases between consecutive major versions.
Usually, if the database dir matching `services.postgresql.package`'s version does not exist, NixOS will initialize a new blank database there.
With this module, when setting `services.postgresql.prevPackage` to the `.package` used before (only bumps by one major version at a time are supported), it will instead use `pg_upgrade` to migrate the previous database to the new version.
If the upgrade fails, the `postgresql` service won't be started (instead of running on an empty database).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.services.postgresql;
in {

    options = { services.postgresql = {
        prevPackage = lib.mkOption { description = lib.mdDoc ''For automatic major version upgrades/migrations, the PostgreSQL package used before the current `.package`.''; type = lib.types.nullOr lib.types.package; default = null; example = lib.literalExpression "pkgs.postgresql_15"; };
        prevDataDir = lib.mkOption { description = lib.mdDoc ''For automatic major version upgrades/migrations, the previous `.dataDir` (if that was set explicitly).''; type = lib.types.path; };
        upgradeArgs = lib.mkOption { description = lib.mdDoc ''Extra CLI arguments provided to `pg_upgrade` during automatic major version upgrades.''; type = lib.types.listOf lib.types.str; default = [ ]; };
    }; };

    config = lib.mkIf (cfg.enable && cfg.prevPackage != null) (let
        wrap = package: let
            base = if cfg.enableJIT && !package.jitSupport then package.withJIT else package;
            extensions = cfg.extensions or cfg.extraPlugins;
        in if extensions == [ ] then base else base.withPackages extensions;
        esc = lib.escapeShellArg;
    in {
        services.postgresql.prevDataDir = lib.mkDefault "/var/lib/postgresql/${cfg.prevPackage.psqlSchema}";
        systemd.services.postgresql.preStart = lib.mkBefore ''
            curData=${esc cfg.dataDir}
            curBin=${wrap cfg.package}/bin
            prevData=${esc cfg.prevDataDir}
            prevBin=${wrap cfg.prevPackage}/bin

            if [[ ! -e $curData/base ]] ; then ( # (systemd may have created $curData itself)
                mkdir -p -m 700 "$curData" ; cd "$curData"
                $curBin/initdb -D "$curData"
                $curBin/pg_upgrade \
                    --old-datadir "$prevData" --new-datadir "$curData" \
                    --old-bindir $prevBin --new-bindir $curBin \
                    ${lib.escapeShellArgs cfg.upgradeArgs} \
                ;
            ) ; fi
        '';
    });

}
