/*

# ZFS Backup Sending

Implements the sending (or forwarding) of encrypted ZFS datasets for incremental backups.
The sending host/user does not require destructive ZFS permissions on the target, i.e. it can never cause the destruction on pervious backups.
See [the README](./README.md) for motivation and concepts.

**NOTICE**: (If any dataset targets are defined, then) this module currently requires `config.services.syncoid.sshKey` to be set and the `nixpkgs/syncoid-user-per-cmd` [patch](../../../patches/nixpkgs/) to be applied to `nixpkgs`.
See at the bottom of [`example/hosts/zfs-backup.nix.md`](../../../example/hosts/zfs-backup.nix.md) for an example how to do this (without patching all of `nixpkgs`).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { options, config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = "wip"; #inputs.config.prefix;
    cfg = config.${prefix}.services.zfs.send;
    targetSpec = source: target: "${target.host}:${if (lib.fun.lastChar target.path == "/") then "${target.path}${config.networking.hostName}/${builtins.baseNameOf source.path}" else target.path}";
in { imports = [ {

    ## Sending

    options.${prefix} = { services.zfs.send = {
        enable = lib.mkEnableOption "ZFS backups (and restoring)" // {
            default = cfg.datasets != { };
        };
        datasets = lib.mkOption {
            description = "ZFS datasets to back up.";
            default = { };
            type = lib.fun.types.attrsOfSubmodules (sourceArgs@{ name, ... }: { options = {
                path = lib.mkOption { description = "Path of the local source dataset. Sending will fail if the local dataset is not encrypted."; type = lib.types.str; default = name; readOnly = true; };
                targets = lib.mkOption {
                    description = "Targets to send the dataset to.";
                    default = { };
                    type = lib.fun.types.attrsOfSubmodules ({ name, ... }: { options = {
                        name = lib.mkOption { description = "Symbolic name of the target, for example its hostname."; type = lib.types.strMatching ''^[a-zA-Z0-9_-]+$''; default = name; readOnly = true; };
                        host = lib.mkOption { description = "Hostname of the target."; type = lib.types.str; default = name; };
                        path = lib.mkOption { description = "Path of the dataset on `.host` to send to. If it ends in a `/` (recommended), then the `config.networking.hostName` and the last label of the source `..path` will be appended."; type = lib.types.str; };
                        user = lib.mkOption { description = "SSH user to log in as on `.host`."; default = "zfs-from-${config.networking.hostName}"; type = lib.types.str; };
                        startAt = lib.mkOption { description = "When to send to this target, as systemd time spec."; default = if sourceArgs.config.isForwarding then "04:15 UTC" else "00:15 UTC"; type = lib.types.str; }; # If forwarding, TRY to send after receiving (but can't ensure that).
                    }; });
                };
                isForwarding = lib.mkOption {
                    description = "Whether the sent dataset is also being received to from elsewhere.";
                    default = (lib.any (from: config.${prefix}.services.zfs.receive.dataset == from) (lib.fun.parentPaths name));
                    type = lib.types.bool;
                };
                forwardingTo = lib.mkOption {
                    description = "If `.isForwarding`, list of targets' `.name`s that this dataset is being sent to. Defaults to the targets' names of this and all parent sends (which should all be unique), and should probably not need to be adjusted.";
                    default = lib.attrNames (sourceArgs.config.targets // (lib.fun.mergeAttrs (map (path: cfg.datasets.${path}.targets or { }) (builtins.tail (lib.fun.parentPaths sourceArgs.config.path)))));
                    type = lib.types.listOf lib.types.str;
                };
                locations = lib.mkOption {
                    description = "Lists of locations where (backups of) this dataset will be available (to restore from).";
                    internal = true; type = lib.types.listOf lib.types.str;
                };
            }; config = {
                locations = lib.mkMerge ((lib.mapAttrsToList (_: target: lib.mkOrder 1000 [ "${targetSpec sourceArgs.config target}" ]) sourceArgs.config.targets) ++ [ (lib.mkOrder 2000 [ "${config.networking.hostName}:${name}" ]) ]);
            }; });
        };
        postRestoreCommands = lib.mkOption { description = "When installing the system with `--zfs-restore`, bash commands to be run after each dataset in `.datasets` (whose local path will be in `$dataset`) has been restored."; type = lib.types.lines; default = ""; };
        forwardPendingProperty = lib.mkOption { default = "forward:pending-to"; type = lib.types.strMatching ''^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$''; };
    }; };

    config = (lib.mkIf cfg.enable (let

        # Unfortunately, when receiving a replicate stream (»-R«), the »-o« properties specified in the »recvOptions« are only applied to the root dataset sent, not to its children (the man says the children are supposed to be set to inherit, but that does not seem to be the case). Since the mount options have to be set, use »syncoid«'s »--recursive« instead:
        commonArgs = [ "--no-command-checks" "--no-rollback" "--keep-sync-snap-target" "--compress=none" "--recursive" ]; # "--debug"
        sendOptions = " w "; # -w == --raw : send as encrypted; /* -R == --replicate : (ZFS) recursive */
        recvOptions = " u o canmount=off o mountpoint=none o keylocation=file:///dev/null "; # -u : don't mount on receive; -o... : don't mount later

    in lib.mkMerge [ ({

        services.syncoid.enable = true;

        # TODO: remove:
        # Any mention of the "backup(-to-*)" users/group should be irrelevant once DynamicUser is used.
        services.syncoid.user = "backup"; services.syncoid.group = "backup";
        users.users.backup = { isSystemUser = true; group = "backup"; }; users.groups.backup = { }; # the group should be able to read the »config.services.syncoid.sshKey«

        services.syncoid.localSourceAllow = [ "userprop" ] ++ [ "bookmark" "hold" "send" "snapshot" "destroy" ] ++ [ "mount" ]; # for reasons of obviousness, destroying (not-mounted) snapshots requires the »mount« permission (might be because they are accessible via the ».zfs« hidden directory)
        # TODO: drop userprop?
        # TODO: Only need destroy/mount when not forwarding?

    } // (lib.optionalAttrs (options?installer) {
        ## Enable restoring of backups during installation:
        installer.scripts.zfs-restore = { path = ./utils/restore-zfs-backups.sh; order = 750; };
        installer.commands.postFormat = ''check-restore-zfs-backups --force-delete'';

    })) (let

        forEachTarget = getConfig: lib.mkMerge (lib.flatten (lib.mapAttrsToList (_: dataset: lib.mapAttrsToList (_: target: getConfig dataset target) dataset.targets) cfg.datasets));
        commandName = source: target: "${source.path}@${target.host}:${target.path}";
        unitName = source: target: escapeUnitName "syncoid-${commandName source target}";
        escapeUnitName = name: lib.concatMapStringsSep "" (s: if builtins.isList s then "-" else s) (builtins.split "[^a-zA-Z0-9_.\\-]+" name); # from nixos/modules/services/backup/syncoid.nix

    in {

        services.syncoid.commands = forEachTarget (source: target: { ${commandName source target} = {
            source = source.path; target = "${target.user}@${targetSpec source target}";
            extraArgs = commonArgs ++ [ "--identifier=to_${target.name}_from" ]
            # When forwarding, don't create sync snaps, but instead remove the target from the pending list (see »Backup Forwarding« in the README):
            ++ (lib.optionals source.isForwarding [ "--no-sync-snap" "--sync-snap-cmd-after=${pkgs.bash}/bin/bash ${./utils/mark-snap-as-sent.sh} ${target.name} ${cfg.forwardPendingProperty}" ]);
            # BUG?: It seems that receiving a stream with holds triggers a number of different assertions in zfs, so don't use holds. (Edit: It might work if the »hold« permission was set on the receiving side ...)
            user = "backup-to-${target.name}";
            inherit sendOptions recvOptions;
        }; });

        systemd = forEachTarget (source: target: {

            services = let
                ensurePendingProp = source: "+" + ''/run/booted-system/sw/bin/zfs set ${config.${prefix}.services.zfs.send.forwardPendingProperty}=${lib.concatStringsSep ":" source.forwardingTo} ${source.path}'';
            in { ${unitName source target} = {
                serviceConfig = {
                    Type = "oneshot";
                    Restart = "on-failure"; RestartSec = 900; # retry on failure
                    TimeoutStartSec = "6h"; # it sometimes get's stuck permanently
                    BindReadOnlyPaths = [ config.services.syncoid.sshKey ]; # TODO(PR): this should be set implicitly
                    ExecStartPre = lib.mkIf (source.isForwarding) [ (ensurePendingProp source) ];
                };
                startAt = lib.mkOverride 99 target.startAt;
                # TODO: For mobile devices: add check before backup that network is not declared/guessed as metered.
                # TODO: Same for mains power.
            }; };

            timers = { ${unitName source target}.timerConfig = {
                RandomizedDelaySec = 1800;
                Persistent = true;
            }; };
        });

        users.users = forEachTarget (_: { name, ... }: { "backup-to-${name}" = { isSystemUser = true; group = "backup"; }; });

    }) ]));

} ]; }
