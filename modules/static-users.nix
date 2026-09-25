dirname: inputs: { config, pkgs, lib, utils, modulesPath, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.users;
    force = if cfg.staticPretendsUserborn then lib.mkForce else _:_;
in {

    options.${prefix} = { users = {
        static = lib.mkEnableOption ''
            completely static generation of users files in nix, linking directly from `/etc/passwd`, `/etc/group`, and `/etc/shadow` to the nix store.
            This requires any declared user/group to have a fixed UID/GID, and conflicts with any dynamic user/group management.
            It is the administrators responsibility that the assignment of IDs that own persistent resources on the system does not change between system generations.
            `.hashedPassword` is the only supported password option, and options like `.createHome`, `.homeMode` and similar ones are ignored silently.
        '';
        staticPretendsUserborn = lib.mkOption { type = lib.types.bool; default = true; description = ''
            Whether to enable but then completely override "static" user generation via »userborn«.
            A number of other modules react to the different types of user generation, and this is the closest to `${prefix}.users.static`.
        ''; }; # required for example with config.system.etc.overlay.enable && !config.system.etc.overlay.mutable
        fixIDs = lib.mkOption { type = lib.types.bool; default = true; description = ''
            Whether to fix the UIDs/GIDs of some commonly used system users/groups.
        ''; };
    }; };

    config = lib.mkIf cfg.static (lib.mkMerge ((

        lib.mapAttrsToList (cfgName: value: {
            users.${cfgName} = value;
            assertions = [ {
                assertion = config.users.${cfgName} == value;
                message = "${prefix}.users.static implies that users.${cfgName} needs to be ${if value then "enabled" else "disabled"}.";
            } ];
        }) { mutableUsers = false; /* enforceIdUniqueness = true; */ } # non-unique UIDs are actually kinda-okay
    ) ++ [ {
        assertions = lib.flatten (lib.mapAttrsToList (name: user: (
            map (pwdName: {
                assertion = user.${pwdName} == null;
                message = "${prefix}.users.static implies that users.users.${name}.${pwdName} needs to be null.";
            }) [ "password" "hashedPasswordFile" "passwordFile" "initialHashedPassword" "initialPassword" ]
        ) ++ [ {
            assertion = user.uid != null;
            message = "${prefix}.users.static requires that users.users.${name}.uid needs to be set.";
        } ]) config.users.users) ++ (lib.mapAttrsToList (name: group: {
            assertion = group.gid != null;
            message = "${prefix}.users.static requires that users.groups.${name}.gid needs to be set.";
        }) config.users.groups);

    } { ## Actual Implementation:

        environment.etc = let
            isoToEpochDays = iso: let # accurate within a few days
                epoch = 1970; # next not-actually leap year is 2100
                split = lib.splitString "-" iso;
                years = (builtins.fromJSON (lib.elemAt split 0)) - epoch;
                months = (builtins.fromJSON (lib.elemAt split 1)) - 1;
                days = (builtins.fromJSON (lib.elemAt split 2)) - 1;
            in lib.floor ((years * 365.25) + (months * 30.4375) + days);
            mkEntry = {
                "passwd" = user: "${user.name}:${"x"}:${toString user.uid}:${toString config.users.groups.${user.group}.gid}:${user.description}:${user.home}:${utils.toShellPath user.shell}";
                "group" = group: "${group.name}:x:${toString group.gid}:${lib.concatStringsSep "," group.members}";
                "shadow" = user: "${user.name}:${if user.hashedPassword != null then user.hashedPassword else "!"}::::::${if user.expires != null then toString (isoToEpochDays user.expires) else ""}:";
                "subuid" = user: lib.concatStringsSep "\n" (map (range: "${user.name}:${toString range.startUid}:${toString range.count}") user.subUidRanges);
                "subgid" = user: lib.concatStringsSep "\n" (map (range: "${user.name}:${toString range.startGid}:${toString range.count}") user.subGidRanges);
            };
            mkFile = entities: mkEntry: force ((lib.concatStringsSep "\n" (map mkEntry (lib.attrValues entities))) + "\n");
        in {
            "passwd".text = mkFile config.users.users mkEntry."passwd";
            "group" .text = mkFile config.users.groups mkEntry."group";
            "shadow".text = mkFile config.users.users mkEntry."shadow";
            "subuid".text = mkFile config.users.users mkEntry."subuid";
            "subgid".text = mkFile config.users.users mkEntry."subgid";
            "shadow".mode = force "0640"; "shadow".gid = force config.ids.gids.shadow; # all contained information is readable in the store, but maybe "correct" permissions here make some program less unhappy
        };

    } { ## Compatibility with other user-generation modes:

        system.activationScripts.users = lib.mkIf (!cfg.staticPretendsUserborn) (lib.mkForce "");
        services.userborn = lib.mkIf cfg.staticPretendsUserborn (lib.mkForce { enable = true; static = true; });
        assertions = lib.mkIf cfg.staticPretendsUserborn (lib.wip.removeAssertionsFrom "${modulesPath}/services/system/userborn.nix");
        # tests exist for config.systemd.sysusers.enable + config.services.userborn.enable/static

    } { ## Fix IDs for users/groups that are used on every system:

        ids = let ids = {
            nscd = 48; # seems unused
            systemd-oom = 157; # just above the other systemd-*, and seems unused
        }; in { uids = ids; gids = ids // {
            systemd-coredump = config.ids.uids.systemd-coredump; # dunno why this only defines the user/uid, not the group/gid
        }; };
        users.users = {
            nscd.uid = config.ids.uids.nscd;
            systemd-oom.uid = config.ids.uids.systemd-oom;
        };
        users.groups = {
            nscd.gid = config.ids.gids.nscd;
            systemd-oom.gid = config.ids.gids.systemd-oom;
            systemd-coredump.gid = config.ids.gids.systemd-coredump;
        };

    } ] ++ (let  ## Fix IDs for users/groups that are used on many systems:
        defs = [ {
            "if" = let
                interfaces = lib.attrValues config.networking.interfaces;
                enableDHCP = config.networking.dhcpcd.enable && (config.networking.useDHCP || lib.any (i: i.useDHCP == true) interfaces);
            in enableDHCP;
            "then".dhcpcd = 133; # former ID
        } {
            "if" = config.networking.resolvconf.enable;
            "then".resolvconf.gid = 270; # used to be "kresd"'s ID
        } {
            "if" = config.services.openssh.enable;
            "then".sshd = 104; # used to be "nix-ssh"'s ID
        } ];
    in (
        map (def: lib.mkIf (def."if") (lib.mkMerge (lib.mapAttrsToList (name: id: if lib.isInt id then {
            ids.uids.${name} = id;
            ids.gids.${name} = id;
            users.users.${name}.uid = config.ids.uids.${name};
            users.groups.${name}.gid = config.ids.gids.${name};
        } else (lib.optionalAttrs (id?uid) {
            ids.uids.${name} = id.uid;
            users.users.${name}.uid = config.ids.uids.${name};
        }) // (lib.optionalAttrs (id?gid) {
            ids.gids.${name} = id.gid;
            users.groups.${name}.gid = config.ids.gids.${name};
        })) def."then"))) defs
    ))));
}
