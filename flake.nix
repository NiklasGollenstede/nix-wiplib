{ description = (
    "Work In Progress: a collection of Nix things that are used in more than one project, but aren't refined enough to be standalone libraries/modules/... (yet)."
    # This flake file defines the inputs (other than except some files/archives fetched by hardcoded hash) and exports all results produced by this repository.
    # It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-24.05"; };
    nixos-hardware = { url = "github:NixOS/nixos-hardware/master"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    installer = { url = "github:NiklasGollenstede/nixos-installer"; inputs.nixpkgs.follows = "nixpkgs"; inputs.functions.follows = "functions"; };
    agenix = { url = "github:ryantm/agenix"; inputs.nixpkgs.follows = "nixpkgs"; inputs.home-manager.follows = "nixpkgs"; inputs.darwin.follows = "nixpkgs"; };
    systems.url = "github:nix-systems/default";
    config.url = "github:NiklasGollenstede/nix-wiplib?dir=example/defaultConfig"; # "path:./example/defaultConfig"; # (The latter only works on each host after using this flake directly (not as dependency or another flake). The former effectively points to the last commit, i.e. it takes two commits to apply changes to the default config.)

}; outputs = inputs@{ self, ... }: inputs.functions.lib.importRepo inputs ./. (repo@{ overlays, ... }: let
    lib = repo.lib.__internal__;
in [ # Run »nix flake show« to see what this merges to:


    ## Exports

    repo # lib.* nixosModules.* overlays.* (legacy)packages.*.* patches.*
    { templates.default = { path = "${self}/example/template"; description = "NixOS host(s) configuration"; }; }


    ## Examples:

    (lib.inst.mkSystemsFlake { inherit inputs; hosts.dir = "${self}/example/hosts"; asDefaultPackage = true; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems/.default

    (lib.wip.mkSecretsApp {
        inherit inputs; secretsDir = "example/secrets";
        adminPubKeys = { "${builtins.readFile ./example/ssh-dummy-key.pub}" = ".*"; };
        getPrivateKeyPath = pkgs: "echo ${self}/example/ssh-dummy-key"; # Don't try this at home!
    })

    (lib.fun.forEachSystem (import inputs.systems) (localSystem: let
        pkgs = lib.fun.importPkgs inputs { system = localSystem; };
    in { packages.builder-shell = (lib.wip.vps-worker {
        inherit pkgs inputs; name = "builder"; serverType = lib.wip.vps-worker.serverTypes.cax11;
        debug = true; ignoreKill = true;
    }).shell; }))

]); }
