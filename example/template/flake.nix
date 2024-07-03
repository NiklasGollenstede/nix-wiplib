{ description = (
    "TOOD"
    # This flake file defines the inputs (other than files/archives fetched by hardcoded hash) and exports all results produced by this repository.
    # It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-24.05"; };
    nixos-hardware = { url = "github:NixOS/nixos-hardware/master"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    installer = { url = "github:NiklasGollenstede/nixos-installer"; inputs.nixpkgs.follows = "nixpkgs"; inputs.functions.follows = "functions"; };
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; inputs.nixpkgs.follows = "nixpkgs"; inputs.nixos-hardware.follows = "nixos-hardware"; inputs.installer.follows = "installer"; inputs.functions.follows = "functions"; inputs.systems.follows = "systems"; };
    systems.url = "github:nix-systems/default-linux";

}; outputs = inputs@{ self, ... }: inputs.functions.lib.importRepo inputs ./. (repo@{ overlays, ... }: let
    lib = repo.lib.__internal__;
in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo # lib.* nixosModules.* overlays.* (legacy)packages.*.* patches.*

    (lib.inst.mkSystemsFlake { inherit inputs; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems
]); }
