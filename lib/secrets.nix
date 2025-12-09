dirname: inputs: let
    lib = inputs.self.lib.__internal__;
    inherit (import "${dirname}/misc.nix" dirname inputs) listDirRecursive;
    wiplibInputs = inputs;
    prefix = inputs.config.prefix;
in {

    # Merged into a flakes outputs, the return value of this function defines an app "secrets" (by default) that can en-/re-/decrypt age secret files.
    # Those secret files can be used with the `agenix` module directly, or via the `${prefix}.services.secrets` module that wraps the former.
    # Compared to pure `agenix`, this wrapper removes the need to list all secret files (with the identities (host/users/admins) that need to decrypt them) in a central (non-flake) `secrets.nix` file. Instead, all hosts (and admins) specify which of the existing files they need by path via (simple) regular expressions.
    # The `secrets` module can use the same expressions to load those secrets into the system configuration.
    # This significantly reduces overhead and information-duplication of/in the secrets management, at the cost of making each individual CLI call slow (depending on the number of hosts in the flake).
    mkSecretsApp = {
        inputs, # `{ self?, nixpkgs, agenix?, systems?, }`: The top-level flake's `inputs` (as passed to the `outputs` function). Needs to contain at least `nixpkgs`. The `overlays.default` from all other (direct) inputs are added to `pkgs` (so `agenix` should be present; if it is not, it will be filled from this flake's inputs) and `systems` (if present) should be one of <https://github.com/nix-systems>. `self` is used in some of the defaults for other arguments.
        adminPubKeys, # `{ "ssh-ed25519 ..." = ".*" | ("secrets/<...>.age": true|false); }`: Mapping of admins' public (SSH/age) keys to secrets they can decrypt, as a regular expression or a predicate. Either is used as a filter of the paths of all `.age` files in `$secretsDir`.
        extraPubKeys ? hostName: { config, ... }: secretsPath: if builtins.isString config.${prefix}.services.secrets.rootKeyEncrypted && secretsPath == "${secretsDir}/${config.${prefix}.services.secrets.rootKeyEncrypted}.age" then config.${prefix}.services.secrets.rootKeyExtraOwners else [ ], # Function that lets each host declare that additional public keys should be used to decrypt certain (any) secrets.
        getPrivateKeyPath ? pkgs: ''echo "$HOME/.ssh/id_ed25519"'', # A bash script snippet that returns the path to the private key file/identity used to decrypt secrets (explicitly or when editing/rekeying existing secrets). Its public key should be in `adminPubKeys`.
        hostNeedsSecret ? hostName: { config, ... }: if config.${prefix}.services.secrets.include == [ ] then path: false else lib.concatStringsSep "|" config.${prefix}.services.secrets.include, # `...: ( "wg/.*@${hostName}|ssh/service/.*@${hostName}" | ("secrets/<...>.age": true|false) )`: Function of host to the secrets it can decrypt. The function arguments are the same as for `getHostPubKey`, and the matching logic is the same as for the values of `adminPubKeys`.
        getHostPubKey ? hostName: { config, ... }: let path = "${inputs.self.outPath}/${secretsDir}/ssh/host/host@${hostName}.pub"; in if builtins.pathExists path then builtins.readFile path else null, # `...: "ssh-ed25519 ..."|null`: Function mapping hosts to their decryption key's public identity. The arguments are an attribute name and corresponding value of `hosts`.
        hosts ? inputs.self.nixosConfigurations, # Attribute set of NixOS configurations that need to access secrets. Note that the attribute names may matter for default key locations (see above).
        repoRoot ? inputs.self.outPath, # Path to the root of the flake/repository.
        secretsDir ? "secrets", # Relative path of the dir in `repoRoot` where secrets are stored.
        appName ? "secrets", # Name of the exported app (`nix run .#$appName -- ...`).
    }: let

        ageFiles = builtins.filter (lib.hasSuffix ".age") (if builtins.pathExists "${repoRoot}/${secretsDir}" then listDirRecursive "${repoRoot}" "${secretsDir}" else [ ]); # [ "${secretsDir}/**.age" ]
        hostInclusions = builtins.mapAttrs hostNeedsSecret hosts;
        getMatchingKeys = file: inclusions: builtins.attrNames (lib.filterAttrs (_: exp: if builtins.isFunction exp then exp file else (builtins.match "(${secretsDir}/)?(${exp})([.]age)?" file) != null) inclusions);
        secrets = lib.genAttrs ageFiles (file: { publicKeys = (lib.remove null (map (name: getHostPubKey name hosts.${name}) (getMatchingKeys file hostInclusions))) ++ (getMatchingKeys file adminPubKeys) ++ (lib.flatten (lib.mapAttrsToList (n: s: extraPubKeys n s file) hosts)); });
        secretsJSON = builtins.toJSON secrets;

    in { apps = lib.fun.exportFromPkgs { inputs = { inherit (wiplibInputs) nixpkgs agenix; } // inputs; what = pkgs: {
        ${appName} = (pkgs.age-of-nix.override (old: {
            context.args = { inherit appName secretsDir secretsJSON; fallbackPrivateKeyPath = getPrivateKeyPath pkgs; };
        })).overrideAttrs (old: { passthru = old.passthru // { inherit secretsJSON; }; });
    }; asApps = true; }; };

    # Usable as »mkSecretsApp«'s »getPrivateKeyPath« argument, this generates a admin private (and public) key from a seed that results from a fixed challenge to a YubiKey's HMAC function.
    # The key pair can thus be re-generated with the same YubiKey (or the same HMAC secret), effectively making the YubiKey ('s HMAC secret) the actual key, and the generated key pair only a cache of the (derived) key.
    # The default location of the cached key (»keyPath«) is in »/run/user/« and thus clears the cache on reboot or logout.
    getPrivateKeyFromYubikeyChallenge = { challenge, slot ? "2", keyPath ? ''/run/user/"$UID"/"$challenge".key'', }: (pkgs: ''
        challenge=${challenge} ; slot=${slot} ; keyPath=${keyPath} # not escaped on purpose, to allow for evil wizardry
        if [[ ! -e $keyPath ]] ; then
            read -p 'No --identity was passed an it is not yet cached (in '"$keyPath"'). Regenerating the private by challenging YubiKey (slot '"$slot"') with "'"$challenge"'". Enter to continue, or Ctrl+C to abort:'
            seed=$( ${pkgs.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge" ) || exit
            <<<"$seed" ${pkgs.coreutils}/bin/sha256sum - | ${pkgs.coreutils}/bin/head -c 64 | ${pkgs.util-linux}/bin/setsid -- ${lib.getExe pkgs.melt-raw} restore "$keyPath" >&2 || exit
            echo 'Public key: '"$( cat "$keyPath".pub )" >&2
        fi ; echo "$keyPath"
    '');

}
