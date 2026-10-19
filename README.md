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

Ordinary TP vocals trigger on readies; completion lines are suppressed to prevent duplicates. Shadow Lord Implosion intentionally triggers on uses and plays its numbered recordings in order: 1, 2, 3, 4, then repeats from 1. Reloading the addon resets the sequence. Tonberry TP vocals use one exclusive BeastVoice channel; concurrent addon voice events are discarded until playback finishes. Bonze Marberry maps to Tonberry voices.

## Shadow Lord encounter aggro

The opening aggro line is eligible only on the first engagement of the encounter. Phase-two re-engagement and mob-index changes do not replay it. The flag survives phase-one defeat and transient player-memory recovery; a fresh zone entry or player/zone identity change resets it. Existing aggro preset and rate settings still apply to the first opportunity. Audition remains independent.

## Shadow Lord Stonega

Stonega and tiered casts such as Stonega II use `Shadowlord/shadow_stonega.wav`. Supply that recording in the voice folder to enable it; a missing recording is skipped. This corrects the old Stonea spelling.

## Additional Shadow Lord spells

The following recordings have distinct mappings in `sounds/Shadowlord/`:

| Cast name | Recording |
| --- | --- |
| Burn | `shadow_burn.wav` |
| Rasp | `shadow_rasp.wav` |
| Choke | `shadow_choke.wav` |
| Frost | `shadow_frost.wav` |
| Freeze | `shadow_freeze.wav` |
| Shock | `shadow_shock.wav` |
| Drown | `shadow_drown.wav` |

Frost and Freeze are separate mappings. Use Frost for the elemental debuff recording; Freeze is supported separately if you record that spell too. Missing recordings are skipped. Add the WAVs before expecting their callouts to play.

## Recording names

Use the exact case and stems configured in `beastvoice.lua`. The resolver checks `.wav` before `.mp3`. Tonberry examples: `tonberry_ritual_bind.wav`, `tonberry_everyones_grudge.wav`, and `tonberry_everyones_rancor.wav`. Numbered category recordings must also be listed in the relevant category table; placing an extra numbered file in the folder does not automatically register it.

Audio and DAT payloads are distributed separately from the source bundle. Personal settings, runtime signals, backups and recordings marked unused are excluded.

## Normalized audio refresh (2026-10-19)

The complete Nexus package now contains 408 WAV recordings. Of these, 373 were attenuated for more consistent playback; 35 quieter recordings were preserved. Normalization targets active RMS of -20 dBFS and a sample-peak ceiling of -3 dBFS, without boosting quiet recordings. The largest reduction is 10.02 dB.

Four Shadow Lord recordings contained consecutive samples at the digital limit: attack 7, attack 9, ouch 3 and Thundaga. Their playback levels were reduced; pre-existing clipping distortion is not restored. The optional bomb overlay is unchanged.

`AUDIO-MANIFEST.json` records every packaged WAV hash, format, applied gain and measured sample peak. All WAV payloads were fully read and the normalized files verified against the installed addon. This refresh does not change runtime version 1.2.0. No new listening, live combat, LUFS or true-peak tests were performed.
