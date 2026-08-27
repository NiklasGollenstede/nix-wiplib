dirname: inputs: { config, pkgs, lib, utils, modulesPath, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    hasDumbAssertion = config.system.etc.overlay.enable && !config.system.etc.overlay.mutable;
    fixDumbAssertion = if hasDumbAssertion then lib.mkForce else _:_;
in {

    options.${prefix} = { users = {
        static = lib.mkEnableOption ''
            completely static generation of users files in nix, linking directly from /etc/passwd, /etc/group, and /etc/shadow to the nix store.
            This requires any declared user/group to have a fixed UID/GID, and conflicts with any dynamic user/group management.
            It is the administrators responsibility that the assignment of IDs that own files on the system does not change between system generations.
            `.hashedPassword` is the only supported password option, and options like `.createHome`, `.homeMode` and similar ones are ignored silently.
            `/etc/shadow` will be world-readable (but contains only trivial information anyway).
        '';
    }; };

    config = lib.mkIf config.${prefix}.users.static (lib.mkMerge ((
        map (cfgName: {
            users.${cfgName} = false;
            assertions = [ {
                assertion = !config.users.${cfgName};
                message = "${prefix}.users.static implies that users.${cfgName} needs to be disabled.";
            } ];
        }) [ "mutableUsers" "enforceIdUniqueness" ] # TODO: also config.systemd.sysusers.enable + config.services.userborn.enable
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

        ids = let ids = {
            nscd = 48; # seems unused
            systemd-oom = 157; # just above the other systemd-*, and seems unused
        }; in { uids = ids; gids = ids; };
        users.users = {
            nscd.uid = config.ids.uids.nscd;
            systemd-oom.uid = config.ids.uids.systemd-oom;
        };
        users.groups = {
            nscd.gid = config.ids.gids.nscd;
            systemd-oom.gid = config.ids.gids.systemd-oom;
            systemd-coredump.gid = config.ids.uids.systemd-coredump; # dunno why this only defines the user/uid, not the group/gid
        };

        system.activationScripts.users = lib.mkForce "";

        environment.etc = let
            isoToEpochDays = iso: let # accurate within a new days
                epoch = 1970; # next not-actually leap year is 2100
                split = lib.splitString "-" iso;
                years = (builtins.fromJSON (lib.elemAt split 0)) - epoch;
                months = (builtins.fromJSON (lib.elemAt split 1)) - 1;
                days = (builtins.fromJSON (lib.elemAt split 2)) - 1;
            in lib.floor ((years * 365.25) + (months * 30.4375) + days);
        in {
            "passwd".text = fixDumbAssertion ((lib.concatStringsSep "\n" (map (user: "${user.name}:${"x"}:${toString user.uid}:${toString config.users.groups.${user.group}.gid}:${user.description}:${user.home}:${utils.toShellPath user.shell}") (lib.attrValues config.users.users))) + "\n");
            "group".text = fixDumbAssertion ((lib.concatStringsSep "\n" (map (group: "${group.name}:x:${toString group.gid}:${lib.concatStringsSep "," group.members}") (lib.attrValues config.users.groups))) + "\n");
            "shadow".text = fixDumbAssertion ((lib.concatStringsSep "\n" (map (user: "${user.name}:${if user.hashedPassword != null then user.hashedPassword else "!"}::::::${if user.expires != null then toString (isoToEpochDays user.expires) else ""}:") (lib.attrValues config.users.users))) + "\n");
            "subuid".text = fixDumbAssertion ((lib.concatStringsSep "\n" (map (user: lib.concatStringsSep "\n" (map (range: "${user.name}:${toString range.startUid}:${toString range.count}") user.subUidRanges)) (lib.attrValues config.users.users))) + "\n");
            "subgid".text = fixDumbAssertion ((lib.concatStringsSep "\n" (map (user: lib.concatStringsSep "\n" (map (range: "${user.name}:${toString range.startGid}:${toString range.count}") user.subGidRanges)) (lib.attrValues config.users.users))) + "\n");
        };
        services.userborn = lib.mkIf hasDumbAssertion (lib.mkForce { enable = true; static = true; });
    } {
        assertions = lib.mkIf hasDumbAssertion (lib.wip.removeAssertionsFrom "${modulesPath}/services/system/userborn.nix");

    } ]));
}
