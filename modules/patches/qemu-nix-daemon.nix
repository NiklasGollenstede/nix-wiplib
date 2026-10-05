dirname: inputs: { config, options, pkgs, lib, modulesVersion, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.virtualisation;
in {
    options.virtualisation.exposeHostNixDaemon = lib.mkEnableOption ''
        exposing the host Nix daemon to the VM, and configuring the VM to use it as Nix backend.
        This allows for VMs (i.e., environments with separate kernel and true root access) that build and boot very quickly and can still use Nix.
        Build results are stored persistently in the host's Nix store, but most types of GC references will not work, and evaluation is considerably slower.

        Note that the VM will have the same access to the Nix daemon as the user that launched the VM.
        The guest can therefore run arbitrary commands in Nix build sandboxes on the host, which basically reduces the VM security boundary to that of containers.

        The current implementation of this requires a TCP port accessible within the VM, so _any_ VM process can connect to the host Nix daemon.
    '';

    config = lib.optionalAttrs (options.virtualisation.qemu.options or null != null) (lib.mkIf cfg.exposeHostNixDaemon (let
        # We need:
        guestAddress = "${subnetPrefix}.2"; # an address that the guest can assign to its interface
        macAddress = "52:54:07:6e:24:19"; # a fixed MAC to identify the interface (`printf '52:54:%02x:%02x:%02x:%02x\n' $(od -An -N4 -tu1 /dev/urandom)`)
        forwardAddress = "${subnetPrefix}.0"; forwardPort = 6642; # an address that the guest routes through that interface and that qemu's networking can intercept for the forwarding (and any port number)
        hostForwardCommand = "${lib.getExe pkgs.socat} STDIO UNIX-CONNECT:${nixSocket}"; # the command that directs the intercepted connection to the Nix daemon socket (on the host)
        hostAddress = "${subnetPrefix}.1"; # maybe also a host address
        dnsAddress = "${subnetPrefix}.3"; # an address that qemu requires for its DNS server
        subnetPrefix = "10.254.253"; subnetAddress = "${subnetPrefix}.0"; subnetLength = 30; # a subnet with those addresses that does not conflict with anything inside the VM

        nixSocket = "/nix/var/nix/daemon-socket/socket";
    in {
        virtualisation.qemu.networkingOptions = lib.mkBefore [
            "-device" "virtio-net-pci,netdev=nix-daemon,mac=${macAddress},addr=0x5" # specify a fixed PCI slot to sort this interface after the default one, so that linux still calls that `eth0`
            "-netdev" (lib.concatStringsSep "," [
                "user" "id=nix-daemon"
                "net=${subnetAddress}/${toString subnetLength}" "host=${hostAddress}"
                "dns=${dnsAddress}" "dhcp${"start"}=${subnetPrefix}.0" # can't be disabled
                "guestfwd=tcp:${forwardAddress}:${toString forwardPort}-cmd:${lib.escapeShellArg hostForwardCommand}"
            ])
        ];

        systemd.network.links."10-nix-daemon" = { # also works without `systemd.network.enable`
            matchConfig.MACAddress = macAddress;
            linkConfig.Name = "nix-daemon";
        };
        networking.interfaces.nix-daemon = {
            useDHCP = false;
            ipv4.addresses = [ { address = guestAddress; prefixLength = subnetLength; } ];
        };

        systemd.sockets.nix-daemon = {
            description = "Nix daemon proxy socket";
            wantedBy = [ "sockets.target" ];
            socketConfig = {
                ListenStream = nixSocket; SocketMode = "0666";
                Accept = true; RemoveOnStop = true;
            };
        };
        systemd.services."nix-daemon@" = {
            description = "Nix daemon guestfwd proxy";
            serviceConfig = {
                Type = "simple"; KillMode = "process";
                StandardInput = "socket"; StandardOutput = "socket";
                ExecStart = "${lib.getExe pkgs.socat} STDIO TCP:${forwardAddress}:${toString forwardPort}";
            };
        };

        nix.enable = lib.mkVMOverride true;
        nix.daemon.enable = lib.mkVMOverride false;
        nix.gc.automatic = lib.mkVMOverride false;
        nix.settings.store = lib.mkVMOverride "unix://${nixSocket}";
        # Many settings are not applicable when using an external daemon.
        # Additionally, the TCP port is available to all users in the VM, so "allowed-users" has no effect.

        virtualisation = {
            mountHostNixStore = true; # required to see build results
            writableStore = false; # makes no sense
            additionalPaths = lib.mkForce [ ]; # not necessary (and VM builds+boots faster without)
        };
    }));
}
