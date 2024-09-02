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
in { preface = {
    #instances = [ "rpi" ];


}; imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "aarch64-linux"; system.stateVersion = "23.11";
    wip.hardware.raspberry-pi.enable = true;

    setup.disks.devices.primary.size = 31914983424; # exact size of the disk/card

    ## Minimal automatic FS setup
    setup.bootpart.enable = true;
    setup.temproot.enable = true;
    setup.temproot.temp.type = "tmpfs";
    setup.temproot.local.type = "bind";
    setup.temproot.local.bind.base = "f2fs";
    setup.temproot.remote.type = "none";


}) ({ ## Base Config

    # Some base config:
    wip.base.enable = true;
    documentation.enable = false; # sometimes takes quite long to build
    boot.kernelParams = [ "console=ttyS0" ]; # Only during local testing.
    wip.services.secrets = {
        enable = true; secretsDir = "example/secrets";
        include = [ "shadow/.*" ]; # secrets that this host needs access to
        rootKeyEncrypted = "ssh/host/host@${name}"; # (backup of) the host's decryption key, for (re-)installations
    };


}) ({ ## Actual Config

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.hashedPasswordFile = config.age.secrets."shadow/${"root"}".path; # »toor«

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.enable = true;
    wip.services.dropbear.rootKeys = ''${lib.readFile "${inputs.self}/example/ssh-dummy-key.pub"}'';
    wip.services.dropbear.socketActivation = true;

    boot.binfmt.emulatedSystems = [ "x86_64-linux" ];


}) ]; }
