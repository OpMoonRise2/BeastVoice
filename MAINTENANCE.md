# Maintenance state

The runtime Lua owns parsing, playback policy, GUI controls and settings defaults. User preferences remain in Ashita's separate configuration directory. Audio files and the optional native bomb overlay are maintained as separate release assets.

This snapshot follows the installed addon after the user reported completion of Tonberry testing on 2026-10-18. It includes creature toggles, the separate Tonberry TP control, named Tonberry matching, and the smoothed final Rancor and Ritual Bind recordings in the external asset package.

Preserve the existing queue priorities, TP first-wins exclusivity, readies/uses exception, zone-transition guard and independent named-preset versus Custom rates. Exercise these behaviors after changing parsing or playback gates. A syntax check or mocked audio test alone does not prove live engine behavior.

The source bundle was copied from the installed runtime without behavioral edits during cleanup. Existing local source ownership and license terms are retained; this preparation does not grant a new license.

Audio state as of 2026-10-19: the installed library contains 408 WAVs, with 373 attenuated and 35 unchanged. AUDIO-MANIFEST.json records the current release asset hashes and normalization policy; actual audio remains outside Git and ships in the Nexus package. Original pre-normalization files are retained locally outside the repository. The four original rail-clipped recordings remain subject to recorded distortion; attenuation only provides playback headroom. Runtime source is unchanged and matches origin/main before this documentation update. No merge is needed when local main and origin/main are already identical.
