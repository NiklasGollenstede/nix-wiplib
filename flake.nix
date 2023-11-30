{ description = (
    "Work In Progress: a collection of Nix things that are used in more than one project, but aren't refined enough to be standalone libraries/modules/... (yet)."
    # This flake file defines the inputs (other than except some files/archives fetched by hardcoded hash) and exports all results produced by this repository.
    # It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-23.11"; };
    nixos-hardware = { url = "github:NixOS/nixos-hardware/master"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    installer = { url = "github:NiklasGollenstede/nixos-installer"; inputs.nixpkgs.follows = "nixpkgs"; inputs.functions.follows = "functions"; };
    systems.url = "github:nix-systems/default-linux";
    config.url = "path:./example/defaultConfig";

}; outputs = inputs@{ self, ... }: inputs.functions.lib.importRepo inputs ./. (repo@{ overlays, ... }: let
    lib = repo.lib.__internal__;
in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo # lib.* nixosModules.* overlays.*

    (lib.inst.mkSystemsFlake { inherit inputs; asDefaultPackage = true; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems
    { templates.default = { path = "${self}/example/template"; description = "NixOS host(s) configuration"; }; }

    (lib.fun.forEachSystem (import inputs.systems) (localSystem: let
        pkgs = lib.fun.importPkgs inputs { system = localSystem; };
    in { packages.builder-shell = (lib.wip.vps-worker rec {
        inherit pkgs inputs; name = "builder"; serverType = lib.wip.vps-worker.serverTypes.cax11;
        debug = true; ignoreKill = true;
    }).shell; }))
]); }
