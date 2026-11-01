# Publication and verification state

Updated 2026-11-01. Maintainer: MoonRise (Eldorin).

GitHub hosts the addon source, author-supplied screenshots, and an installation ZIP. Optional recordings remain separate on Nexus Mods or may be supplied by each player. GitHub packages exclude audio, DAT overlays, personal configuration, runtime signals, recovery backups, and unrelated binaries. Existing attribution is preserved; no new license is granted for third-party material or project code.

Current verification: the Lua files pass loadfile syntax checks. This publication changes documentation, screenshots and packaging, not runtime logic. Earlier live-test reports in MAINTENANCE.md are historical evidence, not new tests. No new in-client playback, combat or cutscene test was performed for this publication.

The author-supplied screenshots show the author's installed UI. Their exact runtime revision has not been established; they are visual reference, not proof that the published source reproduces every shown control. Compare the published source before relying on a particular feature.

External Nexus descriptions and downloadable archives have not been changed by this publication. Any old wording directing users to download the addon there still needs removal by the maintainer; retain Nexus downloads for optional audio assets only. Historical audio distribution is not evidence of redistribution rights. No audio or DAT asset is newly published here.

This publication does not assert reviewer approval. Final review remains pending.

## Binary transparency

No binary is shipped in this addon release. The Lua source loads winmm.dll from Windows for audio playback. Ashita and its bundled libraries are prerequisites and are not republished.

## Nexus follow-up completed (2026-11-01)

After the GitHub release publication, the signed-in Nexus short and full descriptions were updated and verified on the public pages. They direct addon/helper downloads to GitHub only and explain optional audio installation. Current mixed-archive file descriptions also direct users to copy only audio/optional sound overlays and ignore bundled legacy code. The ZoneMusic legacy helper file explicitly directs users to GitHub instead of installing it from Nexus.

The release-tag snapshot above predates these external-page edits. The existing Nexus archives themselves remain unchanged, including legacy bundled code and older documentation. Audio-only replacement archives are still pending; no audio, DAT files or newly compiled binaries were uploaded during this follow-up. Historical files and internal archive documentation were not rewritten. Final reviewer approval remains pending.