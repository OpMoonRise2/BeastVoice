# Maintenance state

The runtime Lua owns parsing, playback policy, GUI controls and settings defaults. User preferences remain in Ashita's separate configuration directory. Audio files and the optional native bomb overlay are maintained as separate release assets.

This snapshot follows the installed addon after the user reported completion of Tonberry testing on 2026-10-18. It includes creature toggles, the separate Tonberry TP control, named Tonberry matching, and the smoothed final Rancor and Ritual Bind recordings in the external asset package.

Preserve the existing queue priorities, TP first-wins exclusivity, readies/uses exception, zone-transition guard and independent named-preset versus Custom rates. Exercise these behaviors after changing parsing or playback gates. A syntax check or mocked audio test alone does not prove live engine behavior.

The source bundle was copied from the installed runtime without behavioral edits during cleanup. Existing local source ownership and license terms are retained; this preparation does not grant a new license.
