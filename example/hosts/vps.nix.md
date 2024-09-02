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

    nixpkgs.hostPlatform = if name == "vps" then "x86_64-linux" else "aarch64-linux"; system.stateVersion = "23.11";
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
    wip.services.secrets = {
        enable = true; secretsDir = "example/secrets";
        include = [ "shadow/.*" ]; # secrets that this host needs access to
        rootKeyEncrypted = "ssh/host/host@${name}"; # (backup of) the host's decryption key, for (re-)installations
    };


}) ({ ## Actual Config

    ## And here would go the things that actually make the host unique (and do something productive). For now just some debugging things:

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.hashedPasswordFile = config.age.secrets."shadow/${"root"}".path; # »toor«

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.enable = true; # root:toor
    #services.openssh.enable = true; # (needs extra config to allow root password login)

}) ]; }
