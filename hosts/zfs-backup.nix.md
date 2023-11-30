/*

# Example Multi-level [ZFS Backup](../modules/services/zfs/)

This sets up two data-producing "clients" (`server` and `laptop`) that send their backups to a `relay` which stores their backups at the main site, but also forwards the received backups to two off-site backup sinks (`sink1`/`sink2`).

To start the VMs, run in `..`:
```bash
 nix shell nixpkgs#vde2 --command vde_switch -sock /tmp/nixos-vm/zfs-net
 nix run .#zfs-relay  -- run-qemu --install=always --nic=vde,sock=/tmp/nixos-vm/zfs-net
 nix run .#zfs-server -- run-qemu --install=always --nic=vde,sock=/tmp/nixos-vm/zfs-net
 nix run .#zfs-laptop -- run-qemu --install=always --nic=vde,sock=/tmp/nixos-vm/zfs-net
 nix run .#zfs-sink1  -- run-qemu --install=always --nic=vde,sock=/tmp/nixos-vm/zfs-net
 nix run .#zfs-sink2  -- run-qemu --install=always --nic=vde,sock=/tmp/nixos-vm/zfs-net
```

To see the interesting part of the configuration, skip to `## Backups` below.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    rpoolOf = name: "rpool-${builtins.substring 0 8 (builtins.hashString "sha256" name)}";
    rpool = rpoolOf name;
    uidOf = name: (lib.fun.indexOf instances name) + 401;
    instances = [ "zfs-relay" "zfs-server" "zfs-laptop" "zfs-sink1" "zfs-sink2" ];
in { preface = {
    inherit instances;
    id = (lib.fun.indexOf instances name) + 1;


}; imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "23.11";

    boot.loader.extlinux.enable = true;
    profiles.qemu-guest.enable = true;
    setup.temproot = { enable = true; temp.type = "zfs"; local.type = "zfs"; remote.type = "zfs"; };
    setup.keystore.enable = true;

    networking.interfaces.ens4.ipv4.addresses = [ { address = "10.0.4.${config.preface.id}"; prefixLength = 24; } ];
    networking.hosts = lib.fun.mapMerge (name: { "10.0.4.${toString ((lib.fun.indexOf instances name) + 1)}" = [ name ]; }) instances;


}) ({ ## Base Config

    # Some base config:
    wip.base.enable = true;
    documentation.enable = false; # sometimes takes quite long to build
    boot.kernelParams = [ "console=ttyS0" ];
    services.getty.autologinUser = "root"; users.users.root.password = "root";


}) ({ ## Backups

}) (lib.mkIf (name == "zfs-server" || name == "zfs-laptop") { ### Clients

    # While not strictly required, it makes sense to take periodic snapshots:
    services.sanoid.enable = true; services.sanoid.interval = "*:0/15";
    services.sanoid.datasets."${rpool}/remote" = {
        recursive = "zfs"; use_template = [ "production" ]; # (see below)
    };

    # All clients send all datasets to the `relay`:
    wip.services.zfs.send.enable = true;
    wip.services.zfs.send.datasets = {
        "${rpool}/remote".targets = {
            "zfs-relay".path = "${rpoolOf "zfs-relay"}/backup/";
        }; # (could declare more datasets or targets)
    };


}) (lib.mkIf (name == "zfs-relay") { ### Relay (forwarding)

    # Allow receiving of backups from clients:
    wip.services.zfs.receive.dataset = "${rpool}/backup";
    wip.services.zfs.receive.enableSanoid = true; # (prune the received periodic snapshots)
    wip.services.zfs.receive.sources = {
        "zfs-server" = { uid = uidOf "zfs-server"; };
        "zfs-laptop" = { uid = uidOf "zfs-laptop"; };
    };

    # If this host also serves other tasks, snapshot its local data as well:
    services.sanoid.enable = true; services.sanoid.interval = "*:0/15";
    services.sanoid.datasets."${rpool}/remote" = {
        recursive = "zfs"; use_template = [ "production" ]; # (see below)
    };

    # Then send all received backups and own data to the off-site sinks:
    wip.services.zfs.send.enable = true;
    wip.services.zfs.send.datasets = {
        "${rpool}/backup".targets = { # (this will automatically use forwarding commands)
            "zfs-sink1".path = "${rpoolOf "zfs-sink1"}/backup/";
            "zfs-sink2".path = "${rpoolOf "zfs-sink2"}/backup/";
        };
        "${rpool}/remote".targets = {
            "zfs-sink1".path = "${rpoolOf "zfs-sink1"}/backup/";
            "zfs-sink2".path = "${rpoolOf "zfs-sink2"}/backup/";
        };
    };


}) (lib.mkIf (lib.fun.startsWith "zfs-sink" name) { ### Sinks (off-site)

    # Allow receiving of backups from the relay:
    wip.services.zfs.receive.dataset = "${rpool}/backup";
    wip.services.zfs.receive.enableSanoid = true; # (prune the received periodic snapshots)
    wip.services.zfs.receive.sources = {
        "zfs-relay" = { uid = uidOf "zfs-relay"; };
    };


}) ({ ### Backup Commons

    services.openssh.enable = true;
    wip.services.zfs.receive.getSshKey = host: lib.fileContents ../example/ssh-dummy-key.pub;
    services.syncoid.sshKey = ../example/ssh-dummy-key;

    services.openssh.knownHosts = lib.fun.mapMerge (name: { ${name}.publicKeyFile = ../example/ssh-dummy-key.pub; }) instances;
    environment.etc."ssh/ssh_host_ed25519_key" = { source = lib.mkForce ../example/ssh-dummy-key; mode = "0400"; };

    services.sanoid.templates.production = {
        autoprune  = true; autosnap   = true;
        frequent_period = 15; # make "frequently" = 15 minutes

        frequently =   4;
        hourly     =  36;
        daily      =  21;
        weekly     =   6;
        monthly    =   6;
        yearly     = 100; # for manual deletion
    };


}) ({ # For now, this patch is required:

    disabledModules = [ "services/backup/syncoid.nix" ];
    imports = [ "${((import inputs.nixpkgs { system = "x86_64-linux"; }).applyPatches {
        name = "nixpkgs-patched"; src = "";
        patches = [ ../patches/nixpkgs/syncoid-user-per-cmd.patch ];
    }).overrideAttrs {
        unpackPhase = ''
            mkdir -p nixos/modules/services/backup
            cp -aT {${inputs.nixpkgs}/,}nixos/modules/services/backup/syncoid.nix
        '';
    }}/nixos/modules/services/backup/syncoid.nix" ];


}) ]; }
