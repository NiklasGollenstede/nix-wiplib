/*

# Nix(OS-ish env) on Linux with Root Access

For when you have Linux with root access (and Nix installed), but what you really want is NixOS.
Except for service management, this is pretty close to a "real" NixOS installation, with `sudo` working "inside" NixOS.


## Usage

Include this in the host configuration:
```nix
{   nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "24.05";
    wip.hardware.root-chroot.enable = true;
    wip.hardware.root-chroot.ssh-enter.viaEtc = true;
    users.users.me = {
        isNormalUser = true; # => ssh-enter
        home = "${config.wip.hardware.root-chroot.homesDir}/me";
        openssh.authorizedKeys.keyFiles = [ ... ];
    }; # might want to change U/GIDs to match the host's, to avoid warnings
}
```


## Installation

To initialize the NixS environment:
* install Nix on the target system (e.g., as `sudo` user (not `root`), run `sh <(curl -L https://nixos.org/nix/install) --daemon`),
* build the system on the target by running (on your dev machine in the flake defining the system) `nix run .#update-host -- <host> build`,
* run the below in a `sudo -i`/`root` shell (either all at once or line-by-line):
```bash
 # bash -u -o pipefail -x -e <(cat << " #EOF" # (copy from after the first #)


 ## Activate the System
 nix-env -p /nix/var/nix/profiles/system --set $( su - "$SUDO_USER" -c 'readlink ~/result' ) # (This relies on the update-host command above.)
 SSH_ORIGINAL_COMMAND='echo "Installation done!"' /nix/var/nix/profiles/system/ssh-enter

 ## Cleanup: remove unmanaged Nix stuff from the host
 ln -sfT system/nix /nix/var/nix/profiles/default # As only thing in the profile, use the nix version from NixOS. The nix-daemon.service also already links to that.
 rm -rf /etc/nix/ ; ln -sfT /nix/var/nix/profiles/system/etc/nix /etc/nix # Use nix.conf and registry.json from NixOS (some changes will take »host-sc restart nix-daemon.service« to apply).
 systemctl daemon-reload && systemctl restart nix-daemon.service
 rm -rf /root/{.nix-profile,.nix-channels,.nix-defexpr/} /nix/var/nix/profiles/per-user/
 su - "$SUDO_USER" -c 'rm -rf ~/{.nix-profile,.nix-channels,.nix-defexpr/}'
 #EOF
 ) # (copy including this)
```

Now the NixOS system can be SSHed into (using a new master session, if any).


## Notes

Things the Nix installer did that we want:
* set up /nix
* set up the nix daemon service
    * `/etc/tmpfiles.d/nix-daemon.conf`
    * `/etc/systemd/system/nix-daemon.service` (link into default profile)
... and that we don't want
* mess with all sorts of shell profiles in /etc/
* add files to /root/
* add the build group and users


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS hardware config:
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.hardware.root-chroot;
in ({

    options.${prefix} = { hardware.root-chroot = {
        enable = lib.mkEnableOption "the configuration for a NixOS on (other) Linux (as root) system";
        homesDir = lib.mkOption { type = lib.types.nullOr lib.types.str; default = "/home"; };
        ssh-enter.viaHome = lib.mkOption { type = lib.types.bool; default = false; description = ''
            Enter the NixOS chroot on users' key-authenticated SSH connections by (over-)writing `''${..homesDir}/''${user.name}/.ssh/authorized_keys` with `''${user.openssh.authorizedKeys}` (and a command) for each `config.users.users` that `isNormalUser`.
            This may not work as expected if the home dir is a network share.
            Note that this (over-)writes files, but never removes them.
        ''; };
        ssh-enter.viaEtc = lib.mkOption { type = lib.types.bool; default = false; description = ''
            Enter the NixOS chroot on users' SSH connections by (over-)writing `/etc/ssh/sshd_config.d/nixos-enter.conf` (on the host) for each `config.users.users` that `isNormalUser`.
            This requires that file to persist and be included into the SSHd config (the default on recent SSHd installations).
            Note that this (over-)writes files, but never removes them.
        ''; };
        ssh-enter.opportunistic = lib.mkOption { type = lib.types.bool; default = true; description = ''
            If the entry hook is only partially installed, try to proceed with a notmal SSH connection to the host environment, instead of failing.
        ''; };
    }; };


} // { config = lib.mkIf (cfg.enable) (lib.mkMerge [ ({

    boot.isContainer = true; # in many ways, it's like in a container
    wip.base.includeInputs = inputs; # (with »isContainer«, it would usually omit »inputs.self«)

    system.activationScripts = (lib.fun.mapMerge (name: { ${name} = lib.mkForce ""; }) [
        "specialfs" "hashes" "domain" "hostname" "nix" # handled below and/or by the host
    ]) // {
        AAA_mount-all = ''mount --all''; # This won't unmount anything, and it will remount explicitly unmounted mount points, even if they have not changed.
        systemd-tmpfiles = ''
            ${config.systemd.package}/bin/systemd-tmpfiles --create --remove --exclude-prefix=/{dev,tmp,var,nix/var} # ,run
        '';

        wrappers = lib.stringAfter [ "specialfs" "users" ] config.systemd.services.suid-sgid-wrappers.script;
        binfmt = ''${config.systemd.package}/lib/systemd/systemd-binfmt'';

        users.text = lib.mkBefore (lib.concatMapStringsSep "\n" (file: ''cp -af /host/etc/${file} /etc/${file}'') [ "passwd" "shadow" "group" "subuid" "subgid" ]);
    };
    users.mutableUsers = lib.mkForce true; # (want to append to the host's users)
    environment.variables.NIX_REMOTE = lib.mkForce "";

    fileSystems = {
        inherit (config.boot.specialFileSystems) "/proc" "/run" "/run/keys" "/run/wrappers";
        "/sys" = { fsType = "sysfs"; options = [ "nosuid" "noexec" "nodev" ]; };
        "/proc/sys/fs/binfmt_misc" = { fsType = "binfmt_misc"; device = "binfmt_misc"; options = [ "nosuid" "noexec" "nodev" ]; };
    } // (lib.fun.mapMerge (target: source: { ${target} = { options = [ "rbind" ]; device = "/host/${source}"; }; }) {
        "/dev" = "dev";
        "/nix" = "nix"; "/tmp" = "tmp";
        ${cfg.homesDir} = cfg.homesDir; "/root" = "root";
        "/run/user" = "run/user";
        # TODO: /run/*?
        # TODO: /var/*?
    });

    environment.etc = {
        mtab.source = "/proc/mounts"; # (must be absolute)
    } // (lib.genAttrs [
        "resolv.conf"
    ] (path: { source = "/host/etc/${path}"; }));

    #programs.ssh.knownHostsFiles = [ "/host/etc/ssh/ssh_known_hosts" ];
    # TODO(PR): The default implementation tries to copy the path to the store, which will not work with flakes.
    programs.ssh.extraConfig = ''
        GlobalKnownHostsFile /etc/ssh/ssh_known_hosts ${builtins.concatStringsSep " " [ "/host/etc/ssh/ssh_known_hosts" ]}
    '';


}) (let ## Entering
    ssh-enter = "/nix/var/nix/profiles/system/ssh-enter"; # Use indirection, because SSHd only reads the config files on new (master) connections, but changes to this script should apply to new sessions as soon as the system got rebuilt.
    command = if cfg.ssh-enter.opportunistic then ''if test -e ${ssh-enter} ; then NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC=1 ${ssh-enter} ; else "$SHELL" ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"} ; fi'' else "exec ${ssh-enter}";
    users = builtins.filter (_:_.isNormalUser) (builtins.attrValues config.users.users);
    keys = user: user.authorizedKeys.keys ++ builtins.concatLists (map (file: lib.splitString "\n" (lib.fileContents file)) user.authorizedKeys.keyFiles);
in {

    services.openssh.enable = true; # (has to be enabled on the host too)
    system.activationScripts.chroot-enter = lib.mkIf cfg.ssh-enter.viaEtc ''
        ln -sfT ${pkgs.writeText "sshd_nixos-enter.conf" (lib.concatMapStringsSep "\n" (user: ''
            Match User ${user.name}
                ForceCommand ${command}
                AuthorizedKeysFile %h/.ssh/authorized_keys /nix/var/nix/profiles/system/etc/ssh/authorized_keys.d/${user.name}
        '') users)} /host/etc/ssh/sshd_config.d/nixos-enter.conf
        chroot /proc/1/cwd ${config.systemd.package}/bin/systemctl reload ssh.service
    '';

    systemd.tmpfiles.rules = lib.mkIf cfg.ssh-enter.viaHome (map (user: lib.fun.mkTmpfile {
        type = "f+"; path = "${cfg.homesDir}/${user.name}/.ssh/authorized_keys"; mode = 644; argument = ''
            # Auto-generated, do not edit!
            ${lib.concatMapStrings (key: ''command=${builtins.toJSON command} ${key}'') (keys user)}
        '';
    }) users);

    system.extraSystemBuilderCmds = ''
        ln -sT ${config.nix.package} $out/nix # target of /host/nix/var/nix/profiles/default
        ln -sT ${pkgs.writeShellScript "ssh-nixos-chroot-enter" ''
            if [[ ''${NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC:-} ]] ; then if ! sudo -v ; then
                echo 1>&2 'No sudo access to enter NixOS root chroot, running on host' ; exec "$SHELL" ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"}
            fi ; fi
            if [[ ''${SSH_ORIGINAL_COMMAND} == internal-sftp ]] ; then
                SSH_ORIGINAL_COMMAND='exec ${pkgs.openssh}/libexec/sftp-server'
            fi
            exec sudo ${lib.getExe pkgs.root-chroot-enter} /run/current-system/sw/bin/su - $USER ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"}
        ''} $out/ssh-enter
    '';
    system.extraDependencies = [ pkgs.root-chroot-enter pkgs.openssh ];

    # Entering the chroot (currently) requires (passwordless) sudo. So might as well grant that in the chroot as well.
    security.sudo.extraRules = [ { users = map (_:_.name) (builtins.filter (_:_.isNormalUser) (builtins.attrValues config.users.users)); commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ]; } ];


}) ({

    environment.shellAliases.nixos-rebuild-switch = ''( system=$( nix build --no-link --print-out-paths "$(realpath /etc/nixos)"#nixosConfigurations."$(hostname)".config.system.build.toplevel ) && sudo nix-env -p /nix/var/nix/profiles/system --set "$system" && sudo /nix/var/nix/profiles/system/activate )''; # (»sudo nixos-rebuild switch« fails to find git; because of some mount-namespace issues?)
    environment.shellAliases.host-sc = ''sudo chroot /proc/1/cwd "$( realpath "$( which systemctl )" )"''; # allow (explicit) interactions with systemctl (on the host)
    environment.shellAliases.on-host = ''bash -c 'exec sudo chroot /proc/1/cwd "$( realpath "$( which "$0" )" )" "$@"' ''; # same for any related commands

    system.build.initialRamdisk = lib.mkDefault "/var/empty"; # missing with isContainer, but something is using it


}) ]); })
