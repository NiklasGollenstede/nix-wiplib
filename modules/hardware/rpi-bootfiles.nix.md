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
                    enable_uart = 1; # U-Boot needs this to work, regardless of whether UART is actually used or not. Look in arch/arm/mach-bcm283x/Kconfig in the U-Boot tree to see if this is still a requirement in the future.
                    avoid_warnings = 1; # Prevent the firmware from smashing the frame buffer setup done by the mainline kernel when attempting to show low-voltage or over temperature warnings.
                    kernel = "u-boot-aarch64.bin"; # Works for all 64-bit rPIs (except that (non-SD) boot is broken on rPI5).
                };
                #"u-boot-aarch64.bin".source = "${pkgs.ubootRaspberryPiAarch64}/u-boot.bin";
                "u-boot-aarch64.bin".source = "${(pkgs.buildUBoot rec { # none of this actually works:
                    # https://lists.u-boot-project.org/pipermail/u-boot/2025-May/589080.html
                    defconfig = "rpi_arm64_defconfig";
                    extraMeta.platforms = [ "aarch64-linux" ];
                    filesToInstall = [ "u-boot.bin" ];
                    #version = "2026.07-rc3"; src = pkgs.fetchurl {
                    #    # TODO: does that include this?: https://lists.u-boot-project.org/pipermail/u-boot/2026-July/624063.html
                    #    url = "https://ftp.denx.de/pub/u-boot/u-boot-${version}.tar.bz2";
                    #    hash = "sha256-eOi/w4L+OI+bVaodr4xWNSKgN3ebXUw0nRQV44HxJD4=";
                    #};
                    #version = "2026.07-rc3-nvme-389363d2"; src = pkgs.fetchurl {
                    #    url = "https://git.u-boot-project.org/u-boot/custodians/neil.armstrong/u-boot-nvme/-/archive/389363d287585d8135a554c4419a4f580346b9f8/u-boot-nvme-389363d287585d8135a554c4419a4f580346b9f8.tar.bz2";
                    #    hash = "sha256-MmPhDzfuUda1jfUWHoBCSyyuaf3x43xBl8nXCktCAzc=";
                    #};
                    version = "2026.10-rc1-a12ec6cb"; src = pkgs.fetchurl {
                        url = "https://git.u-boot-project.org/u-boot/custodians/u-boot-raspberrypi/-/archive/a12ec6cbc4e169bafb1d4a3f5ce1962f01131b09/u-boot-raspberrypi-a12ec6cbc4e169bafb1d4a3f5ce1962f01131b09.tar.bz2";
                        hash = "sha256-Eh2d5u+5KQZawVUhmdIDbhYrXNj6t018c7MzDzB6++A=";
                    };
                })/* .overrideAttrs (attrs: {
                    postPatch = (attrs.postPatch or "") + ''
                        if [ ! -f configs/rpi_5_defconfig ]; then
                            echo ${lib.escapeShellArg ''
                                #include <configs/rpi_arm64_defconfig>
                                CONFIG_DEFAULT_DEVICE_TREE="broadcom/bcm2712-rpi-5-b"
                                CONFIG_OF_UPSTREAM=y
                                CONFIG_LOGLEVEL=8
                                CONFIG_VERBOSE_BOOT=y
                            ''} >configs/rpi_5_defconfig
                            echo '/ { };' >arch/arm/dts/bcm2712-rpi-5-b-u-boot.dtsi
                        fi
                    ''; # The LOGLEVEL and VERBOSE_BOOT stuff seems to have no effect. Still see only the logo.
                }) */}/u-boot.bin";
            })
            (lib.mkIf (enabled.bcm2710) ({ # Boots at least into the kernel.
            } // (fw [
                "bootcode.bin" "start.elf" "fixup.dat"
            ]) // (fw [ # dt
                "bcm2710-rpi-zero-2.dtb" "bcm2710-rpi-zero-2-w.dtb" "bcm2710-rpi-3-b.dtb" "bcm2710-rpi-3-b-plus.dtb" "bcm2710-rpi-cm3.dtb"
                #"bcm2710-rpi-2-b.dtb" # other config different
            ])))
            (lib.mkIf (enabled.bcm2711) ({ # Boots into user space.
                "config.txt".data.pi4 = {
                    enable_gic = 1; # (rPI4 only, default)
                    armstub = "armstub8-gic.bin"; # (also works w/o this)
                    disable_overscan = 1; # Otherwise the resolution will be weird in most cases, compared to what the pi3 firmware does by default.
                    arm_boost = 1; # Supported in newer board revisions
                };
                "armstub8-gic.bin".source = "${pkgs.raspberrypi-armstubs}/armstub8-gic.bin";
            } // (fw [
                "start4.elf" "fixup4.dat"
            ]) // (fw [ # dt
                "bcm2711-rpi-cm4s.dtb" "bcm2711-rpi-400.dtb" "bcm2711-rpi-4-b.dtb" "bcm2711-rpi-cm4.dtb" "bcm2711-rpi-cm4-io.dtb"
            ])))
            (lib.mkIf (enabled.bcm2712) ({ # Boots into u-boot, then gets stuck displaying that logo.
                "config.txt".data.pi5 = {
                    usb_max_current_enable = 1;
                    enable_uart = 0; # On some revisions of the RPi5, U-Boot interprets picks up ghost inputs from the uart, interrupting the boot process: https://bugzilla.opensuse.org/show_bug.cgi?id=1251192
                };
                #"armstub8-2712.bin".source = ...; # This is the default value for armstub=, but it does not seem necessary to put anything there.
            } // (fw [
                # no start*.elf (and fixup*.dat) for the rPI5
            ]) // (fw [ # dt
                "bcm2712-d-rpi-5-b.dtb" "bcm2712-rpi-5-b.dtb" "bcm2712-rpi-500.dtb" "bcm2712-rpi-cm5-cm4io.dtb" "bcm2712-rpi-cm5-cm5io.dtb" "bcm2712-rpi-cm5l-cm4io.dtb" "bcm2712-rpi-cm5l-cm5io.dtb"
            ])))
        ];

    };
}
