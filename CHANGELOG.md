# Changelog

Changes to the Nora app, newest first. Work that is merged but not released yet goes under **Unreleased**; at release time it becomes the next version's section and its release notes.

## 1.2.0 (2026-10-15)

### Added
- Settings → General → Menu bar can show the CPU temperature next to the Nora icon, with a coloured dot for how hot it runs: green below 70 °C, orange from 70 °C, red from 90 °C. Off by default; the tooltip gives the value in degrees, or says when no current reading is available. When the chip's sensors give no CPU temperature, Nora reads it from Mole and keeps that stream running while the setting is on.

### Changed
- Updating an app that is open no longer fails with "Quit it and try again". Update now asks first, then quits the open apps the way their own Quit command does, so each one can ask to save your work, updates them and opens them again. An app that stays open, for example because you cancelled its save dialog, is skipped and named in the result, and an app you open while the update runs is left alone. Every app Nora quit comes back, even when a later one refuses to close.

### Fixed
- Cleanup and Projects could remove an item you unticked when its name was one Mole's protection list does not accept, such as a folder with `..` in its name or a name ending in a space. Nora now asks Mole, after writing the protection and before the run, whether every unticked path really is protected; if one is not, nothing runs and the result names it.
- Cleanup hid a category when Mole could not measure its size, while its items stayed ticked and were cleaned. Every category with items now shows, with "Size unknown" where Mole gave no size. Rows Mole marks with an item count or as counted under another row are read correctly, and are no longer counted twice.
- Cleanup checks again right before every run, not only when something is unticked, so junk that appeared after the review is protected even when everything stays ticked. With system caches included, that check and the clean run in one authenticated session, so the check sees exactly what the run will see; before, it ran without administrator rights and could miss new system items.
- Stop and Quit now wait for every helper a Mole command started without a terminal, not only the command itself: a helper that ignores the stop signal is killed after 2 seconds, and Nora restores Mole's protection list only once all of them are gone. Quitting Nora waits for such helpers too.
- A Full security scan no longer scans Nora's own quarantine and virus database: a quarantined file came back as a new finding, and quarantining it again split its entry so one Restore no longer put it back. A file already in quarantine can no longer be quarantined again.
- When yara failed on one folder, the XProtect matches it had already found in other folders were dropped, and a failure that printed output still counted as a clean run. Matches are now kept as each folder finishes, and the card says when some folders could not be checked.
- A file named `meta.json` could not be quarantined. Quarantined files are now kept in a `payload` folder of their entry; older entries are still listed and restored.
- Smart Care no longer runs a step whose review has nothing ticked (or found nothing): it shows "nothing to do" instead of starting the command and reporting a failure. Cleanup, Projects and Installers also refuse an empty selection themselves.
- History counts failed maintenance tasks apart from failed files, so a failed optimize no longer shows as "Failed 0"; each recent session with failures says how many.
- Tools → External drive shows why a preview or a clean failed (the error Mole printed), instead of an empty card. A failed clean says that some files may already be removed.
- Installing Mole from Nora gives up on a download that stalls (30 s to connect, under 1 KB/s for 10 s, 5 minutes in all), and the install can be stopped; a stopped download never reaches the installer.
- Watch Downloads now knows a file by its version, not its name: a file deleted and downloaded again under the same name, or replaced, is checked again. Before, a reused name was never checked after the first time.
- Watch Downloads no longer looks active after ClamAV stopped. Nora restarts it (up to three times in ten minutes, then turns the watch off and says why), and a download clamdscan could not check is named in Settings and checked again after the restart instead of passing as clean.
- Security's launch item review now checks what Apple's script interpreters (`sh`, `zsh`, `osascript`, `python3` and others) are told to run: a launch agent that pipes a download into a shell, decodes base64, or runs a script from a temporary, shared or hidden folder is flagged even though `/bin/sh` itself is signed by Apple. Other Apple-signed programs are still not flagged.
- Smart Care's Scan waits for a module that is already scanning instead of starting it a second time; the first scan could otherwise finish later and overwrite the module's state, even during a run. Stop during Scan stops only the scans Smart Care started, and Stop during Run only the step it started, so a module you run on its own screen goes on.
- Handing a downloaded app over to Homebrew is now a checked transaction. The old copy is set aside in Nora's own folder (journaled and synced first), not straight in the Trash; after `brew install` Nora reads the new bundle and keeps it only if it has the same bundle ID and is not older; only then does the old copy go to the Trash. Otherwise whatever Homebrew left goes to the Trash and the old copy goes back. A quit or crash mid-install is finished the same way on the next start, and a damaged journal stops the update instead of being ignored. The result shows the version actually installed.
- When Nora puts the old copy back after a failed handover, it also removes the record Homebrew made of the app during that install (its `Caskroom` folder goes to the Trash), so a later `brew upgrade` does not replace the copy you kept. `brew uninstall` is not used for this: it would run the cask's uninstall steps against the restored app.
- An app whose bundle belongs to `root`, as Google Chrome's does when its own updater installed it, gets **Open** instead of the Homebrew handover: Nora cannot move such a bundle aside, so the handover could only fail.
- An app that installs its own downloaded update as it quits (Sparkle, Squirrel's ShipIt) now counts as updated when Nora quits it for an update, instead of failing with "It changed since the scan". Nora reopens quit apps only once their bundle has stopped changing, and tries once more if the app is not running a few seconds later; the screen says "Opening the apps again" meanwhile. When macOS does not let Nora move an app aside, the result says so in words and points to App Management, instead of showing a file error.
- Right before an app is handed over, Nora reads it and its Homebrew entry again: an app that updated itself since the scan, or a cask that changed, is skipped with "Scan again".
- An app is matched to a Homebrew cask only by its exact bundle ID, not by an ID that merely starts the same way, and by the name the cask really installs: a cask that renames its app (for example `CleanMyMac_5.app` installed as `CleanMyMac.app`) no longer matches the downloaded copy.
- Versions with letters compare only with their own kind: `2.0rc1` no longer counts as newer than `2.0`, and an app's own feed that gives only build numbers is not weighed against Homebrew's marketing version.
- The menu bar title and the quick menu show only current numbers: when Mole's status stream stops or goes quiet for 15 seconds they show dashes (and the quick menu the reason) instead of the last values.

### Build
- `scripts/build-dmg.sh` runs a release gate before the archive: the tree must be committed, then `scripts/l10n.py check` (new: missing translations, mismatched format specifiers, plurals without `other`, a stale catalog), the MoleKit tests and the app tests. Any failure stops the build.

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
