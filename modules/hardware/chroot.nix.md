/*

# Nix(OS-ish env) on Linux with Root Access

For when you have Linux with root access (and Nix installed), but what you really want is NixOS.
Except for service management, this is pretty close to a "real" NixOS installation, with `sudo` working "inside" NixOS.


## Usage

Include this in the host configuration:
```nix
{   nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "24.05";
    wip.hardware.chroot.enable = true;
    wip.hardware.chroot.ssh-enter.viaEtc = true;
    users.users.me = {
        isNormalUser = true; # => ssh-enter
        home = "${config.wip.hardware.chroot.homesDir}/me";
        openssh.authorizedKeys.keyFiles = [ ... ];
    }; # might want to change U/GIDs to match the host's, to avoid warnings
}
```


## Installation -- `root` Mode

To initialize the NixOS environment:
* install Nix system-wide on the target host (e.g., as `sudo` user (not `root`), run `sh <(curl -L https://nixos.org/nix/install) --daemon`),
* build the config on the target by running (on your dev machine in the flake defining the system) `nix run .#update-host -- <host> build`,
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


## Installation -- `user` Mode

`nix-user-chroot` v1.0.3 is only built for x64, but in later versions [the nix build sandbox is broken](https://github.com/nix-community/nix-user-chroot/issues/102) (on Debian/Ubuntu?).
Because it is also generally much more flexible, this uses `bwrap` (tested with version 0.4.1 and 0.8.0) instead.

The `$nixDir` has to be user-writable. Additionally, `$nixDir/store` may grow large and should not be slow, and `$nixDir/var/nix/profiles` should not be synced with hosts that require a different configuration.
So `nixDir=$HOME/.nix` can be a good choice, as long as it is not on a network share.

TODO: test this (again):

To install and activate the nixos-chroot, adjust and run the below (either all at once or line-by-line):
```bash
 # bash -u -o pipefail -x -e <(cat << " #EOF" # (copy from after the first #)

 ## Settings
 config=$HOME/dev/nix/nixos-config # flake defining the system's config
 nixDir=$HOME/.nix # see above

 ## Install Nix
 mkdir -p -m 0755 "$nixDir"
 curl='curl -L' ; if ! which curl &>/dev/null ; then curl='wget -nv -O-' ; fi
 bwrap --die-with-parent --bind "$nixDir" /nix --proc /proc --dev /dev $( for mnt in $( shopt -s extglob ; eval 'echo /!(dev|proc|nix)' ) ; do [[ ! -e $mnt ]] || echo --bind $mnt $mnt ; done ) -- sh <($curl https://nixos.org/nix/install) --no-daemon

 ## Build and Register NixOS System
 system=$( PATH=$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin "$( which bwrap )" --die-with-parent --bind "$nixDir" /nix --proc /proc --dev /dev $( for mnt in $( shopt -s extglob ; eval 'echo /!(dev|proc|nix)' ) ; do [[ ! -e $mnt ]] || echo --bind $mnt $mnt ; done ) -- nix-shell --run 'nix --extra-experimental-features "nix-command flakes" build '"$config"'#nixosConfigurations.'"$( hostname )"'.config.system.build.toplevel --no-link --print-out-paths' -p git )
 mkdir -p -m 755 "$nixDir"/var/nix/{profiles,gcroots}/per-user
 ln -sfT $system "$nixDir"/var/nix/profiles/system-1-link
 ln -sfT system-1-link "$nixDir"/var/nix/profiles/system
 ln -sfT /nix/var/nix/profiles "$nixDir"/var/nix/gcroots/profiles
 rm -rf "$nixDir"/var/nix/profiles/per-user/"$( id -un )"/* "$HOME"/.nix-{channels,defexpr,profile}

 ## Activate the System
 SSH_ORIGINAL_COMMAND='echo "Installation done!"' ${nixDir}/${system#/nix/}/ssh-enter
 #EOF
 ) # (copy including this)
```

Now the NixOS system can be SSHed into (using a new master session, if any).


## Notes

* `nixos-rebuild switch` does not work. Instead use `nixos-rebuild boot && /nix/var/nix/profiles/system/activate` or the `nixos-rebuild-switch` alias.


### Implementation Notes

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
dirname: inputs: moduleArgs@{ config, options, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.hardware.chroot;
in ({

    options.${prefix} = { hardware.chroot = {
        enable = lib.mkEnableOption "the configuration for a NixOS on (other) Linux (as root) system";
        homesDir = lib.mkOption { type = lib.types.nullOr (lib.types.strMatching ''^/.*[^/]$''); default = "/home"; };
        mode = lib.mkOption { type = lib.types.enum [ "root" "user" ]; default = "root"; };
        userMode.nixDir = lib.mkOption { type = lib.types.nullOr (lib.types.strMatching ''^/.*[^/]$''); default = null; };
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
        AAA_mount-all = lib.mkIf (cfg.mode == "root") ''mount --all''; # This won't unmount anything, and it will remount explicitly unmounted mount points, even if they have not changed.
        systemd-tmpfiles = ''
            ${config.systemd.package}/bin/systemd-tmpfiles --create --remove --exclude-prefix=/{dev,tmp,var,nix/var${lib.optionalString (cfg.mode == "user") ",run"}}
        '';

        wrappers = lib.mkIf (cfg.mode == "root") (lib.stringAfter [ "specialfs" "users" ] config.systemd.services.suid-sgid-wrappers.script);
        binfmt = lib.mkIf (cfg.mode == "root") ''${config.systemd.package}/lib/systemd/systemd-binfmt'';

        users.text = let
            inheritFiles = ''mkdir -p /etc ; ${lib.concatMapStringsSep "\n" (file: ''cp -af /host/etc/${file} /etc/${file}'') ([ "passwd" "group" "subuid" "subgid" ] ++ lib.optional (cfg.mode == "root") "shadow")}'';
            patched = pkgs.runCommand "update-users-groups.pl" { } ''
                cp -T ${inputs.nixpkgs}/nixos/modules/config/update-users-groups.pl $out
                substituteInPlace $out --replace-fail '(chown($uid, $gid, $path) || die "Failed to change ownership of $path: $!") unless $is_dry;' ""
            '';
        in if !moduleArgs.lib?mkApply then (
            if cfg.mode == "root" then lib.mkBefore inheritFiles else let
                spec = let cfg = config.users; in with lib; pkgs.writeText "users-groups.json" (builtins.toJSON {
                    inherit (cfg) mutableUsers;
                    users = mapAttrsToList (_: u: {
                        inherit (u)
                            name uid group description home homeMode createHome isSystemUser
                            password hashedPasswordFile hashedPassword
                            autoSubUidGidRange subUidRanges subGidRanges
                            initialPassword initialHashedPassword expires;
                        shell = utils.toShellPath u.shell;
                    }) cfg.users;
                    groups = attrValues cfg.groups;
                });
            in lib.mkForce ''
                ${inheritFiles}
                install -m 0700 -d /root
                install -m 0755 -d /home

                ${pkgs.perl.withPackages (p: [ p.FileSlurp p.JSON ])}/bin/perl \
                -w ${patched} ${spec}
            ''
        ) else lib.mkMerge [
            (lib.mkBefore inheritFiles)
            (lib.mkIf (cfg.mode == "user") (moduleArgs.lib.mkApply (script: let
                strings = builtins.match ''(.*)/nix/store/[a-z0-9]+-update-users-groups[.]pl(.*)'' script;
            in (lib.addContextFrom script (builtins.elemAt strings 0) + patched + (builtins.elemAt strings 1)))))
        ];
    };
    users.mutableUsers = lib.mkForce true; # (want to append to the host's users)
    environment.variables.NIX_REMOTE = lib.mkForce "";
    environment.stub-ld.enable = lib.mkIf (cfg.mode == "user") (lib.mkDefault false);

    fileSystems = (/* lib.optionalAttrs (cfg.mode == "root")  */{
        inherit (config.boot.specialFileSystems) "/proc";
        "/sys" = { fsType = "sysfs"; options = [ "nosuid" "noexec" "nodev" ]; };
    }) // (lib.optionalAttrs (cfg.mode == "root") {
        inherit (config.boot.specialFileSystems) "/run" "/run/keys" "/run/wrappers";
        "/proc/sys/fs/binfmt_misc" = { fsType = "binfmt_misc"; device = "binfmt_misc"; options = [ "nosuid" "noexec" "nodev" ]; };
    }) // (lib.optionalAttrs (cfg.mode == "user") {
        "/dev" = { fsType = "devtmpfs"; device = "auto"; };
    }) // (lib.fun.mapMerge (target: source: {
        ${target} = { options = [ "rbind" ]; device = "/host/${source}"; };
    }) ((lib.optionalAttrs (cfg.mode == "root") {
        "/dev" = "dev";
        "/nix" = "nix";
        "/root" = "root";
        ${cfg.homesDir} = lib.removePrefix "/" cfg.homesDir;
    }) // (lib.optionalAttrs (cfg.mode == "user") {
        #"${cfg.homesDir}/${user.name}" = "${lib.removePrefix "/" cfg.homesDir}/${user.name}";
    }) // {
        "/tmp" = "tmp";
        "/run/user" = "run/user";
        # TODO: /run/*?
        # TODO: /var/*?
    }));

    environment.etc = {
        mtab.source = "/proc/mounts"; # (must be absolute)
    } // (lib.genAttrs [
        "resolv.conf"
    ] (path: lib.mkDefault { source = "/host/etc/${path}"; }));

    #programs.ssh.knownHostsFiles = [ "/host/etc/ssh/ssh_known_hosts" ];
    # TODO(PR): The default implementation tries to copy the path to the store, which will not work with flakes.
    programs.ssh.extraConfig = ''
        GlobalKnownHostsFile /etc/ssh/ssh_known_hosts ${builtins.concatStringsSep " " [ "/host/etc/ssh/ssh_known_hosts" ]}
    '';


}) (let ## Entering
    nixDir = if cfg.userMode.nixDir != null then cfg.userMode.nixDir else "${cfg.homesDir}/${user.name}/.nix";
    ssh-enter = if cfg.mode == "root" then "/nix/var/nix/profiles/system/ssh-enter" else "${nixDir}/$( system=$( readlink -m ${nixDir}/var/nix/profiles/system ) ; echo \${system#/nix/} )/ssh-enter"; # Use indirection, because SSHd only reads the config files on new (master) connections, but changes to this script should apply to new sessions as soon as the system got rebuilt.
    command = "enter=${ssh-enter} ; ${if cfg.ssh-enter.opportunistic then ''if test -e $enter ; then NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC=1 exec $enter ; else "$SHELL" ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"} ; fi'' else "exec $enter"}";
    users = builtins.filter (_:_.isNormalUser) (builtins.attrValues config.users.users); user = builtins.head users;
    keys = user: user.openssh.authorizedKeys.keys ++ builtins.concatLists (map (file: lib.splitString "\n" (lib.fileContents file)) user.openssh.authorizedKeys.keyFiles);
in {

    assertions = [ {
        assertion = (cfg.mode == "user") -> ((builtins.length users) == 1);
        message = ''With `${options.${prefix}.hardware.chroot.mode} == "root`, exactly one user can have `.isNormalUser == true`.'';
    } ];

    services.openssh.enable = true; # (has to be enabled on the host too)
    system.activationScripts.chroot-enter = lib.mkIf cfg.ssh-enter.viaEtc ''
        ln -sfT ${pkgs.writeText "sshd_nixos-enter.conf" (lib.concatMapStringsSep "\n" (user: ''
            Match User ${user.name}
                ForceCommand ${command}
                # SSH refuses to read/execute anything in /nix/store. The ...Command works around that and is in addition to ...File.
                AuthorizedKeysCommandUser ${user.name}
                AuthorizedKeysCommand /usr/bin/env -S cat /nix/var/nix/profiles/system/etc/ssh/authorized_keys.d/${user.name}
        '') users)} /host/etc/ssh/sshd_config.d/nixos-enter.conf
        chroot /proc/1/cwd ${config.systemd.package}/bin/systemctl reload ssh.service
    '';

    systemd.tmpfiles.rules = lib.mkIf cfg.ssh-enter.viaHome (map (user: lib.fun.mkTmpfile {
        type = "f+"; path = "${cfg.homesDir}/${user.name}/.ssh/authorized_keys"; mode = 644; argument = ''
            # Auto-generated, do not edit!
            ${lib.concatMapStringsSep "\n" (key: ''command=${builtins.toJSON command} ${key}'') (keys user)}
        '';
    }) users);

    system.extraSystemBuilderCmds = ''
        ln -sT ${config.nix.package} $out/nix # target of /host/nix/var/nix/profiles/default
        install -T <(cat << "#EOF"${"\n" +''
            #!${if cfg.mode == "root" then pkgs.runtimeShell else "/usr/bin/env bash"}
            ${lib.optionalString (cfg.mode == "root") ''
                if [[ ''${NIXOS_CHROOT_SSH_ENTER_OPPORTUNISTIC:-} ]] ; then if ! sudo -v ; then
                    echo 1>&2 'No sudo access to enter NixOS root chroot, running on host' ; exec "$SHELL" ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"}
                fi ; fi
            ''}
            if [[ ''${SSH_ORIGINAL_COMMAND:-} == internal-sftp || ''${SSH_ORIGINAL_COMMAND:-} == /usr/lib/openssh/sftp-server ]] ; then
                SSH_ORIGINAL_COMMAND='exec ${pkgs.openssh}/libexec/sftp-server'
            fi
            ${if cfg.mode == "root" then ''
                exec sudo ${lib.getExe pkgs.root-chroot-enter} ${pkgs.shadow.su}/bin/su - $USER ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"}
            '' else ''
                NIX_DIR=${nixDir} exec ${nixDir}${lib.removePrefix "/nix" pkgs.user-chroot-enter.src} ${/* utils.toShellPath */lib.getExe user.shell} ''${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"}
            ''}
        '' + "\n#EOF\n"}) -m 555 $out/ssh-enter
    '';
    system.extraDependencies = [ pkgs.root-chroot-enter pkgs.openssh ];

    # Entering the chroot (currently) requires (passwordless) sudo. So might as well grant that in the chroot as well.
    security.sudo.extraRules = [ { users = map (_:_.name) (builtins.filter (_:_.isNormalUser) (builtins.attrValues config.users.users)); commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ]; } ];


}) ({

    environment.shellAliases = if cfg.mode == "root" then {
        nixos-rebuild-switch = ''( system=$( nix build --no-link --print-out-paths "$(realpath /etc/nixos)"#nixosConfigurations."$(hostname)".config.system.build.toplevel ) && sudo nix-env -p /nix/var/nix/profiles/system --set "$system" && sudo /nix/var/nix/profiles/system/activate )''; # (»sudo nixos-rebuild switch« fails to find git; because of some mount-namespace issues?)
        host-sc = ''sudo chroot /proc/1/cwd "$( realpath "$( which systemctl )" )"''; # allow (explicit) interactions with systemctl (on the host)
        on-host = ''bash -c 'exec sudo chroot /proc/1/cwd "$( realpath "$( which "$0" )" )" "$@"' ''; # same for any related commands
        #leave-chroot = ''sudo chroot /proc/1/cwd /nix/var/nix/profiles/system/sw/bin/su - $USER''; # This should work ...
        #leave-chroot = ''sudo chroot /proc/1/cwd /nix/var/nix/profiles/system/sw/bin/bash -c 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin su - '$USER '';
        leave-chroot = ''sudo PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin chroot /proc/1/cwd bash -l'';
    } else {
        nixos-rebuild-switch = "nixos-rebuild boot && /nix/var/nix/profiles/system/activate";
    };

    system.build.initialRamdisk = lib.mkDefault "/var/empty"; # missing with isContainer, but something is using it


}) ]); })
