/*

# Patches for [sanoid](https://github.com/jimsalterjrs/sanoid)/syncoid

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS overlay:
dirname: inputs: final: prev: { sanoid = prev.sanoid.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [

        # Fixes syncoid so that when it is supposed to send recursive snapshots, it also creates and prunes its sync snaps recursively.
        ../patches/sanoid-sync-snap-recursive.patch

        # Adds the »--sync-snap-cmd-before/after« flags to syncoid, allowing to run an arbitrary command before/after sending, with the sync snap as argument.
        ../patches/sanoid-sync-snap-cmd.patch

        # Adds the »--keep-sync-snap-source/target« flags to syncoid, which keeps the created sync snapshots selectively on the source/target (relevant when syncoid can only delete on one end).
        # (To avoid conflicts with other patches, and since it is quite clear where the hunks are to be applied, this patch uses very little context. Replacing lines and single line anchors after an inserted line seem to work fine, single line anchors before not so much.)
        ../patches/sanoid-keep-sync-snap-target.patch

        # Makes the »-no-command-checks« "work(s) for me". (Nobody seems to have ever used or tested this. There is a typo in flag name, and at least one further bug (but probably more).)
        ../patches/sanoid-fix-no-command-checks.patch

        # Adds the »--sync-snap-hold/release« flags to syncoid, which set/release holds on the sync snap before/after sending.
        # (Includes the »sanoid-sync-snap-recursive.patch« and »sanoid-keep-sync-snap-target.patch« patches.)
        #../patches/sanoid-sync-snap-hold.patch

    ];
}); }
