dirname: inputs: {
    nodejs, # tcc uses v14, v20 works
    electron, # tcc uses v13, v29 works
    buildNpmPackage, fetchFromGitHub, buildPackages,
    bash, udev, python3,
    coreutils, procps, gnugrep, gnused, gawk, xorg, which, # wrapper
lib }: let
    version = "2.1.8"; rev = "v${version}";
    srcHash = "sha256-SIRm2+1lkPnzITT3VmshTXDen43y3v9OCIMoIjrPJSE="; # after updating the lockfile, see below
    npmDepsHash = "sha256-1hedSJm+nvKCZhDoefM4j2pTSfywfHeRIWs8x5iDUQY=";

    replace = if (builtins.substring 0 5 lib.version) >= "24.05" then "--replace-fail" else "--replace";
in (buildNpmPackage.override { nodejs = buildPackages.nodejs; }) rec {
    pname = "tuxedo-control-center"; inherit version;

    src = (fetchFromGitHub { # https://github.com/tuxedocomputers/tuxedo-control-center
        owner = "tuxedocomputers"; repo = pname; name = "${pname}-src"; inherit rev; hash = srcHash;
        # The lockfile format is outdated (node 14) and buildNpmPackage can't handle (the way that it includes?) a git+https reference.
        # This may very well undo a bugfix (in that forked reference) and cause the source hash to be unstable, but it works for now.
        postFetch = ''(
            HOME=$( realpath /build/home ) ; cd $out
            export PATH=$PATH:${lib.makeBinPath [ buildPackages.nodejs buildPackages.which buildPackages.git buildPackages.openssh ]}
            export NODE_EXTRA_CA_CERTS=${buildPackages.cacert}/etc/ssl/certs/ca-bundle.crt
            npm uninstall --package-lock-only --legacy-peer-deps --ignore-scripts node-ble || exit
            npm install --package-lock-only --legacy-peer-deps --ignore-scripts --legacy-peer-deps node-ble@1.9.0 || exit
        )'';
    }); inherit npmDepsHash;

    # Compatibility options:
    makeCacheWritable = true;
    npmPackFlags = [ "--ignore-scripts" ];
    npmFlags = [ "--legacy-peer-deps" ]; # "--loglevel=verbose"
    NODE_OPTIONS = "--openssl-legacy-provider";

    nativeBuildInputs = [ buildPackages.git buildPackages.pkg-config buildPackages.python3 ];
    buildInputs = [ udev ];
    prePatch = ''
        # skip bundling (not necessary), but do create the target dir (otherwise, later »cp« operations do strange things)
        substituteInPlace package.json \
            ${replace} ' && run-s bundle-service' ' && cp ./build/Release/TuxedoIOAPI.node ./dist/tuxedo-control-center/service-app/native-lib && mkdir -p ./dist/tuxedo-control-center/data/service/'
    '';
        # tell gyp where to find udev(/systemd) (it did not pick this up from the environment)
        #substituteInPlace binding.gyp \
        #    ${replace} '"libraries": [' '"libraries": [ "-L${udev}/lib",' \
        #    ${replace} '"include_dirs": [' '"include_dirs": [ "${udev.dev}/include",'

    ELECTRON_OVERRIDE_DIST_PATH = "${electron}/bin/electron"; # (this is ignored?)
    ELECTRON_SKIP_BINARY_DOWNLOAD = true;

    outputs = [ "out" "autostart" ];
    installPhase = ''
        runHook preInstall

        substituteInPlace dist/tuxedo-control-center/{data/dist-data/99-webcam.rules,data/dist-data/com.tuxedocomputers.tccd.policy,data/dist-data/tccd.service,data/dist-data/tuxedo-control-center.desktop,e-app/common/classes/TccPaths.js,ng-app/de/main-es5.js,ng-app/de/main-es5.js.map,ng-app/de/main-es2015.js,ng-app/de/main-es2015.js.map,ng-app/en/main-es5.js,ng-app/en/main-es5.js.map,ng-app/en/main-es2015.js,ng-app/en/main-es2015.js.map,ng-app/en-US/main-es5.js,ng-app/en-US/main-es5.js.map,ng-app/en-US/main-es2015.js,ng-app/en-US/main-es2015.js.map,service-app/common/classes/TccPaths.js} \
            ${replace} '/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/' "$out/share/tuxedo-control-center/"
        substituteInPlace dist/tuxedo-control-center/data/dist-data/*.desktop \
            ${replace} '/opt/tuxedo-control-center/tuxedo-control-center' "$out/bin/tuxedo-control-center"
        substituteInPlace dist/tuxedo-control-center/data/dist-data/tccd-sleep.service \
            ${replace} '/bin/bash -c' '${bash}/bin/bash -c'
        substituteInPlace dist/tuxedo-control-center/data/dist-data/99-webcam.rules \
            ${replace} '/usr/bin/python3' '${python3}/bin/python3'
        substituteInPlace dist/tuxedo-control-center/{e-app,service-app}/common/classes/XDisplayRefreshRateController.js \
            ${replace} 'setEnvVariables() {' 'setEnvVariables() { return;' # won't work anyway
        substituteInPlace dist/tuxedo-control-center/{e-app,service-app}/native-lib/TuxedoIOAPI.js \
            ${replace} "require('./TuxedoIOAPI.node')" "require('$out/share/tuxedo-control-center/service-app/native-lib/TuxedoIOAPI.node')"
        rm -f dist/tuxedo-control-center/data/dist-data/com.tuxedocomputers.tomte.policy

        mkdir -p $out/bin/ $out/share/
        cp -rT dist/tuxedo-control-center/ $out/share/tuxedo-control-center/
        cp -rT node_modules/ $out/share/tuxedo-control-center/node_modules/

        <<<'#!${bash}/bin/bash
            exec ${electron}/bin/electron '$out'/share/tuxedo-control-center "$@"
        ' install -m 555 -T /dev/stdin $out/bin/tuxedo-control-center
        <<<'#!${bash}/bin/bash
            PATH=${lib.makeBinPath [ coreutils procps gnugrep gnused gawk xorg.xrandr xorg.xset which ]} exec ${nodejs}/bin/node '$out'/share/tuxedo-control-center/service-app/service-app/main.js "$@"
        ' install -m 555 -T /dev/stdin $out/share/tuxedo-control-center/data/service/tccd
        ln -sT $out/share/tuxedo-control-center/data/service/tccd $out/bin/tccd

        mkdir -p $out/share/applications/ ; ln -st $out/share/applications/ $out/share/tuxedo-control-center/data/dist-data/tuxedo-control-center.desktop
        mkdir -p $out/share/dbus-1/system.d/ ; ln -st $out/share/dbus-1/system.d/ $out/share/tuxedo-control-center/data/dist-data/com.tuxedocomputers.tccd.conf
        mkdir -p $out/share/polkit-1/actions/ ; ln -st $out/share/polkit-1/actions/ $out/share/tuxedo-control-center/data/dist-data/com.tuxedocomputers.tccd.policy
        mkdir -p $out/lib/systemd/system/ ; ln -st $out/lib/systemd/system/ $out/share/tuxedo-control-center/data/dist-data/*.service
        #mkdir -p $out/share/systemd/user/ ; ln -st $out/share/systemd/user/ --
        mkdir -p $out/lib/udev/rules.d/ ; ln -st $out/lib/udev/rules.d/ $out/share/tuxedo-control-center/data/dist-data/*.rules

        mkdir -p $autostart/etc/xdg/autostart ; ln -st $autostart/etc/xdg/autostart $out/share/tuxedo-control-center/data/dist-data/tuxedo-control-center-tray.desktop

        runHook postInstall
    '';

    meta = {
        homepage = "https://github.com/tuxedocomputers/tuxedo-control-center";
        description = "A tool to help you control performance, energy, fan and comfort settings on TUXEDO laptops.";
        mainProgram = "tuxedo-control-center";
        license = lib.licenses.gpl3;
        maintainers = [ ];
        platforms = lib.platforms.linux;
    };
}
