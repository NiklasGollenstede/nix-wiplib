/*

# ZFS Backup Receiving

Enables the receiving of encrypted ZFS datasets for incremental backups.
The sending remote is not granted destructive ZFS permissions, i.e. it can never cause the destruction on pervious backups.
See [the README](./README.md) for motivation and concepts.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { options, config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = "wip"; #inputs.config.prefix;
    cfg = config.${prefix}.services.zfs.receive;
in { imports = [ {

    ## Receiving

    options.${prefix} = { services.zfs.receive = {
        dataset = lib.mkOption {
            description = ''
                Name of local backup dataset in which to receive backups and prune them.
                If set, the dataset with children for each ».hosts« will be created during installation and activation.
                The dataset is created as an encryption root. When changing this after the installation, the key must be added to the keystore manually first.
            '';
            type = lib.types.nullOr lib.types.str;
            default = null;
        };
        enableSanoid = lib.mkEnableOption "pruning of received sanoid snapshots on the receive dataset";
        sources = lib.mkOption {
            description = ''
                Remote sources (usually host(name)s) for which to allow SSH log-in limited to receiving (and sending/restoring) encrypted ZFS backups.
            '';
            # TODO: make permissions / allowed commands for restoring optional
            default = { }; apply = lib.filterAttrs (k: v: v != null);
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule (args@{ name, options, ... }: { options = {
                name = lib.mkOption { description = "Name of the source, for example the hostname of the host that is to send its backups here."; type = lib.types.str; default = name; readOnly = true; };
                sshKey = lib.mkOption {
                    default = cfg.getSshKey name;
                    defaultText = ''config.${prefix}.services.zfs.receive.getSshKey .name'';
                    type = lib.types.singleLineStr;
                    description = "Verbatim OpenSSH public key used by the sending host.";
                    example = [ "ssh-ed25519 AAAAC3NzaC/etcetera/etcetera/JZMfk3QPfQ backup@<hostname>" ];
                };
                user = lib.mkOption { default = "zfs-from-${name}"; type = lib.types.str; };
                uid = lib.mkOption { type = lib.types.int; };
                #gid = lib.mkOption { default = lib.mkIf (config.ids.gids?${args.config.user} || options.gid.isDefined) config.ids.gids.${args.config.user} or args.config.uid; type = lib.types.int; }; # (fixing the GID is not really necessary)
            }; config = {
                uid = lib.mkIf (config.ids.uids?${args.config.user}) (lib.mkOptionDefault config.ids.uids.${args.config.user});
            }; })));
        };
        getSshKey = lib.mkOption {
            type = lib.types.functionTo lib.types.singleLineStr;
        };
        #name = lib.mkOption { default = "zfs-from-${name}"; type = lib.types.str; description = ''
        #    Name of this receive target used by all senders as `${prefix}.services.zfs.send.datasets.*.targets.*.name`.
        #''; };
        syncSnapsToKeep = lib.mkOption { type = lib.types.listOf (lib.types.strMatching "[a-zA-Z0-9_-]*"); default = [ ]; };
    }; };


    config = lib.mkMerge [ (lib.mkIf (cfg.sources != [ ]) {

        ## Enable (limited) SSH access

        users.users = lib.fun.mapMerge (name: { user, uid, sshKey, ... }: { ${user} = {
            openssh.authorizedKeys.keys = [ ''command="PATH=${pkgs.bash}/bin:${pkgs.findutils}/bin:${pkgs.gnugrep}/bin:${pkgs.mbuffer}/bin:/run/booted-system/sw/bin ${./utils/ssh-command-filter.sh}" ${sshKey}'' ];
            uid = uid; isSystemUser = true; shell = "/bin/sh"; group = user;
        }; }) cfg.sources;
        users.groups = lib.fun.mapMerge (name: { user, /* gid, */ ... }: { ${user} = {
            #gid = gid;
        }; }) cfg.sources;


    }) (lib.optionalAttrs (options?setup.zfs) (lib.mkIf (cfg.dataset != null) {

        ## Declare receive datasets

        setup.zfs.datasets = { "${cfg.dataset}" = {
            props = {
                canmount = "off"; mountpoint = "none";
                keyformat = "ephemeral"; # encrypted with throw-away key, so that it can be part of an encrypted send, but also never be mounted
            };
        }; } // (lib.fun.mapMerge (name: { uid, ... }: let
            dataset = "${cfg.dataset}/${name}";
        in { ${dataset} = {
            recursiveProps = true; # when applying the »props«, e.g. after restoring this dataset from its backup, also apply them to any already existing child datasets (but this will not automatically/immediately apply the props to new children)
            props = {
                canmount = "off"; mountpoint = "none"; keyformat = "ephemeral";
            };
            permissions."u ${toString uid}" = "create,receive,mount,canmount,mountpoint,keylocation,userprop"; # »mount« is required for »receive« # TODO: drop userprop?
        }; }) cfg.sources);


    })) (lib.mkIf (cfg.dataset != null) (let
        gc-service = (lib.fun.importWrapped inputs "${dirname}/utils/gc-sync-snaps-service.nix").result { inherit (cfg) dataset; inherit pkgs lib utils; label = config.${prefix}.services.zfs.send.forwardPendingProperty; };
        reset-service = (lib.fun.importWrapped inputs "${dirname}/utils/reset-recv-service.nix").result { inherit (cfg) dataset; snapPrefix = lib.optionalString (cfg.syncSnapsToKeep != [ ]) "syncoid_(${lib.concatStringsSep "|" cfg.syncSnapsToKeep})_"; inherit pkgs lib utils; };
        ensurePendingProp = source: "+" + ''/run/booted-system/sw/bin/zfs set ${config.${prefix}.services.zfs.send.forwardPendingProperty}=${lib.concatStringsSep ":" source.forwardingTo} ${source.path}'';
    in {
        ## Prune snapshots in backup »dataset«

        systemd.services.backup-gc = lib.recursiveUpdate gc-service.service {
            serviceConfig.ExecStartPre = map ensurePendingProp (lib.filter (source: (cfg.dataset == source.path) || (lib.fun.startsWith "${cfg.dataset}/" source.path)) (lib.attrValues config.${prefix}.services.zfs.send.datasets));
        };
        systemd.timers  .backup-gc = gc-service.timer;
        systemd.services.backup-reset = reset-service.service;
        systemd.timers  .backup-reset = reset-service.timer;

    })) (lib.mkIf (cfg.enableSanoid) {

        services.sanoid.enable = lib.mkIf (cfg.dataset != null) true;

        services.sanoid.datasets = lib.mkIf (cfg.dataset != null) { ${cfg.dataset} = {
            use_template = [ "backup" ];
            recursive = true; # potentially has multiple (after receiving non-recursively snapshotted) children
        }; };

        services.sanoid.templates.backup = { # »backup«
            autoprune  = true; autosnap   = false; # do NOT create any snapshots here, they are received them from the source

            frequently =   0;
            hourly     =   0;
            daily      =  31;
            weekly     =  12;
            monthly    =  12;
            yearly     = 100; # for manual deletion:
        };

    }) ];

} ]; }
