{ pkgs, lib, dataset, ... }: let
    script = pkgs.runCommandLocal "reset-recv-script" {
        script = ./reset-recv.sh; nativeBuildInputs = [ pkgs.buildPackages.makeWrapper ];
    } ''makeWrapper $script $out --prefix PATH : ${"/run/booted-system/sw/bin"}'';
in {
    service = {
        description = "Aborts potentially stuck receives on the backup receive dataset »${dataset}«";
        environment.TZ = "UTC"; startAt = "23:15 UTC"; # should run before receiving
        after = [ "zfs.target" ];  serviceConfig.Type = "oneshot";
        serviceConfig.ExecStart = "${script} ${dataset}";
    };
    timer.timerConfig = {
        RandomizedDelaySec = 1800;
        Persistent = true;
    };
}
