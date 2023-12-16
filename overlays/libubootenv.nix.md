/*

# `libubootenv` - Library to access U-Boot environment

This provides the `fw_printenv` / `fw_setenv` commands to work with U-Boot's environment variables.


## Example

Assuming `/dev/disk/by-partlabel/uboot-env` is placed at the same location that U-Boot was configured (via `CONFIG_ENV_OFFSET` and `CONFIG_ENV_SIZE`) to expect/save the environment:
```nix
let toHex = num: lib.concatMapStrings toString (lib.toBaseDigits 16 num); in {
    environment.systemPackages = [ pkgs.libubootenv ];
    environment.etc."fw_env.config".text = "/dev/disk/by-partlabel/uboot-env 0x0 0x${toHex CONFIG_ENV_SIZE}";
}
```


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; lib = inputs.self.lib.__internal__;
in {

    libubootenv = pkgs.stdenv.mkDerivation rec {
        pname = "libubootenv"; version = "0.3.5";

        src = pkgs.fetchFromGitHub {
            owner = "sbabic"; repo = pname; rev = "3f4d15e36ceb58085b08dd13f3f2788e9299877b"; # 2023-10-08
            hash = "sha256-i7gUb1A6FTOBCpympQpndhOG9pCDA4P0iH7ZNBqo+PA=";
        };
        nativeBuildInputs = [ pkgs.buildPackages.cmake ];
        buildInputs = [ pkgs.libyaml pkgs.zlib ];
        outputs = [ "out" "lib" ];

        meta = {
            homepage = "https://github.com/sbabic/libubootenv";
            description = "Generic library and tools to access and modify U-Boot environment from User Space";
            license = [ lib.licenses.lgpl21Plus lib.licenses.mit lib.licenses.cc0 ];
            maintainers = [ ];
            platforms = lib.platforms.linux;
        };
    };
}
