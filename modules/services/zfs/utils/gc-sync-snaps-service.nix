{ pkgs, lib, dataset, label, ... }: let
    script = pkgs.runCommandLocal "gc-sync-snaps-script" {
        script = ./gc-sync-snaps.sh; nativeBuildInputs = [ pkgs.buildPackages.makeWrapper ];
    } ''makeWrapper $script $out --prefix PATH : ${"/run/booted-system/sw/bin"}'';
in {
    service = {
        description = "Removes old »@syncoid_*« sync snapshots in the backup receive dataset »${dataset}«";
        environment.TZ = "UTC"; startAt = "04:15 UTC"; # should be done receiving
        after = [ "zfs.target" ];  serviceConfig.Type = "oneshot";
        serviceConfig.ExecStart = "${script} ${dataset} ${label}";
    };
    timer.timerConfig = {
        RandomizedDelaySec = 1800;
        Persistent = true;
    };
}
