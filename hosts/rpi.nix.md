/*

# Raspberry PI Example

## Installation

```bash
 nix run '.#rpi' -- install-system $DISK
 nix run '.#rpi' -- --help # for more information and options
```
Then connect `$DISK` to a PI, boot it, and (not much, because nothing is installed).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
in { imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "aarch64-linux"; system.stateVersion = "23.05";
    wip.hardware.raspberry-pi.enable = true;

    setup.disks.devices.primary.size = 31914983424; # exact size of the disk/card

    ## Minimal automatic FS setup
    setup.bootpart.enable = true;
    setup.temproot.enable = true;
    setup.temproot.temp.type = "tmpfs";
    setup.temproot.local.type = "bind";
    setup.temproot.local.bind.base = "f2fs";
    setup.temproot.remote.type = "none";


}) ({ ## Software

    wip.base.enable = true;

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.enable = true;
    wip.services.dropbear.rootKeys = ''${lib.readFile "${dirname}/../example/ssh-login.pub"}'';
    wip.services.dropbear.socketActivation = true;

    boot.binfmt.emulatedSystems = [ "x86_64-linux" ];


}) ]; }
