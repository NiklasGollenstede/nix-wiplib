/*

# Bash Defaults

Fairly objectively better defaults for interactive bash shells.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.profiles.bash;
in {

    options.${prefix} = { profiles.bash = {
        enable = lib.mkEnableOption "fairly objectively better defaults for interactive bash shells";
        functions = lib.mkOption {
            type = lib.types.attrsOf lib.types.str; default = { }; example = { "my-func" = ''echo "Hello, world!"''; };
            description = ''Additional functions to be added to the bash shell. The attribute name becomes the function name, and the value the body.'';
        };
    }; };


    config = lib.mkIf cfg.enable (lib.mkMerge [ ({

        ${prefix}.profiles.bash.functions = {
            ## »with« doesn't seem to be a common unix command yet, and it makes sense here: with package(s) => do stuff
            "with" = "local supportInline=1 ; source ${../../pkgs/scripts/with.sh}";
            lp = ''path=''${1:-$PWD$} ; rel="$( basename "$path" )" ; cd "$( dirname "$path" )" && namei -lx "$PWD"/"$rel"''; # similar to »ll -d« on all path element from »$1« to »/«
        };

        environment.shellAliases = {

            ls = "ls --color=auto"; # (default)
            l  = "ls -alhF"; # (added F)
            ll = "ls -alF"; # (added aF)
            lt = "${lib.getExe pkgs.tree} -a -p -g -u -s -D -F --timefmt '%Y-%m-%d %H:%M:%S' -I '.git/|node_modules/'"; # ll like tree

            # colorized listing of all interface's IPs
            ips = "ip -c -br addr";
            # »/proc/mounts«, cleaned up and formatted as a sorted table (the output of »mount« does not escape whitespace)
            mounts = pkgs.writeShellScript "mounts" ''
                ${pkgs.coreutils}/bin/cat /proc/mounts | if [[ ''${1:-} ]] ; then
                    P=P ; if [[ $1 == .* ]] ; then P=F ; set -- "$( realpath "$1" )" || exit ; fi
                    ${pkgs.gnugrep}/bin/grep -vPe '/[.]zfs/snapshot/' | ${pkgs.gnugrep}/bin/grep -$P -e ' '"$1"
                else
                    ${pkgs.gnugrep}/bin/grep -vPe '/[.]zfs/snapshot/| /var/lib/docker/|^/var/lib/snapd/snaps/'
                fi | LC_ALL=C ${pkgs.coreutils}/bin/sort -k2 | ${pkgs.util-linux}/bin/column -t -N Device/Source,Mountpoint,Type,Options,X,Y -H X,Y -W Device/Source,Mountpoint,Options
            '';
            #mounts = pkgs.writeShellScript "mounts" ''${pkgs.util-linux}/bin/mount | if [[ ''${1:-} ]] ; then ${pkgs.gnugrep}/bin/grep -vPe '/.zfs/snapshot/' | ${pkgs.gnugrep}/bin/grep -Pe ' on '"$1" ; else ${pkgs.gnugrep}/bin/grep -vPe '/.zfs/snapshot/| on /var/lib/docker/|^/var/lib/snapd/snaps/' ; fi | LC_ALL=C ${pkgs.coreutils}/bin/sort -k3 | ${pkgs.util-linux}/bin/column -t -N Device/Source,on,Mountpoint,type,Type,Options -H on,type -W Device/Source,Mountpoint,Options''; # (...grep ' on /'"''${1#/}")

            # execute a command in a different netns (like »ip netns exec«), without requiring root permissions (but does require »config.programs.firejail.enable=true«)
            netns-exec = pkgs.writeShellScript "netns-exec" ''ns=$1 ; shift ; /run/wrappers/bin/firejail --noprofile --quiet --netns="$ns" -- "$@"'';
            #netns-exec = ''/run/wrappers/bin/firejail --noprofile --quiet --netns "$@"''; # TODO: check if this works as well / instead

            nix-trace = "nix --option eval-cache false --show-trace";
            nixos-list-generations = "nix-env --list-generations --profile /nix/var/nix/profiles/system";

        } // (lib.fun.mapMerge (s: user: { # sc* + uc*

            "${s}c"  = "systemctl${user}";
            "${s}cs" = "systemctl${user} status";
            "${s}cc" = "systemctl${user} cat";
            "${s}cu" = "systemctl${user} start"; # up
            "${s}cd" = "systemctl${user} stop"; # down
            "${s}cr" = "systemctl${user} restart";
            "${s}cf" = "systemctl${user} list-units --state error --state bad --state bad-setting --state failed --state auto-restart"; # ("auto-restart" is waiting to be restarted (i.e, has RestartSec and and the rate limit was not yet reached). I don't know how to query "previous activation failed" _while_ the unit is activating.)
            "${s}cj" = "journalctl${user} -b -f -n 20 -u";

        }) { s = ""; u = " --user"; });

        programs.bash.blesh.enable = true;
        environment.interactiveShellInit = ''
            if command -v ble-bind &>/dev/null ; then
                ble-bind -f 'C-RET' 'accept-line' ; ble-bind -f 'S-RET' 'newline' # Shift+Enter -> new line ; Ctrl+Enter -> submit (this requires the terminal to send escape sequences for those key combinations)
            fi

            ${builtins.concatStringsSep "\n" (
                lib.mapAttrsToList (k: v: if v == null then "" else "function ${k} {\n${v}\n}") cfg.functions
            )}
        '';
        /* programs.bash.promptInit = lib.mkAfter ''
            if command -v ble-bind &>/dev/null ; then
                function wip/cmd_timer/preexec {
                    _wip_cmd_timer_start=$( date +%s%3N )
                }
                ble/array#push preexec_functions wip/cmd_timer/preexec
            fi
        ''; */ # TODO: use that below ...

    }) ({

        programs.bash.promptInit = let
            red = "91"; green = "92";
            PS1 = user: host: ''\[\e[0m\]\[\e[48;5;234m\]\[\e[$( e=$? ; [[ $e == 0 ]] && printf 96 || printf 91 ; exit $e )m\]$( printf "%3d" $? ) \[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[${user}m\]\u\[\e[97m\]@\[\e[${host}m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'';
        in ''
            # Provide a nice prompt if the terminal supports it.
            if [ "''${TERM:-}" != "dumb" ] ; then
                if [[ "$UID" == '0' ]] ; then if [[ ! "''${SUDO_USER:-}" ]] ; then # direct root: red username + green hostname
                    PS1='${PS1 red green}'
                else # sudo root: red username + red hostname
                    PS1='${PS1 red red}'
                fi ; else # other user: green username + green hostname
                    PS1='${PS1 green green}'
                fi
                if test "$TERM" = "xterm" ; then
                    PS1="\[\033]2;\h:\u:\w\007\]$PS1"
                fi
            fi
            if [[ $( realpath "$BASH" ) != *-interactive-* ]] ; then # The non-interactive version of bash does not remove »\[« and »\]« from $PS1 (but without those the terminal gets confused about the cursor position after the prompt once one types more than a bit of text there (at least via serial or SSH)).
                PS1=''${PS1//\\[/} ; PS1=''${PS1//\\]/}
            fi
            export TERM_RECURSION_DEPTH=$(( 1 + ''${TERM_RECURSION_DEPTH:-0} ))
        '';

        environment.interactiveShellInit = lib.mkBefore ''
            # In REPL mode: remove duplicates from history; don't save commands with a leading space.
            HISTCONTROL=ignoredups:ignorespace

            # For shells bound to serial interfaces (which can't detect the size of the screen on the other end), default to a more reasonable screen size than 24x80 blocks/chars:
            if [[ "$(realpath /dev/stdin)" != /dev/tty[1-8] && $LINES == 24 && $COLUMNS == 80 ]] ; then
                stty rows 34 cols 145 # Fairly large font on 1080p. (Setting this too large for the screen warps the output really badly.)
            fi
        '';
    }) ({ # other »interactiveShellInit« (and »shellAliases«) would go in here, being able to overwrite stuff from above, but still also being included in the alias completion below
        environment.interactiveShellInit = lib.mkAfter ''
            # enable completion for aliases
            source ${ pkgs.fetchFromGitHub {
                owner = "cykerway"; repo = "complete-alias";
                rev = "4fcd018faa9413e60ee4ec9f48ebeac933c8c372"; # v1.18 (2021-07-17)
                sha256 = "sha256-fZisrhdu049rCQ5Q90sFWFo8GS/PRgS29B1eG8dqlaI=";
            } }/complete_alias
            complete -F _complete_alias "''${!BASH_ALIASES[@]}"
        '';

    }) ]);

}
