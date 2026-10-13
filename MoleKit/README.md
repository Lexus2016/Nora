# MoleKit

The UI-free core of Nora: it drives the [Mole](https://github.com/tw93/Mole) CLI as an external process. Nothing from Mole is bundled or linked.

| Piece | What it does |
|---|---|
| `PTYSession` | Runs a command on its own pseudo-terminal (`forkpty` in a C shim, so no Swift runs between fork and exec) and mirrors the output into a screen model. The child starts with a clean signal mask and default handlers: an inherited mask from a Dispatch thread once hung Mole's spinner. Keys are sent one write at a time; `waitUntil` waits for a quiet screen that matches a predicate. |
| `ScreenModel` | Minimal VT100: cursor moves, erase, scroll, UTF-8, alternate screen. Unknown escape sequences are recorded, so Mole UI drift fails tests instead of misreading the screen. |
| `InstallerDriver` | Selects exactly the requested files in `mo installer`. It checks the screen after every key and the review list before confirming, cancels on any mismatch, and never presses *All* or *Invert*. The menu cuts long names to "Prefix...", so a row matches by prefix and must be unique; the review list prints full names and is the final check. Lists longer than one screen are refused for now. |
| `UninstallDriver` | Drives `mo uninstall <name>` through both prompts. It answers `y` only when "Matched" lists exactly that app, and presses Enter only when "Files to be removed" equals the previewed entries; otherwise ESC. Wrappers that pipe `y` to stdin confirm the second prompt blind, because EOF reads as Enter. |
| `WhitelistOverlay` | Protects unchecked clean items by appending a marked block to `~/.config/mole/whitelist`. It journals the original state with fsync before writing and restores it byte for byte, including after SIGKILL. If the file was absent, it materializes Mole's own defaults first and deletes the file on restore. |
| `MoleInstallation` | Finds Mole's `lib/`, reads `mo --version`, and asks Mole's own code for its whitelist defaults and its `is_path_whitelisted` verdict. |
| `PrivilegeBroker` | `sudo -A -v && exec mo …` in the same PTY. sudo caches credentials per tty, and Mole's `adopt_sudo_session` only sees that session. |

## Tests

```sh
swift test                                   # unit tests, no Mole needed
NORA_MOLE_E2E=1 swift test                   # also runs the real `mo`, only against a sandbox $HOME, never with sudo;
                                             # uninstall tests set Mole's MOLE_TEST_NO_AUTH=1 (no sudo, no System Events prompt)
NORA_MOLE_E2E=1 NORA_RECORD_FIXTURES=1 swift test   # re-records Tests/MoleKitTests/Fixtures/<mole version>/
swift run molekit-spike sudo-check           # interactive: shows a password dialog, checks Mole adopts the session
swift run molekit-spike sudo-check --no-auth # the same script without a password; expects NORA_NOT_ADOPTED
```

The end-to-end tests use fixtures with collision-proof names in a temporary home: they delete two of five installers through the real `mo installer` menu, and remove a fixture app with its three leftovers through `mo uninstall --permanent`. Recorded transcripts have the sandbox path replaced with `$SANDBOX`.
