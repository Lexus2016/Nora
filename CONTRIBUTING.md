# Contributing to Nora

Nora is source-available under [PolyForm Noncommercial 1.0.0](LICENSE). Read the license before using or distributing changes; this guide does not change its terms.

Search [existing issues](https://github.com/Lexus2016/Nora/issues) first. Include Nora and macOS versions, Apple silicon or Intel, Mole version, affected section, reproduction steps and expected/actual results. Say whether the problem happened during a preview or an approved action.

Use synthetic filenames and redact usernames, private paths, installed-app lists and credentials. Do not post passwords or repeat a destructive action to reproduce a bug.

Keep pull requests focused. Include before/after screenshots for UI changes and regression coverage for parser, selection or deletion-safety changes. Keep shared instructions consistent in English, Ukrainian and Russian.

See [the build guide](docs/BUILD.md) for toolchain requirements and the complete release gate. On a supported Mac:

```bash
python3 scripts/l10n.py check
(cd MoleKit && swift test --no-parallel)
(cd App && xcodegen generate && xcodebuild -project Nora.xcodeproj -scheme Nora -destination 'platform=macOS' test)
```

Use synthetic fixtures and dry-runs. Never test real `clean`, `optimize`, `purge` or `uninstall` operations on a user's files. Leave opt-in live and administrator checks disabled unless the specific isolated test has been reviewed. Report checks you could not run.
