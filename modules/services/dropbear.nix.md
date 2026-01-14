/*

# Dropbear SSHd Configuration

OpenSSH adds ~35MB closure size. Let's try `dropbear` instead!


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.services.dropbear;
in {

    options.${prefix} = { services.dropbear = {
        enable = lib.mkEnableOption "dropbear SSH daemon";
        package = lib.mkPackageOption pkgs "dropbear" { };
        flags = lib.mkOption { description = "Flags to pass to dropbear"; type = lib.types.attrsOf (lib.types.oneOf [ (lib.types.listOf lib.types.str) lib.types.str lib.types.bool ]); default = { "w" = true; }; };
        port = lib.mkOption { description = "TCP port to listen on and open a firewall rule for."; type = lib.types.port; default = 22; };
        openFirewall = (lib.mkEnableOption "opened firewall port for the dropbear SSH daemon") // { default = true; example = false; };
        socketActivation = lib.mkEnableOption "socket activation mode for dropbear, where systemd launches dropbear on incoming TCP connections, instead of dropbear permanently running and listening on its TCP port";
        rootKeys = lib.mkOption { description = "Literal lines to write to »/root/.ssh/authorized_keys«"; default = ""; type = lib.types.lines; };
        hostKeys = lib.mkOption { description = "Location of the host key(s) to use. If empty, then a key(s) will be generated at »/etc/dropbear/dropbear_(ecdsa/rsa)_host_key« on first access to the server."; default = [ ]; type = lib.types.listOf lib.types.path; };
        sftpServer.enable = lib.mkEnableOption "openssh's sftp-server for dropbear";
        sftpServer.package = lib.mkPackageOption pkgs "openssh" { };
    }; };

    config = let
        args = lib.concatLists (lib.mapAttrsToList (flag: value: if flag == false then [ ] else if value == true then [ "-${flag}" ] else if lib.isList value then lib.concatMap (v: [ "-${flag}" v ]) value else [ "-${flag}" value ]) cfg.flags);

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        ${prefix}.services.dropbear.flags = {
            "s" = true; # disable password login
        } // (if cfg.hostKeys == [ ] then {
            "R" = true; # generate host keys on connection
        } else {
            "r" = cfg.hostKeys;
        });

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

        systemd.tmpfiles.rules = lib.mkIf (cfg.rootKeys != "") [ (lib.fun.mkTmpfile { type = "L+"; path = "/root/.ssh/authorized_keys"; argument = pkgs.writeText "root-ssh-authorized_keys" cfg.rootKeys; }) ];

        environment.etc."dropbear/.keep" = lib.mkIf (cfg.hostKeys == [ ]) { source = "/dev/null"; }; # could maybe be changed using DROPBEAR_RSAKEY_DIR

        environment.extraSetup = lib.mkIf cfg.sftpServer.enable ''
            if [[ ! -e $out/libexec/sftp-server ]] ; then
                mkdir -p $out/libexec
                ln -s ${cfg.sftpServer.package}/libexec/sftp-server $out/libexec/sftp-server
            fi
        '';

    }) (lib.mkIf (!cfg.socketActivation) {

        ${prefix}.services.dropbear.flags = {
            "p" = toString cfg.port; # listen on TCP/${port}
            "F" = true; "E" = true; # don't fork, log to stderr
        };

        systemd.services."dropbear" = {
            description = "dropbear SSH server (listening)";
            wantedBy = [ "multi-user.target" ]; after = [ "network.target" ];
            serviceConfig.ExecStart = utils.escapeSystemdExecArgs ([ "${cfg.package}/bin/dropbear" ] ++ args);
            #serviceConfig.PIDFile = "/var/run/dropbear.pid"; serviceConfig.Type = "forking"; after = [ "network.target" ]; # alternative to »-E -F« (?)
        };

    }) (lib.mkIf (cfg.socketActivation) {

        ${prefix}.services.dropbear.flags = {
            "i" = true; # handle a single connection on stdio
        };

        systemd.sockets.dropbear = { # start a »dropbear@.service« on any number of TCP connections on port 22
            conflicts = [ "dropbear.service" ];
            listenStreams = [ "${toString cfg.port}" ];
            socketConfig.Accept = "yes";
            wantedBy = [ "sockets.target" ]; # (implicitly also "after" this)
        };
        systemd.services."dropbear@" = {
            description = "dropbear SSH server (per-connection)";
            serviceConfig.ExecStart = utils.escapeSystemdExecArgs ([ "-${cfg.package}/bin/dropbear" ] ++ args);
            serviceConfig.StandardInput = "socket";
            #serviceConfig.StandardError = "journal"; # already logs to the journal
            unitConfig.CollectMode = "inactive-or-failed";
        };

    }) ]);

}
