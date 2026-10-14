# Building Nora

## Finish line: "ready to build a DMG"

All of these must pass:

1. `scripts/build-dmg.sh` produces `dist/Nora-<version>.dmg`. The app and the DMG are signed with Developer ID (hardened runtime, secure timestamp), notarized with the `nora-notary` keychain profile and stapled.
2. `codesign --verify --deep --strict --verbose=2 Nora.app` passes and `spctl -a -vv Nora.app` reports `Notarized Developer ID`.
3. The app copied out of the mounted DMG and launched with `open -n` (a Finder-like environment without the Homebrew `PATH`) finds Mole, shows live System Status, scans Space Map and reaches every review screen through dry-runs.
4. The bundle contains the `en`, `uk` and `ru` localizations.

## Order of work

1. Skeleton and pipeline: `App/project.yml` (XcodeGen), the local MoleKit package, one real screen (System Status from NDJSON), the DMG script. A valid DMG exists from this step on and stays green.
2. Tier A, Mole coverage: onboarding (Locator, Mole install and update), System Status, Space Map, Cleanup (dry-run, whitelist overlay, PTY, sudo), Applications, Installers, Projects (purge driver), Performance, History, Protection, Tools, Settings, Smart Care, menu bar, console, en/uk/ru.
3. Tier B, beyond Mole: Security (audit, XProtect, ClamAV), power and temperature, energy mode, ports and network, Homebrew app updates, scheduler.

A module that is not finished is absent from the sidebar. There are no mock screens in the app.

## Rules while developing

- Real `clean`, `optimize`, `purge` and `uninstall` runs never happen on the developer's Mac. Verification uses dry-runs, the sandboxed `HOME` end-to-end tests (`NORA_MOLE_E2E=1`) and rendered snapshots.
- Committed fixtures are synthetic or scrubbed: no real app lists, no `/var/folders` paths.
- TCC permissions (Automation, Full Disk Access) are tied to the code signature, so they are checked on the signed release build.

## Requirements

- Xcode 27 or newer, `xcodegen` and `create-dmg` (`brew install xcodegen create-dmg`).
- A Developer ID Application certificate in the login keychain.
- `App/Config/Local.xcconfig` (gitignored, copy `Local.xcconfig.example`) with `DEVELOPMENT_TEAM`.
- Notarization: `xcrun notarytool store-credentials nora-notary --apple-id <id> --team-id <team>` once.

## Identity

- Bundle ID `io.github.lexus2016.nora`. It is durable: TCC grants, Sparkle and notarization history key on it.
- Minimum macOS 14.0. Built with the macOS 27 SDK; Liquid Glass is used behind `#available(macOS 26, *)`.

## Tests

- App: `cd App && xcodegen generate && xcodebuild -project Nora.xcodeproj -scheme Nora -destination 'platform=macOS' test`.
- MoleKit: `cd MoleKit && swift test`. With `NORA_MOLE_E2E=1` the end-to-end suites run the real `mo` against a sandbox `$HOME` (installer, uninstall, purge, whitelist overlay). They never use sudo.

## Releasing an update

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/Config/Nora.xcconfig`.
2. `scripts/build-dmg.sh` → `dist/Nora-<version>.dmg`, signed, notarized and stapled. Keep the Mac unlocked: `notarytool` reads the `nora-notary` profile from the keychain only while the Mac is unlocked.
3. Make the Sparkle feed. `dist/` must hold only the new DMG plus a copy of the published `appcast.xml` from the repo root, so earlier releases stay in the feed. Then run `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix https://github.com/Lexus2016/Nora/releases/download/v<version>/ --link https://github.com/Lexus2016/Nora dist/`. It signs the archive with the EdDSA private key in the login keychain and updates `dist/appcast.xml`. macOS asks for keychain access first; click Allow, or the command waits forever.
4. Tag the release commit `v<version>` and create the GitHub Release with the DMG. Check that the asset URL returns 200 before you publish the feed. Then copy `dist/appcast.xml` to the repo root and push it: Pages serves it at `https://lexus2016.github.io/Nora/appcast.xml` (the `SUFeedURL` in `Info.plist`).
5. Back up the Sparkle private key once: `generate_keys -x sparkle_private_key` (the file name is gitignored), then store it somewhere safe and delete the export. Without this key, installed copies cannot verify future updates.
