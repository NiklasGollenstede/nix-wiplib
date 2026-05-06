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

    libubootenv = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "libubootenv"; version = "0.3.5";

        src = pkgs.fetchFromGitHub {
            owner = "sbabic"; repo = finalAttrs.pname; rev = "1e3511ed77f794ee5decc0974d54c8e5af26f64c"; # 2025-12-04
            hash = "sha256-cwF9zIYv+/ifrYMRJWTbLf+yrsTa2tT0Rrvx850FS/c=";
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
    });
}
