dirname: inputs: let
    lib = inputs.self.lib.__internal__;
    prefix = inputs.config.prefix;
in rec {

    # Given a flake input (attribute passed to ta flakes `outputs` function), this returns a flake reference (thing that can be passed to lockfiles' `locked` or registries' `to` attributes) to the flake.
    # Specifically, this fixes the reference to flakes that are not in the root of their repository (and thus have the `flake.nix` file in a subdirectory in the nix store).
    toFlakeRef = input: (lib.filterAttrs (n: _: n == "lastModified" || n == "narHash" || n == "rev" || n == "revCount") input) // (let
        match = builtins.match ''(${builtins.storeDir}/.*)/(.*)'' input.outPath;
    in if match != null then {
        type = "git"; url = "file://${builtins.elemAt match 0}"; dir = builtins.elemAt match 1;
    } else {
        type = "path"; path = input.outPath;
    });

    # Given a `base` directory path and a relative `dir`ectory path therein, this returns a sorted list of the relative paths of all (non-directory) files recursively in `dir`.
    # The `base` path part is only used to find the directory, whereas `dir` becomes a prefix of all listed paths.
    listDirRecursive = base: dir: builtins.concatLists (lib.mapAttrsToList (name: type: let joined = if dir == "" then name else "${dir}/${name}"; in if type == "directory" then listDirRecursive base joined else [ joined ]) (builtins.readDir "${base}/${dir}"));

    mkKexec = {
        name ? "kexec", config, inputs ? null, mkHosts ? inputs.self.mkHosts or lib.inst.mkSystemsFlake { },
    }: let system = (mkHosts {
        hosts.configs.${name} = { imports = [ config ]; config.${prefix}.hardware.kexec.enable = true; };
    }).nixosConfigurations.${name}; in system // { inherit (system.config.system.build) kexecRun kexecTarball kernel netbootRamdisk; };

}
