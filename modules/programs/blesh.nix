dirname: inputs: { config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.programs.blesh;
in {

    options.${prefix} = { programs.blesh = {
        enable = lib.mkEnableOption "enable the bash line editor (ble.sh)";
        condition = lib.mkOption {
            description = "Run-time (bash code) condition for enabling blesh. All enabled conditions must be true.";
            type = lib.fun.types.attrsOfSubmodules {
                modules = { name, config, options, ... }: { options = {
                    enable = lib.mkEnableOption "this condition" // { default = true; example = false; };
                    command = lib.mkOption { type = lib.types.str; description = "The bash (simple or compound) command to evaluate for this condition"; };
                }; };
                coerce = { from = lib.types.str; by = str: { command = str; }; };
            };
        };
        init = lib.mkOption {
            description = "Shell commands to run after belsh is loaded, but before it is attached. These run inside a function, so they can create `local`s or `return false` to prevent attaching.";
            type = lib.types.lines; example = ''
                bleopt input_encoding=UTF-8
                blehook ADDHISTORY=some/function/in/config.programs.bash.interactiveShellInit
                ble-bind -f 'C-RET' 'accept-line'
            '';
        };
    }; };


    config = lib.mkIf cfg.enable {

        ${prefix} = {
            programs.blesh.condition = let
                require-owned-dir = dir: ''{ if ! [[ -d "${dir}" && -r "${dir}" && -w "${dir}" && -x "${dir}" ]] ; then echo 'Missing (permissions on) ${dir}, disabling ble.sh'>&2 ; false ; fi ; }''; # ble.sh has really poor fallback logic
            in {
                is-interactive = "[[ $- == *i* ]]"; # officially recommended way to check for an interactive shell
                not-disabled = "! [[ \${BLE_DISABLED:-} == 1 ]]"; # provide a clean way to disable blesh for specific environments
                has-cache-dir = require-owned-dir "\${XDG_CACHE_HOME:-$HOME/.cache}";
                has-state-dir = require-owned-dir "\${XDG_STATE_HOME:-$HOME/.local/state}";
            };
        };

        # mkAfter to allow definitions of helpers first
        programs.bash.interactiveShellInit = lib.mkAfter ''
            if { ${builtins.concatStringsSep " && " (
                lib.mapAttrsToList (_: { enable, command, ... }: if enable then lib.removeSuffix "\n" command else "") cfg.condition
            )} ; } ; then
                source ${pkgs.blesh}/share/blesh/ble.sh --attach=none
                if [[ ''${BLE_VERSION:-} ]] ; then
                    function __ble__init__ {
                        ${cfg.init}
                    }
                    if __ble__init__ ; then
                        unset -f __ble__init__
                        [[ ! ''${BLE_VERSION:-} ]] || ble-attach
                    fi
                fi
            fi
        '';

        systemd.tmpfiles.rules = [ # blesh fails if these do not exist
            (lib.fun.mkTmpfile { type = "d"; path = "/root/.cache"; })
            (lib.fun.mkTmpfile { type = "d"; path = "/root/.local/state"; })
        ];

    };

}
