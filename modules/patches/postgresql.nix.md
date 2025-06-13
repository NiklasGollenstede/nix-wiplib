/*

# Auto-upgrade for PostgreSQL

This extends module `services.postgresql` with options to automatically upgrade the databases between consecutive major versions.
Usually, if the database dir matching `services.postgresql.package`'s version does not exist, NixOS will initialize a new blank database there.
With this module, when setting `services.postgresql.prevPackage` to the `.package` used before the upgrade (only bumps by one major version at a time are supported), it will instead use `pg_upgrade` to migrate the previous database to the new version.
If the upgrade fails, the `postgresql` service won't be started (instead of running on an empty database).

This worked fine to upgrade from 11.1 through to 16.

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.services.postgresql;
in {

    options = { services.postgresql = {
        prevPackage = lib.mkOption { description = lib.mdDoc ''
            For automatic major version upgrades/migrations, the PostgreSQL package used before the current `.package`.
            This uses `pg_upgrade` included in (the current) `.package`. Also see `.upgradeArgs`.

            If you want to use automatic upgrades, set this to the previous package when you bump `.package`.
            This is no longer needed after the first successful startup of the postgresql service following the upgrade; you may want to clear this to remove the old package from the system closure (or set it to the same as `.package` to suppress the silent creation of empty databases).
            If the upgrade fails, the postgresql service will not be started and you may roll your (system) configuration back to the previous package version without any data loss (but of course with service downtime).
            This does not delete the previous database. If you are certain that the upgrade was successful, you may manually delete `.prevDataDir`.
        ''; type = lib.types.nullOr lib.types.package; default = null; example = lib.literalExpression "pkgs.postgresql_15"; };
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

            if [[ ! -e $curData/PG_VERSION ]] ; then ( # (systemd may have created $curData itself)
                rm -rf "$curData"/.auto-upgrade &>/dev/null || true
                # All of this is no atomic, and we would not want to proceed (on a second attempt) with a half-migrated DB.
                # Working in a temp dir that can replace $curData on success would be better, but $curData may be a mount point, so we have to use a subdir instead:
                mkdir -p -m 750 "$curData"/.auto-upgrade && cd "$curData"/.auto-upgrade || exit
                $curBin/initdb -D "$curData"/.auto-upgrade || exit
                $curBin/pg_upgrade \
                    --old-datadir "$prevData" --new-datadir "$curData"/.auto-upgrade \
                    --old-bindir $prevBin --new-bindir $curBin \
                    ${lib.escapeShellArgs cfg.upgradeArgs} \
                || exit
                ( GLOBIGNORE="$curData"/.auto-upgrade/PG_VERSION ; mv -ft "$curData"/ "$curData"/.auto-upgrade/* ) || exit
                mv -ft "$curData"/ "$curData"/.auto-upgrade/PG_VERSION || exit # commit
                rmdir "$curData"/.auto-upgrade || true # should be empty
            ) || exit ; fi
        '';
        systemd.services.postgresql.serviceConfig = lib.mkMerge [
            (lib.mkIf (cfg.prevDataDir != "/var/lib/postgresql/${cfg.prevPackage.psqlSchema}") {
                ReadWritePaths = [ cfg.prevDataDir ];
            })
            (lib.mkIf (cfg.prevDataDir == "/var/lib/postgresql/${cfg.prevPackage.psqlSchema}") {
                StateDirectory = [ "postgresql/${cfg.prevPackage.psqlSchema}" ];
                StateDirectoryMode = "0750";
            })
        ];
        systemd.services.postgresql.unitConfig.RequiresMountsFor = [ cfg.prevDataDir ];
    });

}
