{ description = (
    "TODO"
    # This flake file defines the inputs (other than files/archives fetched by hardcoded hash) and exports all results produced by this repository.
    # It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-26.05"; };
    nixos-hardware = { url = "github:NixOS/nixos-hardware/master"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    installer = { url = "github:NiklasGollenstede/nixos-installer"; inputs.nixpkgs.follows = "nixpkgs"; inputs.functions.follows = "functions"; };
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; inputs.nixpkgs.follows = "nixpkgs"; inputs.nixos-hardware.follows = "nixos-hardware"; inputs.installer.follows = "installer"; inputs.functions.follows = "functions"; inputs.systems.follows = "systems"; };
    blinders = { url = "github:NiklasGollenstede/blinders"; inputs.nixpkgs.follows = "nixpkgs"; inputs.installer.follows = "installer"; inputs.functions.follows = "functions"; };
    systems.url = "github:nix-systems/default-linux";

}; outputs = inputs: let patches = {

    nixpkgs = [
		# remote: { url = "https://github.com/NixOS/nixpkgs/pull/###.diff"; sha256 = inputs.nixpkgs.lib.fakeSha256; }
        # import: inputs.foo.patches.nixpkgs.bar
		# local: ./overlays/patches/nixpkgs/bar.patch # (use native (unquoted) path to the file itself, so that the patch has its own nix store path, which only changes if the patch itself changes (and not if any of the other files in ./. change))

        # Add lib.mkApply:
        inputs.wiplib.patches.nixpkgs.mkApply-25-11
    ];

}; in inputs.functions.lib.patchFlakeInputsAndImportRepo inputs patches ./. (inputs: repo: let
    lib = repo.lib.__internal__;
in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo # lib.* nixosModules.* overlays.* (legacy)packages.*.* patches.*

    (lib.inst.mkSystemsFlake { inherit inputs; }) # nixosConfigurations.* apps.*-linux.* packages.*-linux.all-systems

    ## Enable `nix run .#init` to initialize a blinders sandbox matching this repo to be used rapidly from the CLI or editor integration:
    (inputs.blinders.lib.mkBlindersInitApp {
        inherit inputs;
        config = { pkgs, ... }: {
            environment.systemPackages = [ ];
            programs.bash.interactiveShellInit = inputs.nixpkgs.lib.mkAfter ''
            '';
        };
        #devShell = "my-dev-shell";
        args = [ "--read-only-glob=?**/.vscode/" ];
    })

]); }
