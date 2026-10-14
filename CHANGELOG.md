# Changelog

Changes to the Nora app, newest first. Work that is merged but not released yet goes under **Unreleased**; at release time it becomes the next version's section and its release notes.

## Unreleased

### Added
- Settings → Credits names ClamAV (Cisco Talos), YARA (VirusTotal) and Sparkle next to Mole, in English, Ukrainian and Russian.
- Settings → Credits has a **Third-party licenses** button that opens the bundled license texts.
- Stop in every operation that can end safely: Cleanup, Projects and Installers runs, Smart Care's Run, the Applications removal and updates and Security's quarantine (these two finish the item in progress first), `brew install` and the virus database download, and the external drive clean.
- The ClamAV database update shows that it is downloading.

### Changed
- Menu and scene icons match: each section's icon in the sidebar and the menu bar draws the same object as its scene. New glass objects for Cleanup (a trash can instead of a star with a white ball), Applications (four app tiles instead of a tile with a trash can, so it no longer looks like Cleanup), Projects (a clean `</>`), Performance (a bolt instead of a shield), History (a clock with a back arrow) and Tools (a wrench and a screwdriver instead of a gear).
- Homebrew updates run one app at a time, so Stop can wait for the app in progress.

### Fixed
- When two sections worked at once, such as Cleanup and Applications updates, each showed the other's current item. Every section now shows only its own command's output.
- A stopped command no longer shows as running forever in the console, and a stopped `brew install` no longer counts as a success.
- The app now ships Sparkle's MIT license and the external licenses it includes (`ThirdPartyNotices.txt`). 1.0.0 bundled Sparkle without them.

## 1.0.0 (2026-10-14)

First public release. See the [release notes](https://github.com/Lexus2016/Nora/releases/tag/v1.0.0).
