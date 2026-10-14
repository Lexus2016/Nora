# Changelog

Changes to the Nora app, newest first. Work that is merged but not released yet goes under **Unreleased**; at release time it becomes the next version's section and its release notes.

## Unreleased

### Added
- Settings → General → Menu bar can show the CPU temperature next to the Nora icon, with a coloured dot for how hot it runs: green below 70 °C, orange from 70 °C, red from 90 °C. Off by default; the tooltip gives the exact value.

### Changed
- Updating an app that is open no longer fails with "Quit it and try again". Update now asks first, then quits the open apps the way their own Quit command does, so each one can ask to save your work, updates them and opens them again. An app that stays open, for example because you cancelled its save dialog, is skipped and named in the result.

### Fixed
- Cleanup and Projects could remove an item you unticked when its name was one Mole's protection list does not accept, such as a folder with `..` in its name or a name ending in a space. Nora now asks Mole, after writing the protection and before the run, whether every unticked path really is protected; if one is not, nothing runs and the result names it.
- Cleanup hid a category when Mole could not measure its size, while its items stayed ticked and were cleaned. Every category with items now shows, with "Size unknown" where Mole gave no size. Rows Mole marks with an item count or as counted under another row are read correctly, and are no longer counted twice.
- Handing a downloaded app over to Homebrew is now a checked transaction. The old copy is set aside in Nora's own folder (journaled and synced first), not straight in the Trash; after `brew install` Nora reads the new bundle and keeps it only if it has the same bundle ID and is not older. Otherwise whatever Homebrew left goes to the Trash and the old copy goes back. Only then does the old copy go to the Trash. A quit or crash mid-install is finished the same way on the next start, and a damaged journal stops the update instead of being ignored. The result shows the version actually installed.
- Right before an app is handed over, Nora reads it and its Homebrew entry again: an app that updated itself since the scan, or a cask that changed, is skipped with "Scan again".
- An app is matched to a Homebrew cask only by its exact bundle ID, not by an ID that merely starts the same way, and by the name the cask really installs: a cask that renames its app (for example `CleanMyMac_5.app` installed as `CleanMyMac.app`) no longer matches the downloaded copy.
- Versions with letters compare only with their own kind: `2.0rc1` no longer counts as newer than `2.0`, and an app's own feed that gives only build numbers is not weighed against Homebrew's marketing version.
- Updating apps that are open: an app that was quit before another one refused to close comes back, and an app opened during the update is left open and skipped instead of being quit without asking.

## 1.1.0 (2026-10-14)

### Added
- Applications now finds updates for apps you installed from a DMG or a zip, not only for Homebrew apps. Nora reads each app's own update feed and Homebrew's public app list, and matches an app to that list only when both its name and its bundle ID agree. If Homebrew can take the app over, Update moves the old copy to the Trash, installs the new version with `brew install --cask` and puts the old copy back if the install fails, or the next time Nora starts if it was quit in the middle. From then on Homebrew keeps the app up to date. Other apps get an **Open** button, and their own updater installs the new version.
- Settings → Credits names ClamAV (Cisco Talos), YARA (VirusTotal) and Sparkle next to Mole, in English, Ukrainian and Russian.
- Settings → Credits has a **Third-party licenses** button that opens the bundled license texts.
- Stop in every operation that can end safely: Cleanup, Projects and Installers runs, Smart Care's Run, the Applications removal and updates and Security's quarantine (these two finish the item in progress first), `brew install` and the virus database download, and the external drive clean.
- The ClamAV database update shows that it is downloading.

### Changed
- Menu and scene icons match: each section's icon in the sidebar and the menu bar draws the same object as its scene. New glass objects for Cleanup (a trash can instead of a star with a white ball), Applications (four app tiles instead of a tile with a trash can, so it no longer looks like Cleanup), Projects (a clean `</>`), Performance (a bolt instead of a shield), History (a clock with a back arrow) and Tools (a wrench and a screwdriver instead of a gear).
- The app icon's glass vessel is 20% smaller, with more white around it.
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
