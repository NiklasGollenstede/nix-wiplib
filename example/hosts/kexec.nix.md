/*

# `kexec` test in VM

This example boots a "persistent" (though also immutable) NixOS configuration (`kexec-vm`) in a VM, and then uses `kexec` to boot into a new NixOS configuration (`kexec`) that lives entirely in-memory.
That second configuration could have been pushed from elsewhere, yet it can still make use of agenix encrypted secrets (by basically declaring the target host('s SSH host key) as administrator that can decrypt its own root key).


## Installation

The encrypted keys were created with:
```bash
 nix run .#secrets -- genkey-ssh::ssh/host/host@kexec-vm genkey-ssh::ssh/host/host@kexec encrypt:<(echo 'deployment works!'):dummy/kexec
```

To test the system, first launch the VM with the "persistent" host system:
```bash
 nix run .#.nixosConfigurations.kexec-vm.config.system.build.vm
```

Usually, one would now build or copy the `kexec` script on or to the host system.
For convenience, it is already linked there. Simply run:
```bash
 /do-kexec --reset
```
(On a proper host system, one would probably do a clean shutdown/reboot (`--reboot`) instead of the `--reset`, but something prevents the host system from shutting down properly (independently of the `kexec` stuff).)

In graphical mode, the `kexec` system for some reason does not print boot messages, but after a few seconds it shows the (autologin) prompt:
```bash
 cat /check # -> yay
 cat /run/agenix/dummy/kexec # -> deployment works
```


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, nodes, ... }: let lib = inputs.self.lib.__internal__; in let
    useDummyKey = true; # Use dummy key so that the key as to not worry about the deployment of the host key for the kexec VM. TYhe else branch shows how it _should_ be done.
in { preface = {
    instances = [ "kexec-vm" "kexec" ];


}; imports = if name == "kexec" then [ ({ ## kexec System

    nixpkgs.hostPlatform = "x86_64-linux";
    wip.hardware.kexec.enable = true;

    services.getty.autologinUser = "root";
    boot.kernelParams = [ "console=ttyS0" ]; # ++ [ "rd.systemd.debug_shell=ttyS0" "systemd.debug_shell=ttyS0" ];

    systemd.tmpfiles.rules = [ (lib.fun.mkTmpfile { type = "f"; path = "/check"; argument = "yay\n"; }) ];

    wip.services.secrets = {
        enable = true; secretsDir = "example/secrets";
        include = [ "dummy/kexec" ];
        rootKeyEncrypted = "ssh/host/host@${name}"; # to be decrypted during kexec
        rootKeyExtraOwners = if (!useDummyKey) then (
            lib.optional (builtins.pathExists "${inputs.self}/ssh/host/host@kexec-vm.pub") (builtins.readFile "${inputs.self}/ssh/host/host@kexec-vm.pub")
        ) else [ (builtins.readFile "${inputs.self}/example/ssh-dummy-key.pub") ]; # (See below.)
    };


}) ] else [ ({ ## Runner VM

    nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "25.05";
    wip.base.enable = true;
    profiles.qemu-guest.enable = true;
    services.getty.autologinUser = "root";
    boot.kernelParams = [ "console=ttyS0" ]; # ++ [ "rd.systemd.debug_shell=ttyS0" "systemd.debug_shell=ttyS0" ];
    documentation.enable = false; # sometimes takes quite long to build

    systemd.tmpfiles.rules = [ (lib.fun.mkTmpfile { type = "L+"; path = "/do-kexec"; argument = lib.getExe nodes.kexec.config.system.build.kexecRun; }) ];

    virtualisation.vmVariant.virtualisation.diskImage = null;
    #virtualisation.vmVariant.virtualisation.graphics = true;
    virtualisation.vmVariant.virtualisation.memorySize = 4096;

    wip.services.secrets = {
        enable = !useDummyKey; secretsDir = "example/secrets";
        rootKeyEncrypted = "ssh/host/host@${name}"; # (This is the key that _should_ be decrypted during "installation" of the runner. Since we are not installing it, (also) use the dummy key:)
    };
    environment.etc."ssh/ssh_host_ed25519_key".source = lib.mkIf useDummyKey "${inputs.self}/example/ssh-dummy-key";
    environment.etc."ssh/ssh_host_ed25519_key.pub".source = lib.mkIf useDummyKey "${inputs.self}/example/ssh-dummy-key.pub";


})]; }
