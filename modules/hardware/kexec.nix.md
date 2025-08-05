/*

# Ephemeral `kexec` Systems

This module provides the base "hardware" configuration for ephemeral `kexec` test systems.
The idea is that they can be deployed to basically any host system (built there or copied to the store, or copied as a tarball if the target does not have Nix installed), and can be loaded into memory and rebooted into via `kexec`, to test things directly on the hardware with complete control over the software (including kernel and ideally even CPU microcode), while not leaving any persistent traces on the host system -- a reboot (or hard reset) is enough to restore the host system.

To make the `kexec` system accessible, login and host/decryption keys, plus IP setup, are optionally propagated from the host system to the `kexec` system.
This is (in places quite literally) inspired by <https://github.com/nix-community/nixos-images/blob/main/nix/kexec-installer>, though not for installations but for software tests on bare hardware.


## Usage

Define a system through a normal host configuration, but omit anything that has to do with installation, booting, file systems, or most hardware configuration.
Instead, enable this module (and probably secrets, to enable trustworthy SSH access):
```nix
{   nixpkgs.hostPlatform = "x86_64-linux";
    installer.hardware.kexec.enable = true;
    wip.services.secrets = {
        enable = true; rootKeyEncrypted = "ssh/host/host@${name}";
        include = [ "..." ]; # Secrets that this host needs access to.
        rootKeyExtraOwners = [ "ssh-rsa/..." "ssh-ed25519/..." ]; # Public host keys of the system(s) that this one should be deployable to. Let's those systems decrypt the root key.
    };
}
```
Then:
```bash
 # From your local repo, copy the config to the $target system:
 push-flake root@$target --register=nixos-config
 # ... and then build and kexec on the $target:
 ssh root@$target -- nix run nixos-config#.nixosConfigurations.$name.config.system.build.kexecRun -- --reboot # or see --help
 # OR build on your local system and copy the result to the $target:
 kexec=$( nix build --no-link --print-out-paths .#.nixosConfigurations.$name.config.system.build.kexecScript )
 nix copy --to ssh://root@$target $kexec
 # ... to directly run it there:
 ssh root@$target -- $kexec --reboot # or see --help
```

A complete example can be found in [`example/hosts/kexec.nix.md`](../../example/hosts/kexec.nix.md).


## TODOs / Open Questions

* [ ] Do microcode downgrades work?
* [ ] Fix/test the tarball variant.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS hardware config:
dirname: inputs: moduleArgs@{ config, options, pkgs, lib, utils, modulesPath, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.hardware.kexec;
    esc = lib.escapeShellArg;

    enableIf = enable: path: args@{ config, lib, pkgs, ... }: let module' = import path; module = if lib.isFunction module' then module' args else module'; in if module?config then { _file = "${path}#optional"; } // module // { config = lib.mkIf enable module.config; } else lib.mkIf enable module;

in ({

    options.${prefix} = { hardware.kexec = {
        enable = lib.mkEnableOption "the kexec system base config";
        applyInheritedIpSetup = lib.mkOption { description = ''
            Whether to apply IP/route setup as inherited from the host system by the `--inherit-ip-setup` flag.
        ''; type = lib.types.bool; default = true; };
        zswap = lib.mkEnableOption "zswap (in-memory compressed swap). Should help compress stale file system contents in low-memory situations";
    }; };

    imports = [
        (enableIf cfg.enable "${modulesPath}/installer/netboot/netboot.nix")
        (enableIf cfg.enable "${modulesPath}/profiles/minimal.nix")
        (enableIf cfg.enable "${inputs.nixos-images}/nix/restore-remote-access.nix") # boot.initrd.systemd.services.restore-state-from-initrd
    ];


} // { config = lib.mkIf (cfg.enable) (lib.mkMerge [ (let

    hasRootKey = config.${prefix}.services.secrets.enable && config.${prefix}.services.secrets.rootKeyEncrypted != null;
    rootKeyEncrypted = if !hasRootKey then "" else "${config.${prefix}.services.secrets.secretsPath}/${config.${prefix}.services.secrets.rootKeyEncrypted}.age";

    doKexec = doTar: if doTar then
        throw "coping the script to the tar won't currently work"
    else pkgs.kexec-run.override (old: {
        context = { args = { inherit doTar rootKeyEncrypted; }; inherit config; };
    });

in {

    system.build.kexecScript = lib.mkForce (pkgs.writeShellScript "kexec-script" ''exec ${lib.getExe config.system.build.kexecRun} "$@"'');
    system.build.kexecRun = doKexec false;

    system.build.kexecTarball = lib.mkForce ((import inputs.nixos-images.nixosModules.kexec-installer (moduleArgs // { config = config // { system = config.system // {
        build = config.system.build // { kexecRun = pkgs.writeScript "kexec-run.sh" "#!/usr/bin/env bash\n${doKexec true}"; }; # broken, see above
        kexec-installer.name = config.networking.hostName;
    }; }; })).config.system.build.kexecInstallerTarball.overrideAttrs (old: lib.optionalAttrs hasRootKey {
        runCommand = ''
            mkdir kexec $out
            cp ${esc rootKeyEncrypted} kexec/rootKey.age
            ln -sT ${esc (builtins.head config.age.identityPaths)} kexec/rootKey.target
            cp ${pkgs.pkgsStatic.age}/bin/age kexec/age
            echo init=${config.system.build.toplevel}/init' '${lib.escapeShellArgs config.boot.kernelParams} >kexec/cmdline
        '' + (lib.fun.extractLineAnchored ''mkdir kexec [$]out'' true true old.runCommand).without;
    }));

    boot.initrd.systemd.services.restore-state-from-initrd.script = lib.mkForce ''
        cp -aT /extra /sysroot
    '';
    systemd.services.restore-network = lib.mkIf cfg.applyInheritedIpSetup (import inputs.nixos-images.nixosModules.kexec-installer moduleArgs).config.systemd.services.restore-network;

    # Both providing multiple microcode archives to prepend and applying them during kexec seems to be working just fine:
    hardware.cpu.amd.updateMicrocode = true;
    hardware.cpu.intel.updateMicrocode = true; # (tested: even if sorted second, this gets applied on a previously outdated intel CPU)


}) ({ ## stripped-down base config

    wip.base.enable = lib.mkDefault true;

    system.stateVersion = lib.mkDefault config.system.nixos.release; # the default?
    boot.initrd.systemd.emergencyAccess = lib.mkDefault true;
    systemd.enableEmergencyMode = lib.mkDefault true;

    boot.kernelParams = lib.mkIf cfg.zswap [ "zswap.enabled=1" "zswap.max_pool_percent=50" "zswap.compressor=zstd" "zswap.zpool=zsmalloc" ];

    nix.enable = lib.mkDefault false;
    system.switch.enable = lib.mkDefault false;
    environment.defaultPackages = lib.mkDefault [ ];


}) ]); })
