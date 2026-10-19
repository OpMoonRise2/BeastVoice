# BeastVoice 1.2

## Download the complete audio package

**[Download BeastVoice and its accompanying audio package on Nexus Mods](https://www.nexusmods.com/finalfantasy11/mods/32?tab=files).**

GitHub contains the addon source and documentation. To hear the supplied recordings, install the complete package from Nexus Mods; the GitHub source ZIP does not include the audio library.

Creature combat voices for Ashita v4. Runtime version: 1.2.0.

## Install

Copy `beastvoice.lua` to `Ashita/addons/beastvoice/`, and the separately supplied `sounds/` folder beside it. Load with `/addon load beastvoice`; open the menu with `/bv`.

The optional Goblin bomb overlay belongs at `Ashita/polplugins/DATs/beastvoice-bombtoss/`. Add its folder name to your Pivot overlay list. Keep existing overlays and settings; the addon voices and this native sound overlay are separate installation components.

## Controls

- Voice mode selects the categories that can play.
- Named voice presets use their own fixed rates. Custom uses the saved category rates.
- Creatures enables each supported family independently. Tonberry TP Songs controls Tonberry TP vocals separately from aggro, attack, ouch and death. Save Settings persists choices.
- Audition previews installed recordings. Reload with `/addon reload beastvoice` after updating code.

Ordinary TP vocals trigger on readies; completion lines are suppressed to prevent duplicates. Shadow Lord Implosion intentionally triggers on uses and cycles its recorded variations. Tonberry TP vocals use one exclusive BeastVoice channel; concurrent addon voice events are discarded until playback finishes. Bonze Marberry maps to Tonberry voices.

## Shadow Lord Stonega

Stonega and tiered casts such as Stonega II use `Shadowlord/shadow_stonega.wav`. Supply that recording in the voice folder to enable it; a missing recording is skipped. This corrects the old Stonea spelling.

## Recording names

Use the exact case and stems configured in `beastvoice.lua`. The resolver checks `.wav` before `.mp3`. Tonberry examples: `tonberry_ritual_bind.wav`, `tonberry_everyones_grudge.wav`, and `tonberry_everyones_rancor.wav`. Numbered category recordings must also be listed in the relevant category table; placing an extra numbered file in the folder does not automatically register it.

Audio and DAT payloads are distributed separately from the source bundle. Personal settings, runtime signals, backups and recordings marked unused are excluded.
