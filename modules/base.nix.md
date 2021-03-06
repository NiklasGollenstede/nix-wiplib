/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.base;
in {

    options.${prefix} = { base = {
        enable = lib.mkEnableOption "saner defaults";
        includeInputs = lib.mkOption { description = "Whether to include all build inputs to the configuration in the final system, such that they are available for self-rebuilds, in the flake registry, and on the »NIX_PATH« entry (e.g. as »pkgs« on the CLI)."; type = lib.types.bool; default = specialArgs?inputs && specialArgs.inputs?self && specialArgs.inputs?nixpkgs; };
    }; };

    # Bugfix:
    imports = [ (lib.wip.overrideNixpkgsModule ({ inherit inputs; } // specialArgs) "misc/extra-arguments.nix" (old: { config._module.args.utils = old._module.args.utils // {
        escapeSystemdPath = s: builtins.replaceStrings [ "/" "-" " " "." ] [ "-" "\\x2d" "\\x20" "\\x2e" ] (lib.removePrefix "/" s); # The original function does not escape ».«, resulting in mismatching names with units generated from paths with ».« in them.
    }; })) ];

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
        implied = true; # some mount points are implied (and forced) to be »neededForBoot« in »specialArgs.utils.pathsNeededForBoot« (this marks those here)

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        users.mutableUsers = false; users.allowNoPasswordLogin = true; # Don't babysit. Can roll back or redeploy.
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = lib.mkDefault (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # this works, but it "should be considered "confidential", and must not be exposed in untrusted environments" (not sure _why_ though)
        documentation.man.enable = lib.mkDefault config.documentation.enable;


    }) ({
        # Robustness/debugging:

        boot.kernelParams = [ "panic=10" "boot.panic_on_fail" ]; # Reboot on kernel panic (showing the printed messages for 10s), panic if boot fails.
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
        systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.


    }) (lib.mkIf cfg.includeInputs { # non-flake

        # Importing »<nixpkgs>« as non-flake returns a lambda returning the evaluated Nix Package Collection (»pkgs«). The most accurate representation of what that should be on the target host is the »pkgs« constructed when building it:
        system.extraSystemBuilderCmds = ''
            ln -sT ${pkgs.writeText "pkgs.nix" ''
                # Provide the exact same version of (nix)pkgs on the CLI as in the NixOS-configuration (but note that this ignores the args passed to it; and it'll be a bit slower, as it partially evaluates the host's configuration):
                args: (builtins.getFlake ${builtins.toJSON specialArgs.inputs.self.outPath}).nixosConfigurations.${name}.pkgs
            ''} $out/pkgs # (nixpkgs with overlays)
        ''; # (use this indirection so that all open shells update automatically)

        nix.nixPath = [ "nixpkgs=/run/current-system/pkgs" ]; # this intentionally replaces the defaults: nixpkgs is here, /etc/nixos/flake.nix is implicit, channels are impure
        # TODO: decide whether to put any other flake inputs also on the nix path: con: they may very well not even have a »./default.nix«
        nix.autoOptimiseStore = true; # because why not ...
        environment.shellAliases = { "with" = ''nix-shell --run "bash --login" -p''; }; # »with« doesn't seem to be a common linux command yet, and it makes sense here: with $package => do stuff in shell

    }) (lib.mkIf cfg.includeInputs { # flake things

        # "input" to the system build is definitely also a nix version that works with flakes:
        nix.extraOptions = "experimental-features = nix-command flakes"; # apparently, even nix 2.8 (in nixos-22.05) needs this
        environment.systemPackages = [ pkgs.git ]; # necessary as external dependency when working with flakes

        # »inputs.self« does not have a name (that is known here), so just register it as »/etc/nixos/« system config:
        environment.etc.nixos.source = lib.mkDefault "/run/current-system/config"; # (use this indirection to prevent every change in the config to necessarily also change »/etc«)
        system.extraSystemBuilderCmds = ''
            ln -sT ${specialArgs.inputs.self.outPath} $out/config # (build input for reference)
        '';

        # Add all inputs to the flake registry:
        nix.registry = lib.mapAttrs (name: input: lib.mkDefault { flake = input; }) (builtins.removeAttrs specialArgs.inputs [ "self" ]);


    }) ({
        # Free convenience:

        programs.bash.promptInit = lib.mkDefault ''
        # Provide a nice prompt if the terminal supports it.
        if [ "''${TERM:-}" != "dumb" ] ; then
            if [[ "$UID" == '0' ]] ; then if [[ ! "''${SUDO_USER:-}" ]] ; then # direct root: red username + green hostname
                PS1='\[\e[0m\]\[\e[48;5;234m\]\[\e[96m\]$(printf "%-+ 4d" $?)\[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[91m\]\u\[\e[97m\]@\[\e[92m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'
            else # sudo root: red username + red hostname
                PS1='\[\e[0m\]\[\e[48;5;234m\]\[\e[96m\]$(printf "%-+ 4d" $?)\[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[91m\]\u\[\e[97m\]@\[\e[91m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'
            fi ; else # other user: green username + green hostname
                PS1='\[\e[0m\]\[\e[48;5;234m\]\[\e[96m\]$(printf "%-+ 4d" $?)\[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[92m\]\u\[\e[97m\]@\[\e[92m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'
            fi
            if test "$TERM" = "xterm" ; then
                PS1="\[\033]2;\h:\u:\w\007\]$PS1"
            fi
        fi
        export TERM_RECURSION_DEPTH=$(( 1 + ''${TERM_RECURSION_DEPTH:-0} ))
        ''; # The non-interactive version of bash does not remove »\[« and »\]« from PS1, but without those the terminal gets confused about the cursor position after the prompt once one types more than a bit of text there (at least via serial or SSH).

        environment.interactiveShellInit = lib.mkDefault ''
            if [[ "$(realpath /dev/stdin)" != /dev/tty[1-8] && $LINES == 24 && $COLUMNS == 80 ]] ; then
                stty rows 34 cols 145 # Fairly large font on 1080p. Definitely a better default than 24x80.
            fi
        '';

    }) ]);

}
