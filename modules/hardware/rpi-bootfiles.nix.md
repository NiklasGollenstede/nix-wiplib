/*

# Bootfiles for Raspberry PIs

These are presets of files required on the boot partition to boot Raspberry PIs. Besides the low-level firmware files, this installs u-boot, in the expectation that `boot.loader.generic-extlinux-compatible` is used to provide it with the necessary config to resume booting into NixOS.

This also serves as a demo for the `extra-files` module.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.boot.loader.extra-files;
in {

    options = { boot.loader.extra-files = {
        presets.raspberryPi = {
            bcm2710 = lib.mkEnableOption "boot files for the Raspberry PI 3A+(?), 3B, 3B+, CM3, Zero2(/W)"; # 2B(rev2)
            bcm2711 = lib.mkEnableOption "boot files for the Raspberry PI 400, 4B, CM4, CM4S";
            bcm2712 = lib.mkEnableOption "boot files for the Raspberry PI 5B";
        };

    }; };

    config = {

        boot.loader.extra-files.files = let
            dt = files: lib.genAttrs files (file: { source = "${config.hardware.deviceTree.package}/broadcom/${file}"; }); # From the Kernel build. Only used by u-boot, which then provides Linux with the device tree as specified in the generation's bootloader entry(?).
            fw = files: lib.genAttrs files (file: { source = "${pkgs.raspberrypifw}/share/raspberrypi/boot/${file}"; });
            enabled = cfg.presets.raspberryPi;
        in lib.mkMerge [
            (lib.mkIf (enabled.bcm2710 || enabled.bcm2711 || enabled.bcm2712) {
                "config.txt".format = lib.generators.toINI { listsAsDuplicateKeys = true; };
                "config.txt".text = lib.mkOrder 100 ''
                    # Generated file. Do not edit.
                '';
                "config.txt".data.all = {
                    arm_64bit = 1; # Boot in 64-bit mode (implicit for rPI5).
                    enable_uart = 1; # U-Boot needs this to work, regardless of whether UART is actually used or not.  Look in arch/arm/mach-bcm283x/Kconfig in the U-Boot tree to see if this is still a requirement in the future.
                    avoid_warnings = 1; # Prevent the firmware from smashing the frame buffer setup done by the mainline kernel when attempting to show low-voltage or over temperature warnings.
                };
            })
            (lib.mkIf (enabled.bcm2710) ({ # Boots at least into the kernel.
                "config.txt".data = {
                    pi3.kernel = "u-boot-rpi3.bin";
                    pi02.kernel = "u-boot-rpi3.bin"; # (Zero2?)
                };
                "u-boot-rpi3.bin".source = "${pkgs.ubootRaspberryPi3_64bit}/u-boot.bin";
            } // (fw [
                "bootcode.bin" "start.elf" "fixup.dat"
            ]) // (fw [ # dt
                "bcm2710-rpi-zero-2.dtb" "bcm2710-rpi-zero-2-w.dtb" "bcm2710-rpi-3-b.dtb" "bcm2710-rpi-3-b-plus.dtb" "bcm2710-rpi-cm3.dtb"
                #"bcm2710-rpi-2-b.dtb" # other config different
            ])))
            (lib.mkIf (enabled.bcm2711) ({ # Boots into user space.
                "config.txt".data.pi4 = {
                    kernel = "u-boot-rpi4.bin";
                    enable_gic = 1; # (rPI4 only, default)
                    armstub = "armstub8-gic.bin"; # (also works w/o this)
                    disable_overscan = 1; # Otherwise the resolution will be weird in most cases, compared to what the pi3 firmware does by default.
                    arm_boost = 1; # Supported in newer board revisions
                };
                "u-boot-rpi4.bin".source = "${pkgs.ubootRaspberryPi4_64bit}/u-boot.bin";
                "armstub8-gic.bin".source = "${pkgs.raspberrypi-armstubs}/armstub8-gic.bin";
            } // (fw [
                "start4.elf" "fixup4.dat"
            ]) // (fw [ # dt
                "bcm2711-rpi-cm4s.dtb" "bcm2711-rpi-400.dtb" "bcm2711-rpi-4-b.dtb" "bcm2711-rpi-cm4.dtb" "bcm2711-rpi-cm4-io.dtb"
            ])))
            (lib.mkIf (enabled.bcm2712) ({ # Boots into u-boot.
                "config.txt".data.pi5 = {
                    kernel = "u-boot-rpi5.bin";
                };
                "u-boot-rpi5.bin".source = "${pkgs.buildUBoot rec { # This boots into u-boot (showing the u-boot logo on screen), but gets stuck
                    defconfig = "rpi_arm64_defconfig"; # u-boot does not have a rpi_5_defconfig yet (as of 2024-07)
                    extraMeta.platforms = [ "aarch64-linux" ];
                    filesToInstall = [ "u-boot.bin" ];
                    version = "2024.07"; src = pkgs.fetchurl {
                        url = "https://ftp.denx.de/pub/u-boot/u-boot-${version}.tar.bz2";
                        hash = "sha256-9ZHamrkO89az0XN2bQ3f+QxO1zMGgIl0hhF985DYPI8=";
                    };
                }}/u-boot.bin";
                #"armstub8-2712.bin".source = ...; # This is the default value for armstub=, but it does not seem necessary to put anything there.
            } // (fw [
                # no start*.elf (and fixup*.dat) for the rPI5
            ]) // (fw [ # dt
                "bcm2712-rpi-5-b.dtb"
            ])))
        ];

    };
}
