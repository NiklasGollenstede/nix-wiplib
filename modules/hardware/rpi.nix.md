/*

# Raspberry PI 3 / 4 / Zero 2

Device specific config for any 64bit capable Raspberry PI (esp. rPI4 and CM4, but also 3B(+) and Zero 2, maybe others).

To set up a rPI host, connect it's boot medium (USB SSD or microSD card) to some other host, and run [`install-system`](https://github.com/NiklasGollenstede/nixos-installer), directly targeting the future boot medium.


## Notes

* Importing this module also makes the [`hardware.raspberry-pi."4".*`](https://github.com/NixOS/nixos-hardware/blob/master/raspberry-pi/4/) options from [`nixos-hardware`](https://github.com/NixOS/nixos-hardware/) available (but disabled by default).
* All the `boot.loader.raspberryPi.*` stuff (and maybe also `boot.kernelParams`) seems to be effectively disabled if `boot.loader.generic-extlinux-compatible.enable == true`.
  The odd thing is that various online sources, including `nixos-hardware`, enable extlinux (this may simply be because `nixos-generate-config` sets this by default, purely based on the presence of `/boot/extlinux` in the (derived from more generic) default images).
  Without extlinux, u-boot is also disabled, which means that (on an rPI4) there is no way to get a generation selection menu, and generations would need to be restored by moving files in the `/boot` partition manually.
* Installing to the eMMC of a CM4: set the "eMMC Boot" jumper/switch to off/disabled; run `nix-shell -p rpiboot --run 'sudo rpiboot'` on a different host; and connect the CM4 carrier to it via the USB-OTG (microUSB / USB-C) port. Then install to the new block device (`/dev/sdX`) that should pop up on the host.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.hardware.raspberry-pi;
in {

    options.${prefix} = { hardware.raspberry-pi = {
        enable = lib.mkEnableOption "base configuration for Raspberry Pi 64bit hardware";
        i2c = lib.mkEnableOption ''the ARM i²c /dev/i2c-1 on pins 3+5 / GPIO2+3 (/ SDA+SCL). Also see `hardware.raspberry-pi."4".i2c{0,1}.enable`'';
        gpio = lib.mkEnableOption "GPIO access for the »gpio« group via sysfs (legacy) and »/dev/gpiochip*« (e.g. libgpiod's »gpioset«)";
        lightless = lib.mkEnableOption "operation without any activity lights";
    }; };

    ## Import the rPI4 config from nixos-hardware, but have it disabled by default.
    #  This provides some options for additional onboard hardware components as »hardware.raspberry-pi."4".*«, see: https://github.com/NixOS/nixos-hardware/blob/master/raspberry-pi/4/
    imports = let
        path = "${inputs.nixos-hardware}/raspberry-pi/4/default.nix"; module = import path args;
    in [ { _file = path; imports = [ {
        config = lib.mkIf cfg.enable (builtins.removeAttrs module [ "imports" ]);
    } ]; } ] ++ module.imports;

    config = lib.mkIf cfg.enable (lib.mkMerge [ ({ ## Bootloader

        setup.bootpart.enable = true;

        boot.loader.generic-extlinux-compatible.enable = true;
        boot.loader.extra-files.enable = true;
        boot.loader.extra-files.presets.raspberryPi = { bcm2710 = true; bcm2711 = true; };


    }) ({ ## Drivers

        ## Serial console:
        # Different generations of rPIs have different hardware capabilities in terms of UARTs (driver chips and pins they are connected to), and different device trees (and options for them) and boot stages (firmware/bootloader/OS) can initialize them differently.
        # There are three components to a UART port: the driver chip in the CPU, which GPIOs (and through the PCB thereby physical pins) or other interface (bluetooth) they are connected to, and how they are exposed by the running kernel (»/dev/?«).
        # All rPIs so far have at least one (faster, data transfer capable) "fully featured PL011" uart0 chip, and a slower, console only "mini" uart1 chip.
        # In Linux, uart0 usually maps to »/dev/ttyAMA0«, and uart1 to »/dev/ttyS0«. »/dev/serial0«/»1« are symlinks in Raspbian.
        # What interfaces (GPIO/bluetooth) the chips connect to is configured in the device tree. The following should be true for the official/default device trees:
        # When bluetooth is enabled (hardware present and not somehow disabled) then uart0 "physically" connects to that, and uart1 connects to pins 08+10 / GPIO 14+15, otherwise the former connects to those pins and the latter is unused. The uart at GPIO 14+15 is referred to as "primary" in the rPI documentation.
        # If uart1 is primary, then UART is disabled by default, because uart1 only works at a fixed (250MHz) GPU/bus speed. At some performance or energy cost, the speed can be fixed, enabling the UART, by setting »enable_uart=1« (or »core_freq=250« or »force_turbo=1« (i.e. 400?)) in the firmware config.
        # Bottom line, to use UART on GPIO 14+15, one needs to either disable bluetooth / not have it / disconnect uart0 from it and can (only then) use »/dev/ttyAMA0«, or fix the GPU speed and use uart1 (»/dev/ttyS0«).
        # On a rPI4, one could use the additional (fast) uart2/3/4/5. Those need to be enabled via device tree( overlay)s, and will be exposed as »/dev/ttyAMAx«.
        # For example: boot.loader.raspberryPi.firmwareConfig = "enable_uart=1\n"; boot.kernelParams = [ "console=ttyS0,115200" ];
        # TODO: NixOS sets »enable_uart=1« by default. That is probably a bad idea.
        boot.kernelParams = [
            #"8250.nr_uarts=1" # 8250 seems to be the name of a serial port driver kernel module, which has a compiled limit of ports it manages. Setting this can override that. Not sure whether the 8250 module has any relevance for the rPI.

            # (someones claim:) Some gui programs need this
            #"cma=128M" # (Continuous Memory Area?)
        ];

        hardware.enableRedistributableFirmware = true; # for WiFi
        #hardware.firmware = [ pkgs.firmwareLinuxNonfree pkgs.raspberrypiWirelessFirmware ]; # TODO: try with this instead
        powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand"; # (not sure whether this is the best choice ...)

        hardware.raspberry-pi."4".dwc2.enable = true; # this is required for (the builtin) USBs on the CM4 to work (with NixOS' device trees, setting »dtoverlay=dwc2« in config.txt or eeprom has no effect)
        #hardware.raspberry-pi."4".dwc2.dr_mode = lib.mkDefault "otg"; # or "peripheral" or "host" ("otg" seems to work just fine also as host)

        hardware.deviceTree.enable = true;
        hardware.deviceTree.filter = lib.mkForce "bcm271[01]-rpi-*.dtb"; # rPI(cm)2/3/4(B(+))/Zero2(W) models

        environment.systemPackages = with pkgs; [
            libraspberrypi # »vcgencmd measure_temp« etc.
            raspberrypi-eeprom # rpi-eeprom-update
        ];

        boot.initrd.systemd.enableTpm2 = false;

    }) (lib.mkIf cfg.i2c { ## i2c

        hardware.i2c.enable = true; # includes »boot.kernelModules = [ "i2c-dev" ]« and some »services.udev.extraRules«
        environment.systemPackages = [ pkgs.i2c-tools ]; # e.g. »i2cdetect«
        boot.loader.raspberryPi.firmwareConfig = "dtparam=i2c_arm=on\n"; # with the default dtb, this enables the ARM i²c /dev/i2c-1 on pins 3+5 / GPIO2+3 (/ SDA+SCL) of all tested rPI models (this has mostly the same effect as setting »hardware.raspberry-pi."4".i2c1.enable«)
        # "dtparam=i2c_vc=on" enables the VideoCore i²c on pins 27+28 / GPIO0+1, but https://raspberrypi.stackexchange.com/questions/116726/enabling-of-i2c-0-via-dtparam-i2c-vc-on-on-pi-3b-causes-i2c-10-i2c-11-t
        # (there is also »hardware.raspberry-pi."4".i2c{0,1}.enable« as an alternative way to enable i2c_arm and i2c_vc, but that option seems bcm2711(/rPI4) specific)

    }) (lib.mkIf cfg.gpio { # GPIO group (this is not actually rPI specific ...)

        users.groups.gpio = { };
        services.udev.extraRules = ''
            # /sys/class/gpio/(un)export (when device appears):
            SUBSYSTEM=="gpio", KERNEL=="gpiochip*", ACTION=="add", \
            RUN+="${pkgs.coreutils}/bin/chown root:gpio /sys/class/gpio/export /sys/class/gpio/unexport", \
            RUN+="${pkgs.coreutils}/bin/chmod 220       /sys/class/gpio/export /sys/class/gpio/unexport"

            # /sys/class/gpio/gpio*/{active_low,direction,value} (on export request):
            SUBSYSTEM=="gpio", KERNEL=="gpio*", ACTION=="add", \
            RUN+="${pkgs.coreutils}/bin/chown root:gpio /sys%p/active_low /sys%p/direction /sys%p/edge /sys%p/value", \
            RUN+="${pkgs.coreutils}/bin/chmod 660 /sys%p/active_low /sys%p/direction /sys%p/edge /sys%p/value"

            # /dev/gpiochip* (when device appears):
            SUBSYSTEM=="gpio", KERNEL=="gpiochip*", ACTION=="add", \
            RUN+="${pkgs.coreutils}/bin/chown root:gpio /dev/%k", \
            RUN+="${pkgs.coreutils}/bin/chmod 660 /dev/%k"

            # /dev/gpiomem:
            SUBSYSTEM=="*gpiomem", KERNEL=="gpiomem", GROUP="gpio", MODE="0660"
        '';


    }) (lib.mkIf cfg.lightless {

        boot.loader.raspberryPi.firmwareConfig = ''
            # turn off ethernet LEDs
            dtparam=eth_led0=4
            dtparam=eth_led1=4
        '';
        systemd.tmpfiles.rules = [
            "w  /sys/class/leds/led0/brightness  -  -  -  -  0" # yellow (activity) LED
            "w  /sys/class/leds/led1/brightness  -  -  -  -  0" # red (power) LED
        ];

    }) ]);
}
