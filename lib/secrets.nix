dirname: inputs: let
    lib = inputs.self.lib.__internal__;
    inherit (import "${dirname}/misc.nix" dirname inputs) listDirRecursive;
    flakeInputs = inputs;
in {

    # Merged into a flakes outputs, the return value of this function defines an app "secrets" (by default) that can en-/re-/decrypt age secret files.
    # Those secret files can be used with the `agenix` module directly, or via the `secrets` module that wraps the former.
    # Compared to pure `agenix`, this wrapper removes the need to list all secret files (with the identities (host/users/admins) that need to decrypt them) in a central (non-flake) `secrets.nix` file. Instead, all hosts (and admins) specify which of the existing files they need by path via (simple) regular expressions.
    # The `secrets` module can use the same expressions to load those secrets into the system configuration.
    # This significantly reduces overhead and information-duplication of/in the secrets management, at the cost of making each individual CLI call slow (depending on the number of hosts in the flake).
    mkSecretsApp = {
        inputs, # `{ self?, nixpkgs, agenix?, systems?, }`: The top-level flake's `inputs` (as passed to the `outputs` function). Needs to contain at least `nixpkgs`. The `overlays.default` from all other (direct) inputs are added to `pkgs` (so `agenix` should be present; if it is not, it will be filled from this flake's inputs) and `systems` (if present) should be one of <https://github.com/nix-systems>. `self` is used in some of the defaults for other arguments.
        adminPubKeys, # `{ "ssh-ed25519 ..." = ".*" | ("secrets/<...>.age": true|false); }`: Mapping of admins' public (SSH/age) keys to secrets they can decrypt, as a regular expression or a predicate. Either is used as a filter of the paths of all `.age` files in `$secretsDir`.
        getPrivateKeyPath ? pkgs: ''echo "$HOME/.ssh/id_ed25519"'', # A bash script snippet that returns the path to the private key file/identity used to decrypt secrets (explicitly or when editing/rekeying existing secrets). Its public key should be in `adminPubKeys`.
        hostNeedsSecret ? hostName: { config, ... }: if config.wip.services.secrets.include == [ ] then path: false else lib.concatStringsSep "|" config.wip.services.secrets.include, # `...: ( "wg/.*@${hostName}|ssh/service/.*@${hostName}" | ("secrets/<...>.age": true|false) )`: Function of host to the secrets it can decrypt. The function arguments are the same as for `getHostPubKey`, and the matching logic is the same as for the values of `adminPubKeys`.
        getHostPubKey ? hostName: { config, ... }: let path = "${inputs.self.outPath}/${secretsDir}/ssh/host/host@${hostName}.pub"; in if builtins.pathExists path then builtins.readFile path else null, # `...: "ssh-ed25519 ..."|null`: Function mapping hosts to their decryption key's public identity. The arguments are an attribute name and corresponding value of `hosts`.
        hosts ? inputs.self.nixosConfigurations, # Attribute set of NixOS configurations that need to access secrets.
        repoRoot ? inputs.self.outPath, # Path to the root of the flake/repository.
        secretsDir ? "secrets", # Relative path of the dir in `repoRoot` where secrets are stored.
        appName ? "secrets", # Name of the exported app (`nix run .#$appName -- ...`).
    }: let

        ageFiles = builtins.filter (lib.hasSuffix ".age") (if builtins.pathExists "${repoRoot}/${secretsDir}" then listDirRecursive "${repoRoot}" "${secretsDir}" else [ ]);
        hostInclusions = builtins.mapAttrs hostNeedsSecret hosts;
        matching = file: inclusions: builtins.attrNames (lib.filterAttrs (_: exp: if builtins.isFunction exp then exp file else (builtins.match "(${secretsDir}/)?(${exp})(.age)?" file) != null) inclusions);
        secrets = lib.genAttrs ageFiles (file: { publicKeys = (lib.remove null (map (name: getHostPubKey name hosts.${name}) (matching file hostInclusions))) ++ (matching file adminPubKeys); });

    in { apps = lib.fun.exportFromPkgs { inputs = { inherit (flakeInputs) nixpkgs agenix; } // inputs; what = pkgs: {
        ${appName} = lib.fun.writeTextFiles pkgs "agenix-wrapped" {
            executable = "bin/*"; checkPhase = ''${pkgs.stdenv.shellDryRun} bin/*'';
            meta.mainProgram = appName;
        } {
            "bin/${appName}" = ''
                #!${pkgs.runtimeShell}
                set -o pipefail -u
                identity=$( ${getPrivateKeyPath pkgs} ) || exit
                export RULES=${placeholder "out"}/share/secrets-spec.nix ; agenix=( ${/* lib.getExe */ pkgs.agenix}/bin/agenix ''${identity:+--identity "$identity"} )

                if [[ $identity && ''${1:-} && ''${2:-} ]] ; then
                    genSSH= ; if [[ $1 == -s || $1 == --genkey-ssh ]] ; then genSSH=1 ; fi
                    genTLS= ; if [[ $1 == -t || $1 == --genkey-tls ]] ; then genTLS=1 ; fi
                    genWG= ; if [[ $1 == -w || $1 == --genkey-wg ]] ; then genWG=1 ; fi
                    genMP= ; if [[ $1 == -m || $1 == --genkey-mkpasswd ]] ; then genMP=1 ; fi
                    genRNG= ; if [[ $1 == -R || $1 == --genkey-random ]] ; then genRNG=1 ; fi
                    edit= ; if [[ $1 == -e || $1 == --edit || $genSSH || $genTLS || $genWG || $genMP || $genRNG ]] ; then edit=true ; fi
                    if [[ $2 != ${secretsDir}/* ]] ; then set -- "$1" ${secretsDir}/"$2" "''${@:3}" ; fi
                    if [[ $2 != *.age ]] ; then set -- "$1" "$2".age "''${@:3}" ; fi

                    if [[ $edit && ! -s $2 ]] ; then
                        existed= ; if [[ -e $2 ]] ; then existed=1 ; else mkdir -p "$( dirname "$2" )" ; fi
                        : | ${lib.getExe pkgs.age} --recipient "$( ${pkgs.openssh}/bin/ssh-keygen -y -f "$identity" )" -o "$2" || exit # --recipients-file "$identity".pub
                        if [[ ! $existed ]] ; then git update-index --add "$2" ; exec nix run .#${appName} -- "$@" ; fi # re-eval with new file
                    fi

                    if [[ $genSSH || $genTLS || $genWG || $genMP || $genRNG ]] ; then
                        set -- --edit "''${@:2}"
                        pubExisted= ; if [[ -e ''${2%.age}.pub ]] ; then pubExisted=1 ; fi
                        if [[ $genSSH ]] ; then
                            ${pkgs.openssh}/bin/ssh-keygen -q -N "" -t ed25519 -f "''${2%.age}" -C "" || exit
                            private=$( cat "''${2%.age}" ) && rm -f "''${2%.age}" || exit
                        elif [[ $genTLS ]] ; then
                            keyOpts=( -algorithm ED25519 ) ; keyOpts=( -algorithm RSA -pkeyopt rsa_keygen_bits:2048 )
                            private=$( ${lib.getExe pkgs.openssl} genpkey "''${keyOpts[@]}" -out - ) || exit
                            read -p "For a self-signed CA with a signed server certificate, enter the certs hostname. If empty, an unnamed (client) certificate will be created: " hostname
                            ext=ca ; [[ $hostname ]] || ext=crt
                            ${lib.getExe pkgs.openssl} req -new -x509 -days 36500 -subj "/CN=-" -key /dev/stdin <<<"$private" -out ''${2%.age}.$ext || exit
                            if [[ $hostname ]] ; then
                                ${lib.getExe pkgs.openssl} req -new -subj "/CN=$hostname" -key /dev/stdin <<<"$private" |
                                ${lib.getExe pkgs.openssl} x509 -req -CA ''${2%.age}.ca -CAkey <( cat <<<"$private" ) -set_serial 01 -out ''${2%.age}.crt -days 36500
                            fi
                        elif [[ $genWG ]] ; then
                            private=$( ${pkgs.wireguard-tools}/bin/wg genkey ) || exit
                            ${pkgs.wireguard-tools}/bin/wg pubkey <<<"$private" >''${2%.age}.pub || exit
                        elif [[ $genMP ]] ; then
                            private=$( ${lib.getExe pkgs.mkpasswd} -m sha-512 ) || exit
                        elif [[ $genRNG ]] ; then
                            private=$( ${lib.getExe pkgs.openssl} rand -base64 32 ) || exit
                            printf "Generated Password: %s\n" "$private"
                        else exit 1 ; fi
                        git update-index --add ''${2%.age}.*
                        <<<"$private" "''${agenix[@]}" "$@" || exit
                    exit ; fi
                fi
                "''${agenix[@]}" "$@" || exit
            '';
            "share/secrets-spec.nix" = ''
                builtins.fromJSON (builtins.readFile "${placeholder "out"}/share/secrets-spec.json")
            '';
            "share/secrets-spec.json" = builtins.toJSON secrets;
        };
    }; asApps = true; }; };

    # Usable as »mkSecretsApp«'s »getPrivateKeyPath« argument, this generates a admin private (and public) key from a seed that results from a fixed challenge to a YubiKey's HMAC function.
    # The key pair can thus be re-generated with the same YubiKey (or the same HMAC secret), effectively making the YubiKey ('s HMAC secret) the actual key, and the generated key pair only a cache of the (derived) key.
    # The default location of the cached key (»keyPath«) is in »/run/user/« and thus clears the cache on reboot or logout.
    getPrivateKeyFromYubikeyChallenge = { challenge, slot ? "2", keyPath ? ''/run/user/"$UID"/"$challenge".key'', }: (pkgs: ''
        challenge=${challenge} ; slot=${slot} ; keyPath=${keyPath} # not escaped on purpose, to allow for evil wizardry
        if [[ ! -e $keyPath ]] ; then
            echo 'Generating private get by challenging YubiKey (slot '"$slot"') with "'"$challenge"'"' >&2
            seed=$( ${pkgs.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge" ) || exit
            <<<"$seed" ${pkgs.coreutils}/bin/sha256sum - | ${pkgs.coreutils}/bin/head -c 64 | ${lib.getExe pkgs.melt-raw} restore "$keyPath" >&2 || exit
            echo 'Public key: '"$( cat "$keyPath".pub )" >&2
        fi ; echo "$keyPath"
    '');

}
