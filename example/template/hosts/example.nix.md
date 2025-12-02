/*

# Rename me!

## Installation

To test the system locally, run in `..`:
```bash
 nix run .#host1 -- run-qemu --install=always
```
See `nix run .#host1 -- --help` for options and more commands.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    ids = { host1 = 1; host2 = 2; host3 = 3; };
in { preface = {
    instances = builtins.attrNames ids; id = ids.${name};

}; imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "25.11";

    boot.loader.systemd-boot.enable = true;
    setup.bootpart.enable = true;
    setup.temproot = { enable = true; temp.type = "zfs"; local.type = "zfs"; remote.type = "zfs"; };
    #setup.disks.devices.primary.size = ...;

}) ({ ## Base Config

    wip.base.enable = true;
    documentation.enable = false; # sometimes takes quite long to build
    services.getty.autologinUser = "root";

}) ({ ## Enable SSHd
    services.openssh.enable = true;
    systemd.tmpfiles.rules = [
        (lib.fun.mkTmpfile { type = "L+"; path = "/root/.ssh"; argument = "/remote/root/.ssh/"; })
        (lib.fun.mkTmpfile { type = "d"; path = "/remote/root/.ssh/"; mode = "700"; })
        (lib.fun.mkTmpfile { type = "f"; path = "/remote/root/.ssh/authorized_keys"; mode = "600"; })
    ];
    environment.systemPackages = [ pkgs.curl ]; # curl https://github.com/$user.keys >>/root/.ssh/authorized_keys

}) ({ ## qemu
    #boot.kernelParams = [ "console=ttyS0" ]; # Only during testing in VM.
    #profiles.qemu-guest.enable = true;

}) ]; }
