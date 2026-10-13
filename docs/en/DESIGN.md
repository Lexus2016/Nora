# Nora: design and architecture

🇬🇧 English · [Українська](../uk/DESIGN.md) · [Русский](../ru/DESIGN.md)

> **Nora** (Ukrainian *нора* = a mole's burrow) is the approved name. The name "Mole" may not be used by third parties (`TRADEMARK.md` in Mole), and "Burrow" is already taken by a direct competitor.
> Interactive prototype: [`prototype/`](../../prototype/) (online: https://lexus2016.github.io/Nora/prototype/). Its data is demo data, but every format mirrors real Mole 1.59.1 output.

## 0. Summary

- **Stack:** native SwiftUI + AppKit, macOS 14+. Mole is macOS-only, and both strongest references (MangelSP/MoleUI, Burrow) are native. The Tauri wrappers lose on feel and on safety (`csp: null`, merged stdout/stderr).
- **Mole is not bundled.** Nora finds it, offers to install it and updates it through the user's own channel. This avoids GPL redistribution duties and a broken update path.
- **Installs and updates Mole by itself:** Homebrew, or Mole's official installer at a pinned version with checksum verification into `~/.local/bin`, with no Terminal and no admin password. **Updates itself** with Sparkle 2.
- **Menu bar quick menu:** live system metrics, reclaimable space, jumps to every section, Mole status and updates.
- **Mole's machine interface is partial.** `status`, `analyze`, `history` and `uninstall --list` return JSON; everything else is text plus TUI prompts. The integration layer therefore has three modes: JSON pipe, NDJSON stream, and a PTY with an auto-responder.
- **Core principle:** a checkbox only appears where we know how Mole will honour it. §4 names the mechanism for every selection. None of the four reference wrappers does this.
- **Design:** CleanMyMac's structure. Each module has its own scene with a large glass 3D object, a short description and a round *Scan* button. The palette is neon, inspired by Hotline Miami. The UI stays simple: *Scan → Review → Done*, and the complex parts live in the console and in *Tools*.

## 1. What the Mole CLI can do (v1.59.1, verified in source)

| Command | What it does | Machine output | Interactivity | How Nora drives it |
|---|---|---|---|---|
| `mo clean` | Caches, logs, leftovers of removed apps, Trash; 16 sections | `--dry-run` writes `~/.config/mole/clean-list.txt` (`=== Section ===`, `path  # size, N items`) | sudo prompt Enter/Space (`bin/clean.sh:557`); non-interactive without a TTY | preview → parse clean-list → run in a PTY with a whitelist overlay |
| `mo clean --external PATH` | macOS metadata only, on an external volume | text | — | *Tools → External drive* |
| `mo clean --whitelist` | TUI that protects caches | file `~/.config/mole/whitelist` | TUI | native file editor (§4) |
| `mo uninstall [names…]` | App + LaunchAgents, caches, preferences; Homebrew and Steam | `--list` is JSON when stdout is not a TTY (`name, bundle_id, source, uninstall_name, path, size`) | `Proceed? [y/N]` (`bin/uninstall.sh:2067`); `D` for personal data | list via JSON; removal in a PTY that checks the preview and then answers `y` |
| `--permanent`, `--dry-run` | Skip the Trash / preview | text | — | *Trash / Permanently* switch, *Preview* button |
| `mo optimize` | 20 maintenance tasks with outcomes (applied, unchanged, skipped, unavailable, attention) | text | — | preview and run; exclusions via `~/.config/mole/whitelist_optimize` |
| `MOLE_ENABLE_DISK_VERIFY=1` | Enables the disk verify task | — | — | *Verify disk* switch |
| `mo analyze [PATH]` | Folder sizes, insights (iOS backups, old downloads, Xcode/Docker caches…) | `--json`: **one level** + `large_files`, `scan_status` (complete / partial / unavailable) | the TUI moves files to the Trash | one call per level, cached; deletion via `FileManager.trashItem` |
| `mo status` | Health 0–100, per-core CPU, GPU, memory, disks + I/O, network + history, proxy, battery, thermals, Bluetooth, top processes, zombies, CPU alerts | `--json`; `--watch --interval 1s` streams NDJSON | — | NDJSON stream with tolerant decoding (`process_*` may be absent) |
| `--proc-cpu-threshold/-window/-alerts` | CPU alert thresholds | — | — | notification settings |
| `mo purge` | Build artifacts: `node_modules, target, build, dist, venv, .venv, __pycache__, .gradle…` | `--dry-run` (text) | TUI selection; `--yes` = no questions, eligible items only; `--include-empty` | default set → `--yes`; custom selection → PTY menu driver |
| `mo purge --paths` | Scan roots | file `~/.config/mole/purge_paths` | TUI | native editor |
| `mo installer` | DMG/PKG/ISO/XIP/ZIP in Downloads, Homebrew, iCloud, Mail, Telegram | `--dry-run` (text) | own menu: `a` / `i` / Space / Enter (`bin/installer.sh:620`) | PTY menu driver with on-screen verification |
| `mo history` | Sessions from `operations.log` (`run_id`, `attribution`, removed/trashed/skipped/failed/rebuilt) | `--json --limit N` (≤200) | — | History and charts |
| `mo touchid enable/disable/status` | Touch ID for sudo (`pam_tid`) | text | — | switch in *Tools* |
| `mo update [--force] [--nightly]` | Update (nightly only for script installs) | text | — | update banner + button |
| `mo remove [--dry-run]` | Remove Mole | text | — | Settings (preview first) |
| `mo completion` | Shell completion | — | — | *Tools* |
| `scripts/setup-quick-launchers.sh` | Raycast / Alfred | — | — | *Tools* |
| `MO_NO_OPLOG=1`, `--debug` | Disable the log / verbose logs | — | — | Settings |

Key facts from the source:
- `mo clean` has **no per-item selection**: `--select/--categories/--exclude` were removed (`bin/clean.sh:2116`).
- **Whitelist trap:** while `~/.config/mole/whitelist` does not exist, 13 default protections apply (`lib/core/base.sh:168`: `~/.ollama/models`, Gradle, JetBrains, Playwright, iCloud…). Any written file **replaces** them (`lib/manage/whitelist.sh:206`). Mandatory safety rules (FontRegistry, Spotlight, CloudKit…) are always merged in.
- `clean` and `purge` delete **permanently** (`MOLE_DELETE_MODE=permanent`); `uninstall` uses the Trash.
- sudo is tied to the TTY: `adopt_sudo_session` uses `sudo -n`. Without a TTY, Mole shows its own osascript dialog (`lib/core/sudo.sh:95`).
- `MOLE_PRESELECTED_INDICES` is honoured by `menu_paginated`/`menu_simple` (app selection) but not by the `installer` menu.
- Operations log: `~/Library/Logs/mole/operations.log`.

## 2. Reference wrappers

| | MangelSP/MoleUI | Zhili1004/MoleUI | gokuscraper/mole-gui | caezium/Burrow |
|---|---|---|---|---|
| Stack | SwiftUI, macOS 14, SwiftTerm | Tauri 2 + vanilla JS | Tauri 2 + React 19 | SwiftUI; own Mole-compatible Rust engine |
| Mole | system `mo` | bundled 1.42 | system `mo` | bundled engine |
| Strengths | Menu bar, embedded terminal, threshold notifications, processes/ports/network/fan | clean-list parsing, askpass + PTY, whitelist editors | Smart Care concept, module colours | treemap, SQLite metric history, MCP server, Sparkle, updates tab |
| Flaws | maintenance without selection; process kills without confirmation; one missing JSON field blanks the dashboard; *Abort* does not terminate the process | `uninstall </dev/null` → "Aborted" while the GUI says "removed"; installer removes everything; `csp: null` | checkboxes do nothing; exit codes ignored; stderr breaks JSON; no sudo | direct competitor; name taken |

**We take:**
- from MangelSP: the SwiftUI architecture, SwiftTerm as a fallback terminal, the menu bar and notifications;
- from Zhili: clean-list parsing and the idea of a marker block in the whitelist (fixed for the default-protections trap), askpass in a PTY;
- from gokuscraper: Smart Care;
- from Burrow: long-term metric history, read-only MCP, signed updates, the treemap;
- from CleanMyMac (the screenshots you supplied): the module screen structure, glass 3D objects, the round button, the *Work done!* panel and the *Activity History*.

**We do not take:** bundling Mole, a web stack, "blind" key presses without screen verification, actions without confirmation, `curl | bash` hidden from the user.

### 2.1. Every reference feature and its fate

| Feature (source) | Decision |
|---|---|
| Health, per-core CPU, GPU, memory, disk + SMART, network, battery, thermals (all) | **In Nora**: *System Status*, fed by `mo status --watch` |
| Live CPU/network charts (MangelSP, Zhili) | **In Nora**: sparklines (M1) |
| Long-term metric history from 5 min to 90 days, retention, sampling rate (Burrow) | **In Nora**: SQLite, M5 |
| Sorting and pinning processes (Burrow, MangelSP) | **In Nora**, read-only |
| Killing processes, restarting apps, ports, per-app network (MangelSP) | **Optional** (§4.3), always with confirmation; some MangelSP actions ran without one |
| Fan control Silent/Auto/Full via `pmset` (MangelSP) | **Optional** (§4.3) |
| "Free RAM" via `purge` with admin rights (MangelSP) | **Rejected**: macOS manages memory itself; the effect is short-lived and needs admin rights |
| Dev Junk catalog and `docker system prune -a --volumes`, `simctl`, `brew cleanup`, `npm cache clean`, `gradle --stop` (MangelSP) | Caches are already covered by `mo clean` (*Developer tools* section) and `mo purge`. Separate destructive commands such as `prune --volumes` are **rejected**: they delete data volumes |
| Disk explorer with move to Trash (MangelSP), Disk Map list (Zhili), donut chart (gokuscraper), treemap (Burrow) | **In Nora**: rings + tiles + list + *Move to Trash* |
| Maintenance with flags and a command preview (MangelSP) | **In Nora**: every action shows its command; console |
| Embedded interactive terminal (MangelSP), *Advanced* xterm (Zhili) | **In Nora** as a fallback (personal data in uninstall, manual selection in purge/installer), not as a separate section |
| Threshold notifications for CPU, RAM, disk, temperature (MangelSP) | **In Nora**: CPU via `--proc-cpu-*`, the rest from the status stream |
| Scheduled cleaning with deletion (MangelSP) | **In Nora** only as a scheduled *check* (preview + notification); **automatic deletion rejected** |
| Cat mascot and skins (MangelSP) | **Rejected** for simplicity; the glass objects play the "character" role |
| JSON audit export (MangelSP) | **In Nora**: *History → Export*, M5 |
| Updating Mole via Terminal.app (MangelSP) | **In Nora** natively: `mo update` in the app console |
| Installing `mo` during onboarding (MangelSP, Zhili, gokuscraper) | **In Nora**, one click, with the exact command shown |
| Symlinking a bundled `mo` into `/usr/local/bin` (Zhili) | **Rejected**: Mole is not bundled |
| Whitelist editors for clean, optimize, purge (Zhili) | **In Nora**: *Protection* |
| `mo remove` (Zhili) | **In Nora**: Settings, `--dry-run` first |
| Hotkeys ⌘1…⌘0 (Zhili) | **In Nora**: ⌘1…⌘8 + ⌘K |
| App icons (Zhili, gokuscraper) | **In Nora**: via NSWorkspace |
| Smart Care / Smart Scan (gokuscraper, Zhili) | **In Nora**: *Smart Care* |
| Optimize diagnosis verdict (gokuscraper) | **In Nora** |
| Light/dark theme switch (gokuscraper) | **Rejected**: one neon world |
| Language picker (Zhili, gokuscraper, Burrow) | **Rejected** per requirement: EN/UK/RU chosen automatically (§6) |
| App updates tab: Mac apps + `brew outdated` (Burrow) | **Optional** (§4.3) |
| Activity log (Burrow) | **In Nora**: console + *History* |
| Menu bar HUD (Burrow, MangelSP) | **In Nora** |
| MCP server (Burrow) | **In Nora**, read-only, M5 |
| Local HTTP API (Burrow) | **Rejected** by default: unnecessary network surface; can return as an option |
| Signed Sparkle updates (Burrow) | **In Nora**: M4 |
| Own engine (Burrow) | **Rejected**: Nora works on top of the real Mole |

## 3. Additional open-source references (verified 2026-10-13)

| Project | License | What we take | Code or idea |
|---|---|---|---|
| **MacSai** (iliyami/MacSai) | BSD-3 | CI check of the binary's network surface; separate menu bar target. Its "malware scanner" is ~18 name substrings without any signature database, pre-selected for deletion: **do not take** | ideas; see §4.3 |
| **Radix** (colinvkim/Radix) | MIT | Sunburst / treemap switch, hover inspect, double-click drill-down | code |
| **Stats** (exelban/stats) | MIT | Modular menu bar widgets with charts | code |
| **macmon** (vladkens/macmon) | MIT | CPU/GPU/ANE watts and temperatures without sudo (Apple silicon) | code |
| **PureMac** | MIT | Scheduled cleaning, Xcode/Homebrew cache categories | code |
| **Applite** | MIT | Homebrew Cask grid (app updates) | code |
| **Vortex**, **Inferno**, **Pow** (twostraws, EmergeTools) | MIT | "Dust" particles, Metal refraction and shine shaders, transition effects | code |
| **Lottie** / **Rive runtime** | Apache-2.0 / MIT | Flat animated icons, state machines | code |
| **DSFSparkline**, Swift Charts | MIT / Apple | Sparklines and history charts | code |
| **btop** | Apache-2.0 | Dense block charts | idea |
| **Sniffnet** | MIT/Apache (Rust) | Connection table and filters | idea |
| Pearcleaner | Apache + Commons Clause | Leftover preview, Trash "Sentinel" | idea only |
| Spacie | Non-Commercial | Plugin protocol for categories | idea only |
| GrandPerspective, Neodisk, QDirStat | GPL | Cushion treemap | code allowed (Nora is GPL-3.0) |
| KnockKnock, BlockBlock, Latest | GPL-3.0 | Persistence audit, change alerts, "what's new" in updates | code allowed (Nora is GPL-3.0) |
| Cork | license unverified | Homebrew GUI | idea |

## 4. Coverage matrix

### 4.1. Mole features: all covered

| Mole feature | Nora screen | How the selection is honoured | In prototype |
|---|---|---|---|
| clean preview | Cleanup → Review | `mo clean --dry-run`, parse clean-list.txt | ✅ |
| Per-item selection | Cleanup | **Whitelist overlay:** back up the file → (if none exists) materialise the 13 default protections → `# nora:overlay` block with the unchecked items → run → restore. After a crash, the marker is detected and restored on next launch | ✅ |
| Keep the Trash | Cleanup | `$HOME/.Trash` line in the whitelist | ✅ |
| System caches | Cleanup | `sudo -A -v && mo clean` in one PTY session; without rights the PTY answers Space | ✅ |
| `--external` | Tools | flag | ✅ |
| Cache protection | Protection | native whitelist editor that carries over the defaults | ✅ |
| App list | Applications | `uninstall --list` → JSON | ✅ |
| Removing several apps | Applications | `mo uninstall "A" "B"`; the PTY checks the preview against the selection and answers `y`; any mismatch stops the run | ✅ |
| `--permanent`, `--dry-run` | Applications | flags | ✅ |
| Personal data selection (`D`) | Applications | Phase 1: embedded terminal; phase 2: upstream flag | ✅ (terminal) |
| References in configs | Applications → Done | parse output | ✅ |
| Optimize and its outcomes | Performance | `--dry-run` → list; run → outcome badges | ✅ |
| Task exclusions | Performance / Protection | `whitelist_optimize` | ✅ |
| Disk verify | Performance | `MOLE_ENABLE_DISK_VERIFY=1` | ✅ |
| Analyze, drill-down, insights, partial | Space Map | `analyze --json PATH` per level, cached, `+` for partial sizes | ✅ |
| Large files | Space Map | `large_files` | ✅ |
| External volumes | Space Map | `mo analyze /Volumes/…` | ✅ |
| Move to Trash from analyze | Space Map | `FileManager.trashItem` (reversible) | ✅ (UI) |
| Status with every field | System Status, menu bar | `--watch --interval` NDJSON | ✅ |
| CPU alerts | System Status | `--proc-cpu-*` + system notifications | ✅ |
| Purge (default set) | Projects | `mo purge --yes [--include-empty]` | ✅ |
| Purge (custom selection) | Projects | PTY menu driver: Space/navigation, on-screen list verified before Enter; fallback: terminal | ✅ |
| Purge scan roots | Protection | `purge_paths` file | ✅ |
| Installer (selection) | Installers | PTY menu driver (`a`/`i`/Space/Enter) with verification | ✅ |
| History | History | `history --json --limit 200` | ✅ |
| Touch ID | Tools / Settings | `mo touchid enable/disable/status` | ✅ |
| Update / nightly | Tools, banner | `mo update` | ✅ |
| Remove | Settings | `--dry-run` first | ✅ |
| Completion, Raycast/Alfred | Tools | commands | ✅ |
| `--debug`, `MO_NO_OPLOG` | Settings | environment variables | ✅ |

### 4.2. Added on top of the CLI (GUI only)

One-click Mole installation and automatic Mole updates (through the install channel); Nora self-updates (Sparkle 2, signed feed on GitHub Releases); the menu bar quick menu; *Smart Care*: four checks, then *Run* = `clean` + `purge --yes` + `installer`. Also: ⌘K, a console with the exact command and *Copy*, *Activity History* with charts and recommendations, scheduled checks (preview + notification only), onboarding (CLI install, Full Disk Access), CLI version and capability checks, read-only MCP server, three UI languages (§6).

### 4.3. Beyond Mole (optional, needs your decision)

Ports, processes, per-app network, fan control (as in MangelSP); app updates via Homebrew (Burrow, Applite); Apple silicon power draw (macmon).

**Security module** (now planned for M5; recommended approach after analysing MacSai):
- read-only persistence audit: LaunchAgents/LaunchDaemons, Login Items, browser extensions;
- for every item, check the code signature, Gatekeeper status and notarization via `Security.framework` (`SecStaticCodeCheckValidity`, `SecAssessment`) and explain each finding;
- Apple's own rules from the local `XProtect.yara` via `yara` (without redistributing them) and the ClamAV engine as an external `clamd`/`clamscan` (GPLv2 stays outside the app), installed and updated on request;
- findings are never pre-selected; a loaded agent is unloaded (`launchctl bootout`) before its file is moved to quarantine or the Trash, after confirmation;
- no "antivirus" marketing and no real-time protection claims.

### 4.4. Security module design (ClamAV + Apple XProtect + native audit)

Researched on 2026-10-13. Every item marked *verify* is tested in the M5 spike before release.

- **Positioning.** On-demand scan, **no real-time protection** (ClamAV's on-access scanner is Linux-only). The UI says "signals to review", never "virus-free" or "protected". Findings are never pre-selected.
- **Pipeline:**
  1. **Native audit.** LaunchAgents/LaunchDaemons, login and background items (BTM), configuration profiles and browser extensions. Code signature via `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures`, notarization via `spctl -a -vv` (`source=Notarized Developer ID`), quarantine xattr. Every finding carries a reason.
  2. **Apple XProtect rules.** `yara` 4.5.8 (BSD-3) runs against the local `XProtect.yara` (≈1 MB, 506 rules), which is read at runtime and never copied or bundled. *Verify* that it compiles with stock yara.
  3. **ClamAV 1.5.4** (GPLv2, Homebrew; the formula also installs yara). During a scan session Nora starts `clamd --foreground` as a child process, scans with `clamdscan --fdpass` and stops it afterwards, so no resident process holds 1.2 GiB or more of RAM. `freshclam` runs at most once a day, with a manual *Update now* and back-off on HTTP 429. The databases are about 107 MB (main 85 MiB, daily 22 MiB). Nora keeps its own configs in `~/Library/Application Support/Nora/clamav`. *Verify* that the child inherits Full Disk Access.
  4. **Optional hash reputation.** Opt-in, SHA-256 only, and only for files that already have a finding: CIRCL hashlookup suppresses known-good files, and MalwareBazaar or VirusTotal work with the user's own key.
- **Scopes.** *Quick* covers launch items, BTM targets, `/Applications`, Downloads and Desktop. *Full* covers `$HOME`, excluding iCloud/CloudStorage placeholders, and reports how many items were skipped.
- **Quarantine.** `~/Library/Application Support/Nora/Quarantine/<uuid>/` holds the file and a `meta.json` (SHA-256, original path, owner, mode, xattrs, rule or detection name). Restore takes one click; permanent deletion is a separate, confirmed action. A loaded agent is unloaded first (`launchctl bootout gui/$UID/<label>`). Apple-signed items, `/System` and `/usr` are never touched.
- **Licensing.** Never link `libclamav`; run ClamAV only as separate processes. Do not bundle the ClamAV databases, XProtect rules or Elastic-licensed rules. Third-party rule sets (signature-base DRL-1.1, YARA Forge packages) stay out until their per-rule licenses are verified.
- **Not doing.** No name-substring "signatures" (the MacSai pattern), no auto-remediation, no automatic uploads of files, no API keys embedded in the app.

## 5. Architecture

```
Nora.app (SwiftUI, macOS 14+)
├─ Scenes: main window · status item (NSStatusItem + NSPopover) · Settings
├─ Features: SmartCare, Clean, Apps, Speed, SpaceMap, Status, Projects, Installers, Protect, History, Tools, Security
└─ MoleKit (Swift package, no UI)
   ├─ Locator          zsh -lc 'command -v mo', /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.mole/mo, Nix; manual path
   ├─ Capabilities     --version + `<cmd> --help` → flag map; minimum 1.55
   ├─ ProcessRunner    pipe mode: separate stdout/stderr, exit codes, SIGINT → SIGTERM
   ├─ NDJSONStream     status --watch; tolerant Decodable
   ├─ PTYSession       forkpty; ANSI strip; PromptResponder (rules + expected-screen verification)
   ├─ Parsers          clean-list, optimize, purge, installer; golden fixtures per Mole version
   ├─ WhitelistOverlay transaction + journal + crash recovery
   ├─ PrivilegeBroker  SUDO_ASKPASS helper with a native dialog / Touch ID; the password is never stored
   ├─ MoleInstaller    brew install mole, or the official install.sh at a pinned version with checksum → ~/.local/bin
   ├─ MoleUpdater      compares mo --version with GitHub Releases; updates through the install channel
   ├─ HistoryStore     SQLite: metric samples + parsed Mole history
   └─ Scheduler        SMAppService/launchd: preview-only checks
```

Safety invariants:
1. No destructive action without a review and a confirmation.
2. The PTY answers "yes" only after the preview matches the selection.
3. The whitelist always returns to its original state.
4. The exact command is visible before every action.
5. Exit codes and stderr are never lost.

Tests: parser tests on fixtures recorded from real runs (CI matrix with `brew install mole`), integration tests in a separate `$HOME`, UI snapshot tests.

## 6. Design system

- **Module scenes** (neon, Hotline Miami): Smart Care magenta → violet; Cleanup green; Applications cyan → blue; Performance sunset; Space Map ultraviolet; Status pink → indigo; Tools and History night violet; Security crimson. Colours morph between sections. Barely visible VHS lines and a light "horizon" behind the button.
- **Glass 3D objects**, one per module, in three states (*idle / working / done*):
  - disk: a "vessel" with layers of used space and amber dust showing what can be removed;
  - cleanup: a sparkle;
  - applications: a tile;
  - performance: a lightning bolt;
  - space map: a 3D sunburst;
  - status: a torus with a neon filament that pulses with the CPU;
  - projects, installers, protection, history, settings: matching symbols.
- **Assets:** the final art is generated with an image model under one style guide (frosted tinted glass, matte white inner symbols, hot-pink and cyan rim light), and the background is converted to alpha. Sources live in `Design/Glass/`.
- **Natively** the objects animate in SwiftUI: float, pointer tilt, a glow while working and a pop on completion. The animation phase never resets on re-render. Inferno (refraction, shine) and Vortex (particles) add to this; UI chrome uses `glassEffect` on macOS 26 with a `Material` fallback.
- **App icon:** neon squircle (magenta → violet → cyan) with the glass disk vessel; sources in `Design/AppIcon/` (`AppIcon-1024.png`, `Nora.icns`).
- **Menu bar** (based on MangelSP, Burrow and Stats; Zhili and gokuscraper have no menu bar):
  - implementation: `NSStatusItem` + `NSPopover` with SwiftUI via `NSHostingController`, not `MenuBarExtra` (no right-click, no programmatic open, no composed images, and on macOS 26 with the `.accessory` policy the item can disappear); an anchor window for auto-hiding menu bars (Burrow's technique);
  - item modes: icon only · icon + CPU · mini chart · up to three metrics (value / bar / sparkline / speed) coloured by thresholds; the image is drawn into an `NSImage` and redrawn only when the value changes;
  - quick menu: health + Mole's verdict, 6 tiles (CPU, memory, network, disk, GPU, fan) with 120-point sparklines, battery and temperature, top processes and CPU alerts (only while open), reclaimable space + *Clean* / *Optimize*, jumps to 6 sections, Mole version and update, *Open Nora*, *Quit*;
  - right-click: a short menu (open, sections, pause updates, settings, quit); global hotkey ⌥⌘N (Carbon `RegisterEventHotKey`, no dependencies); launch at login via `SMAppService.mainApp`; `.accessory` policy, `.regular` while the window is open;
  - data: one actor reads `mo status --watch --interval 1s` (NDJSON) for both the window and the menu bar; when nothing is visible the interval grows and processes are not read; last values are persisted for an instant first paint; `toolTip`/accessibility labels; respects *Reduce motion*.
- **Typography:** large light headings in SF Pro Display (Onest on other systems), body in SF Pro Text, figures in SF Pro Rounded, code in JetBrains Mono. Buttons: a glossy white primary button, frosted-glass secondary buttons and a glossy pink button for destructive actions; the round *Scan* button is a glass orb with a specular highlight.
- **Languages:** English, Ukrainian and Russian. The language follows the system (`Bundle.preferredLocalizations` among `en`/`uk`/`ru`); any other system language falls back to English. There is no in-app language picker; macOS's per-app language setting (*System Settings → General → Language & Region → Applications*) works on its own. Strings live in a String Catalog (`.xcstrings`), sizes and numbers use `ByteCountFormatter`/`Measurement`, with correct plural forms for uk/ru. The prototype is shown in Ukrainian; English and Russian copy is produced in M3.
- **Simplicity:** a module screen has 3–4 bullets and one button. Dense data appears only in review. The console stays closed until opened.

## 7. Prototype

`prototype/index.html` + `app.js` + `assets/glass/`. Online: https://lexus2016.github.io/Nora/prototype/. Locally: `cd prototype && python3 -m http.server 8000` → http://localhost:8000.
- All 12 screens and complete flows (scan → review → run → *Work done!*) for Smart Care, Cleanup, Applications, Performance, Projects, Installers and Security.
- *Scenarios* in the top bar: Mole missing / outdated, no Full Disk Access, an active sudo session.

## 8. Milestones

| Stage | What we build | Done when |
|---|---|---|
| **M0 Spike** | PTY driver for uninstall/installer/purge on real Mole; whitelist overlay with recovery; `sudo -A` in a PTY; fixtures | Removing 2 of 5 installers passes with verification; the whitelist is restored after `kill -9` |
| **M1 Read-only** | MoleKit, System Status (NDJSON), Space Map, History, menu bar | Works with 1.55–1.60; missing fields never break the UI |
| **M2 Cleaning** | Cleanup, Applications, Projects, Installers, Performance, Protection | Every checkbox is honoured; e2e in a sandbox `$HOME` |
| **M3 Look & feel** | Neon system, premium 3D assets, Smart Care, ⌘K, onboarding, EN/RU copy | All 3D loops together ≤ 40 MB; 60 fps on M1 |
| **M4 Release** | Developer ID, notarization, Sparkle, EN/UK/RU localization | Signed DMG; updates work; the language follows the system |
| **M5 Extras** | Security module, scheduler, MCP, beyond-Mole modules (by decision) | — |

## 9. Decisions

1. ~~Name~~ — **Nora**, approved.
2. **License:** **GPL-3.0** chosen (allows reusing both MIT and GPL code; aligned with Mole). Can still change before the first release.
3. **Minimum macOS:** 14+ (recommended) or 26 only (full Liquid Glass).
4. **3D:** AI-generated premium art with a strict style guide and/or Blender renders; live RealityKit later.
5. **Upstream PR to Mole:** `--json` for dry-runs of clean/purge/installer/optimize and a path-selection flag. This would remove the PTY driver. Opening the PR is your call.
6. **Beyond-Mole modules** (§4.3): which ones to include.
7. **Signing and notarization:** a DMG without Gatekeeper warnings needs an Apple Developer ID ($99/year). Without it, the DMG is ad-hoc signed and opens via *Open* in the context menu.

## 10. Risks

- **CLI drift:** text parsers break with new versions. Mitigation: capability probing, golden fixtures, CI against the current Mole, upstream JSON.
- **PTY driver** is brittle. Mitigation: on-screen verification before confirming, fallback embedded terminal.
- **Competitors:** mole.fit (official, $19) and Burrow (free, MIT). Our edge: honest selection, a neon 3D design and full CLI coverage without our own engine.
- **Permissions:** Full Disk Access, notarization, the askpass helper (signed, minimal).
