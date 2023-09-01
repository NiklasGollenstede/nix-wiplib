/*

# Example Hetzner VPS Host

## Installation

To test the system locally, run in `..`:
```bash
 nix run .'#'vps -- run-qemu --install=always
```
See `nix run .#vps -- --help` for options and more commands.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
in { preface = {
    instances = [ "vps" "vps-aarch64" ];


}; imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = if name == "vps" then "x86_64-linux" else "aarch64-linux"; system.stateVersion = "23.05";

    wip.hardware.hetzner-vps.enable = true;
    setup.temproot.enable = true;
    setup.temproot.temp.type = "zfs";
    setup.temproot.local.type = "zfs";
    setup.temproot.remote.type = "zfs";


}) ({ ## Base Config

    # Some base config:
    wip.base.enable = true;
    documentation.enable = false; # sometimes takes quite long to build
    boot.kernelParams = [ "console=ttyS0" ]; # Only during local testing.


}) ({ ## Actual Config

    ## And here would go the things that actually make the host unique (and do something productive). For now just some debugging things:

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    boot.zfs.allowHibernation = lib.mkForce false; # Ugh: https://github.com/NixOS/nixpkgs/commit/c70f0473153c63ad1cf6fbea19f290db6b15291f

}) ]; }
