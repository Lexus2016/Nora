# Changelog

Changes to the Nora app, newest first. Work that is merged but not released yet goes under **Unreleased**; at release time it becomes the next version's section and its release notes.

## 1.1.0 (2026-10-14)

### Added
- Applications now finds updates for apps you installed from a DMG or a zip, not only for Homebrew apps. Nora reads each app's own update feed and Homebrew's public app list, and matches an app to that list only when both its name and its bundle ID agree. If Homebrew can take the app over, Update moves the old copy to the Trash, installs the new version with `brew install --cask` and puts the old copy back if the install fails, or the next time Nora starts if it was quit in the middle. From then on Homebrew keeps the app up to date. Other apps get an **Open** button, and their own updater installs the new version.
- Settings → Credits names ClamAV (Cisco Talos), YARA (VirusTotal) and Sparkle next to Mole, in English, Ukrainian and Russian.
- Settings → Credits has a **Third-party licenses** button that opens the bundled license texts.
- Stop in every operation that can end safely: Cleanup, Projects and Installers runs, Smart Care's Run, the Applications removal and updates and Security's quarantine (these two finish the item in progress first), `brew install` and the virus database download, and the external drive clean.
- The ClamAV database update shows that it is downloading.

### Changed
- Menu and scene icons match: each section's icon in the sidebar and the menu bar draws the same object as its scene. New glass objects for Cleanup (a trash can instead of a star with a white ball), Applications (four app tiles instead of a tile with a trash can, so it no longer looks like Cleanup), Projects (a clean `</>`), Performance (a bolt instead of a shield), History (a clock with a back arrow) and Tools (a wrench and a screwdriver instead of a gear).
- Tools → Remove Mole shows an app-removal icon instead of the trash can, which now belongs to Cleanup.
- Homebrew updates run one app at a time, so Stop can wait for the app in progress.
- The Applications scan now goes online: it downloads Homebrew's public app list from formulae.brew.sh and reads the update feeds of apps installed from a download. Every request is shown in the console.

### Fixed
- Review buttons on a glass object (Smart Care tiles and the large result cards) have a darker backing, so their text stays readable over a bright object.
- When two sections worked at once, such as Cleanup and Applications updates, each showed the other's current item. Every section now shows only its own command's output.
- A stopped command no longer shows as running forever in the console, and a stopped `brew install` no longer counts as a success.
- The app now ships Sparkle's MIT license and the external licenses it includes (`ThirdPartyNotices.txt`). 1.0.0 bundled Sparkle without them.

## 1.0.0 (2026-10-14)

First public release. See the [release notes](https://github.com/Lexus2016/Nora/releases/tag/v1.0.0).
