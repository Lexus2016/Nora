# Nora icon and motion inventory — 2026-10-17

## Evidence and scope

This is a source-backed inventory and native **before** image review, not a new native execution or a performance benchmark.

- Source-before reference: `60679b3fdbdb93c2ae2070b123e27f20b23ae141`. Source names below refer to that revision unless explicitly marked as follow-up. Shared motion components were being edited separately during this audit; the before findings do not certify or reject the final patch.
- Native-before evidence: [Actions run 39047238038](https://github.com/Lexus2016/Nora/actions/runs/39047238038), commit `6a948521b883e616322f2c3e7942a62640c02a44`. The retained run receipt records successful native tests. That success applies to that earlier commit, not to the new motion patch.
- The inspected named export is `run4/build/visual-smoke/NoraTests/named/`. It contains 132 PNGs: 97 at 1240×900, 20 at 1040×720, 12 at 640×580, and 3 at 1040×240. Main-scene filenames say 1240×800 or 1040×620 because the snapshot harness adds 100 points below the scene to show the child-window action orb. That dark lower band is deliberate fixture space.
- All 12 module start screenshots were inspected at both default and minimum sizes. Additional review covered working/review/list states, Status cards, all four English Settings contents, and the shared navigation/action surfaces visible in those images. The remaining exported filenames establish available coverage, not an assertion that every pixel or locale was approved in this pass.
- `MenuVisualSmokeTests` uses off-screen `NSHostingView` rendering with synthetic models and disabled hit-testing. It does not press buttons or execute the illustrated operations. A single PNG cannot establish smoothness, loop timing, hover behavior, animation stopping, frame pacing, input responsiveness, or VoiceOver behavior.
- The checkout contains the resource catalogs and app-icon recipe but not the original glass WebP files or app-icon PNGs. The native-before screenshots visibly contain real glass artwork. This is a local asset-inspection gap, **not evidence that Nora's shipped raster artwork is broken or missing**. Native image metadata, original alpha edges, source dimensions, compressed size, and decode cost remain unmeasured.

Source anchors: [Module.swift](../../App/Nora/Core/Module.swift), [Glass3D.swift](../../App/Nora/Design/Glass3D.swift), [Flow.swift](../../App/Nora/Design/Flow.swift), [Components.swift](../../App/Nora/Design/Components.swift), [MenuVisualSmokeTests.swift](../../App/NoraTests/MenuVisualSmokeTests.swift).

## All-module hero and navigation inventory

`Module.symbol` is the single semantic SF Symbol source used by the rail, rail hover card, menu-bar navigation, and module references. `Module.glass` names a separate glass image. These are intentionally two visual treatments of a related subject; the artwork is not literally an SF Symbol rasterization.

The eight scan-start modules share `ModuleStart`: a 340-point glass slot, source-before idle swing of ±9° with a 7-second horizontal period, feature discs, and the bottom Scan orb. Their `WorkingView` uses a 300-point slot with the default ±26°/3.2-second motion. `DoneView` uses a static 230-point `GlassImage`; `StepHeader` uses a static 64-point image. Specialized layouts are identified below.

| Module | Rail/menu SF Symbol | Glass key | Native-before appearance and use |
|---|---|---|---|
| System Status | `waveform.path.ecg` | `status` | Compact pink/cyan circular waveform medallion in a static 120-point header, not a 340-point scan hero. Present at both sizes; a separate score ring sits at the right. |
| Smart Care | `flask` | `vessel` | Rounded transparent flask with colored liquid bands. Scan-start hero present at both sizes. Review/working tiles reuse Cleanup, Performance, Projects, and Installers artwork in 230-point slots; only a working tile requests ±26° motion. |
| Cleanup | `trash` | `clean` | Green glass lidded bin. Complete hero visible at both sizes. The working screen keeps the bin above “Cleaning…”; the result/category decoration reuses it. This is the cleanup module image, not the upcoming folded-paper Trash character. |
| Applications | `square.grid.2x2` | `apps` | Four cyan/blue glass tiles with white circle, triangle, square, and star marks. Present at both sizes. Full app list has a static 72-point header image; app rows separately use macOS file/app icons. |
| Performance | `bolt` | `optimize` | Amber glass lightning bolt. Present at both sizes. Review uses a large category-card decoration; diagnosis and smaller cards use SF Symbols. |
| Space Map | `chart.pie` | `analyze` | Purple segmented circular storage object. Present at both sizes. Review moves to filesystem icons and data-driven bubbles rather than retaining the large hero. |
| Projects | `chevron.left.forwardslash.chevron.right` | `purge` | Amber/pink stacked code tiles with a white code mark. Present at both sizes. The stacked geometry is part of the artwork; it is not, by itself, proof of accidental duplicate motion layers. |
| Installers | `shippingbox` | `installer` | Cyan transparent parcel with a downward white arrow. Present at both sizes. Working and result screens reuse the same module image. |
| Protection | `checkmark.shield` | `protect` | Compact green glass shield with checkmark. Static 110-point `Glass3D(amplitude: 0)` header at both sizes, above the three configuration tabs. No large scan-start hero is expected. |
| Security | `lock.shield` | `security` | Pink glass shield/keyhole with cyan/pink orbit lines. Present at both sizes. The minimum-size image shows the lower setup area behind the scroll viewport; scrolling and focus visibility require an interactive check. Orbit lines belong to the source art, not a runtime particle effect. |
| History | `clock.arrow.circlepath` | `history` | The key exists in `Module`, but `HistoryView` renders “Activity History” and dashboard cards with **no glass hero**. Both native sizes confirm this. There is no missing-image fallback visible here; a History hero is simply not used by this view. |
| Tools | `wrench.and.screwdriver` | `tools` | Compact crossed glass tools in a static 110-point `Glass3D(amplitude: 0)` header. Both sizes show it above action cards. Lower cards are below the scroll viewport at minimum size. |

Evidence filenames: `{module}-start-1240x800-en.png` and `{module}-start-1040x620-en.png` for each raw module name in the table (`smartCare`, `spaceMap`, and `status` use those exact camel-case/raw names).

### Shared glass consumers outside the start screen

- `CategoryCard`: static 250-point `GlassImage`, offset −56 horizontally / +64 vertically and clipped by the card. Partial art in a corner is intentional in this component; check that it never reduces action-label contrast.
- Smart Care tile: 230-point `Glass3D`, offset +50/−40 and clipped to the tile. `smartCare-review-en.png` and `smartCare-running-en.png` show intentionally cropped tile artwork. The foreground remains the task name/status/action.
- `DoneView`: static 230-point art plus textual outcome; failure changes glow, but error text and failure markers carry the result.
- `StepHeader`: static 64-point art. Applications' specialized list header uses 72 points instead.
- Onboarding: static `vessel` image at 280 points. No onboarding PNG is present in the provided named set, so this use is source-reviewed only.
- `GlassImage` and `Glass3D` hide decorative images from accessibility. The module title and actionable controls must remain the accessible content.
- `GlassLibrary` caches successful image loads by name. Missing loads return `nil`; fallback is `circle.hexagongrid`. No fallback was observed in the reviewed glass hero screenshots. Source caching does not establish actual decoding frequency or memory cost.

## Sidebar, toolbar, settings, and action surfaces

### Sidebar and navigation

[RootView.swift](../../App/Nora/Shell/RootView.swift): 84-point rail; 21-point medium-weight module SF Symbols, 56-point-wide hit frames, adaptive row heights from 32 to 52 points. Selection uses a rounded illuminated background and the selected accessibility trait. Settings uses `gearshape` at 19 points in a 56×50-point frame. All 12 module marks plus Settings are visible at the two tested heights.

The hover card reuses `Module.symbol` in a 32-point `FeatureDisc`, with title and summary. It appears after a 350 ms task delay and has a 0.16-second fade/offset transition in the source-before implementation. There are no hover-card PNGs or focus-state captures in the provided set.

A busy module gets a 16-point `BusyRing`: dark chip, faint track, white arc. `smartCare-running-en.png` visibly shows busy badges on Smart Care and Cleanup, consistent with a composite operation and its active step. The badge must not be described as an extra module or error. A native accessibility pass is still required for an explicit busy-state announcement.

Top bar: `arrow.counterclockwise` for Start over, `chevron.left` for Back/return to Smart Care, and `terminal` for the 30×26-point console control. Space Map additionally uses 26×26-point Back/Forward controls, breadcrumb chevrons and native filesystem icons. Console uses `terminal` and `doc.on.doc`; the exported current/history/paused console PNGs are available. Icon-only controls need actual keyboard focus/VoiceOver verification; a tooltip in source is not equivalent to that verification.

### Settings and macOS menu bar

[SettingsView.swift](../../App/Nora/Features/Settings/SettingsView.swift) declares four tab symbols: General `gearshape`, Mole `terminal`, Security `Module.security.symbol` (`lock.shield`), and Updates `arrow.triangle.2.circlepath`. English native captures show their contents, but the off-screen Settings export does not show a usable native tab/title toolbar. The current PNGs therefore cannot approve the Settings toolbar icons, selected-tab states, label truncation, or keyboard tab switching. Twelve content PNGs exist across en/uk/ru; a real Settings window capture is still needed for the toolbar.

[MenuBar.swift](../../App/Nora/MenuBar/MenuBar.swift): the menu-bar item uses `sparkles` with the accessibility description “Nora.” Optional CPU/memory text and temperature dot are data indicators. The right-click menu reuses all 12 module symbols; QuickMenu reuses the first eight modules at 14 points in 34×30-point controls and has a `macwindow` open-main button. No actual NSStatusItem, right-click menu, or QuickMenu screenshot is in this 132-image set. This is a coverage gap, not an observed rendering defect.

The macOS app/Dock icon catalog names the normal 16/32/128/256/512-point 1×/2× outputs. [Design/AppIcon/render.swift](../../Design/AppIcon/render.swift) describes the vessel-on-white-tile recipe. Source PNGs and Dock/Finder screenshots were not available for an edge/size audit.

### Feature and action symbol families

`FeatureDisc` draws a circular radial-gradient field, white SF Symbol, border, and soft shadow. Default diameter is 34 points; the symbol uses `size × 0.42` at semibold weight. Category discs use 44 points, Tools cards 40, and rail hover cards 32. These are static pictograms in the source-before code.

| Surface | Source-backed symbol family |
|---|---|
| Smart Care bullets | Module symbols for Cleanup, Performance, Projects, Installers |
| Cleanup bullets | `archivebox`, `globe`, `hammer`, `puzzlepiece` |
| Cleanup section cards | `person.crop.circle`, `square.stack.3d.up`, `globe`, `hammer`, `app.badge`, `folder`, `icloud`, `puzzlepiece`, `server.rack`, `gearshape.2`; unknown-section fallback `sparkles` |
| Applications | `xmark.app`, `arrow.triangle.2.circlepath`, `moon.zzz`, `chart.bar`, plus Installers' module symbol |
| Performance | `magnifyingglass`, `network`, `person.badge.key`, `stethoscope`, and warning triangle |
| Space Map | `circle.hexagongrid`, `folder`, `doc.richtext`; `internaldrive`, `externaldrive`, `house` for scope |
| Projects | `square.stack.3d.up`, code chevrons, `clock` |
| Installers | `arrow.down.circle`, `mug`, `icloud` |
| Security | `gearshape.2`, `shield.lefthalf.filled`, `ladybug`, `arrow.uturn.backward.circle`, `tray.full` |
| Tools | `touchid`, `arrow.triangle.2.circlepath`, `externaldrive`, `terminal`, `xmark.app` |
| Protection rows | Module symbol for a custom item, `lock` for protected/built-in items, `minus.circle` for removal |
| Notices/restrictions | `exclamationmark.circle`, `exclamationmark.triangle`, `exclamationmark.shield`, `info.circle`, `lock`, `hand.raised`, `icloud.slash`, `eye.slash`, `arrow.down.circle` |

The primary orb is text-led, not an icon-only button. Source-before `BottomOrb` has a 1.03 hover scale and 0.18-second easing; busy state adds a white arc (1.4-second rotation period) and a faint track. Destructive actions use the pink palette, and disabled actions retain text with reduced opacity and an explanatory reason. `PrimaryButtonStyle` has a 0.97 press scale/0.15-second easing; `DestructiveButtonStyle` has a 0.97 press scale. `OrbButton` is a separate older 132-point component with its own hover/ProgressView behavior; source review found no production call site outside its declaration. It should not be counted as a second live orb in these screenshots.

macOS file/app icons come from `NSWorkspace.shared.icon(forFile:)`: 30-point app rows, 28-point removal-plan rows, 18-point menu process rows, Space Map 16-point breadcrumbs / 44-point current item / 26-point rows / bubble icons capped at 92 points. Generic document icons in synthetic fixtures are expected when those fixture paths do not correspond to installed apps or real folders; they do not demonstrate a broken real-app icon lookup.

## Status indicators and motion source limits

[StatusView.swift](../../App/Nora/Features/Status/StatusView.swift) uses static 11-point card-caption SF Symbols: `cpu`, `memorychip`, `internaldrive`, `network`, `battery.75percent`, `bolt`, `thermometer.medium`, `leaf`, `arrow.up.arrow.down`, `point.3.connected.trianglepath.dotted`, `list.bullet`, `dot.radiowaves.left.and.right`. Transfer direction uses `arrow.down`/`arrow.up`; a hot-process warning uses `flame`.

`status-review-en.png` visibly covers the 120-point header art, score ring, CPU/memory/disk/network/power/temperature/energy/traffic/port cards, and three small loading arcs. Conditional battery, Bluetooth, process-warning, and all hardware-specific states are not established by that one fixture. The score and health wording are separate from color. Meters and sparklines are data-driven shapes, not decorative hero loops.

The following are **source-before configured bounds**, not measured frame rates or renderer draw calls:

| Component | Configured behavior | Important before limitation |
|---|---|---|
| Idle `Glass3D` | `minimumInterval = 1/24 s`; ±9°/7 s at module start; ±5° tilt and ±6 pt lift on related sine periods | Idle oscillates indefinitely while active/visible. Inactive idle is paused, but its static phase is not a completion gesture. |
| Busy `Glass3D` | `minimumInterval = 1/30 s`; ±26°/3.2 s by default; 12 side-wall image copies at amplitude ≥15°; 6% size depth | Inactive-window pause was limited to amplitude <15°, so a visible inactive busy hero could continue. Twelve copies are view layers, not twelve measured GPU draw calls. |
| Glass shadows/highlight | Two separate static shadow images; glow blur `0.12 × size`, dark blur `0.07 × size`; masked moving highlight; `drawingGroup()` | Source decomposition can reduce repeated work, but no GPU, off-screen-texture, memory, or power savings have been measured here. |
| Reduce Motion / invisible glass | Source-before selects a still frame when Reduce Motion, amplitude 0, or window not visible | Busy amplitude still selected the 12-layer geometry in the still branch. No animated timing is proved by a screenshot. |
| Shared `Spinning` | `minimumInterval = 1/30 s`; pauses when not visible; Reduce Motion returns unrotated content | There was no inactive-window gate in this modifier. Busy ring remains visible under Reduce Motion, but does not rotate. |
| Spinner consumers | Small spinner 14 pt / 0.8 s; rail busy arc 0.9 s; primary busy arc 1.4 s | Multiple simultaneous consumers have separate timelines; there is no measured aggregate frame/CPU budget. |
| Health ring | Score change easing 0.6 s; no infinite loop | Source-before did not consult Reduce Motion or active state. |
| Transitions and hover | Scene palette 0.45 s; module/console 0.22 s; rail selection 0.2 s; tooltip 0.16 s; orb hover 0.18/0.2 s; child-orb spring response 0.35 s | Source-before finite animations were not consistently gated for Reduce Motion/inactive state. |
| Smart Care and Space Map | Working-state ease 0.3 s; bubble-layout spring response 0.5 s; bubble hover ease 0.15 s | Finite/data-driven movement, but still needs reduced-motion and interruption checks. |
| Native progress/popover | `ProgressView` is used on selected loading/setup paths; `NSPopover.animates = true` | Native system behavior is distinct from the custom `Spinning` modifier. Do not claim a shared-policy change automatically covers every native animation. |
| Live data | Visible-window viewer retains/releases the stream; menu-bar refresh timer 2 s when required; QuickMenu task reads at 3 s intervals while mounted | These are data schedules, not decorative FPS. Stopping hero motion must not silently stop an authorized background operation or requested menu-bar metrics. |

The historical comments mentioning roughly 38% of a CPU core for an old spinner or roughly 13% main-thread cost for hidden Status are prior implementation notes. This audit did not reproduce those measurements and does not use them as current results.

## Native-before visual observations

1. The glass family is visually coherent across the inspected start scenes: transparent colored materials, bright rim/specular highlights, and a module-specific scene glow. All eleven actually-used module/header artworks render recognizable objects. History is intentionally text/dashboard-led in the inspected source.
2. Rail marks remain simpler than hero art and are present at minimum size. Protection and Security are both shield-family marks; their checkmark/keyhole interiors and labels help distinguish them, but real hover, keyboard, and accessibility testing is still needed.
3. Start heroes keep their own broad column in the inspected English views. The small-window Security/setup and Tools/History dashboard states require scrolling; the exported viewport does not prove that off-screen controls can be reached or focused correctly.
4. Smart Care and large result cards intentionally crop decorative artwork at their corners. The reviewed working image preserves visible task states and text. Intermediate rotation phases could change overlap or edge quality and are not covered by one native image.
5. The native working images show the expected content plus a busy ring and Stop text. They do not prove that the ring moved, that work really ran, or that Stop cancels anything.
6. No real Settings tab toolbar, menu-bar item, quick menu, hover tooltip, or Trash mascot panel is included in this named baseline. Those surfaces need separate evidence rather than extrapolation from a module screenshot.

## Approved upcoming Trash character

This is an approved bounded UI specification, not an assertion that the baseline already implements it:

- Panel stays **520×260 points**.
- Decorative character is restricted to the **76-point mascot slot**. Do not expand the panel or move important copy/actions to make room for it.
- Use a small folded-paper character that peeks out, waves **twice**, then rests.
- Reduce Motion presents a static character immediately.
- No infinite loop. Dismissal, disappearance, or app/window inactivity must not leave an orphaned animation task running. Returning to a settled state must not accidentally restart a perpetual sequence.
- Keep confirmation text, item count, cancellation and destructive-action meaning independent of the character. The character is decoration, not confirmation that a Trash operation succeeded.

Existing Cleanup bin art, Installer/Space Map “move to Trash” copy, and Applications deletion choices do not constitute a screenshot of this panel. No corresponding 520×260 panel or character was observed in the supplied before images. Integration and target route should be verified in the implementation branch before it is described as delivered.

## Verification checklist for the final patch

### Source and native build

- [x] Inventory all 12 module mappings and their actual consumers; inspect native default/minimum start images.
- [x] Record the before evidence commit separately from the source-before revision.
- [x] Identify source limits without presenting them as measured performance.
- [ ] Build and run the native test suite on the final exact commit. Record run URL/SHA and passed, skipped, failed, or never-run stages.
- [ ] Confirm all 12 named glass assets resolve in the built bundle, inspect the real artwork dimensions/alpha, and test deliberate missing-asset fallback separately.
- [ ] Check the app icon at each declared size and in Dock/Finder; verify every SF Symbol on the minimum supported macOS release.
- [ ] Capture final heroes and shared cards with the new motion policy at reproducible phase points. Compare the real art, not just fallback symbols.

### Motion, interaction, and accessibility

- [ ] Observe at least a complete idle/busy cycle on an active window, then an inactive-but-visible window, minimized/fully covered window, another Space, and restored window. Verify policy boundaries without relying solely on source flags.
- [ ] Toggle Reduce Motion before mounting and while a hero/spinner/hover transition is active. Confirm useful still art, readable status, and no continuing decorative timeline/task.
- [ ] Switch modules repeatedly and rapidly; dismiss/reopen console and orb-bearing views; interrupt motion mid-cycle. Check stale callbacks, observer cleanup, stranded state, and input responsiveness.
- [ ] Inspect actual native Settings tabs, menu-bar icon/text styles, right-click module list, QuickMenu, tooltip, focus, and disabled/error actions. Current fixture content PNGs are insufficient for these surfaces.
- [ ] Test VoiceOver labels/selected state and busy-state communication, keyboard traversal, and icon-only actions. Test readability without relying on color or motion alone.
- [ ] Capture the Trash panel at rest, peek, both waves, settled state, and Reduce Motion. Assert the 520×260 panel/76-point slot geometry; inspect long/localized copy and destructive-action focus. Verify bounded completion and task cancellation after dismissal.

### Performance evidence still required

- [ ] Profile the same final build on a named Mac/macOS/display configuration with stable workload: idle start hero, busy fixture, Smart Care with concurrent busy indicators, Status loading cards, and Trash before/after settlement.
- [ ] Record frame pacing/hitches, CPU/main-thread time, GPU/off-screen rendering where available, memory allocations/texture sizes, and energy impact. Compare active, inactive, covered/minimized, and Reduce Motion states over equivalent observation windows.
- [ ] Separate data polling/process work from decorative rendering. Attribute any claimed improvement to an actual trace and baseline; configured 24/30 Hz intervals and fewer image copies are not a benchmark.

No new native tests, runtime measurements, real Trash operation, or production action was executed by this documentation pass. Final shared-motion implementation and native verification are reported separately.

## Follow-up implementation addendum — source inspected, native acceptance pending

The coordinated shared-component patch was inspected after the before inventory. It retains the original named glass artwork and adds these source-level constraints:

- `DecorativeMotion.isAllowed` requires Reduce Motion off, non-inactive control state, and visibility. `Glass3D` and `Spinning` remove their timelines entirely when this gate fails. Functional labels/tracks remain visible.
- `GlassMotion` requests at most 24 updates per second, limits yaw to 18°, tilt to 1.6°, and lift to 1.8 points, and imposes a minimum 4.8-second period. Busy glass has six tinted silhouette side layers instead of twelve bright artwork copies; idle glass has no additional side layers. Static glow/shadows remain outside the timeline. These are testable source budgets, not measured runtime savings.
- `FeatureDisc` receives a more defined rim and contact shadow. `BottomOrb` receives a clearer rim/contact shadow and a gated 2% hover scale. The finite-motion gate also covers the shared button styles, MainView/Rail transitions, child-orb spring, HealthRing, Smart Care tiles, and Space Map layout/hover transitions. Native `ProgressView`/popover behavior still requires its own check.
- [TrashMascot.swift](../../App/Nora/Design/TrashMascot.swift) provides a decorative, non-hit-testing folded-paper visitor peeking from a small basket, defaulting to the 76-point slot. Its finite arm-angle sequence is −18°, +18°, −18°, +18°, then 0°, totaling 0.90 seconds. A view task settles on completion/cancellation; Reduce Motion/inactive/hidden state uses the static pose. This establishes the component source, not the actual panel integration or observed animation timing.
- [IconMotionRegressionTests.swift](../../App/NoraTests/IconMotionRegressionTests.swift) adds six policy/geometry/finite-wave tests. [IconMotionVisualTests.swift](../../App/NoraTests/IconMotionVisualTests.swift) adds deterministic module-art phase boards, actual-size feature-disc/Stop-orb boards, and rest/wave/Reduce Motion mascot boards. DEBUG fixed-pose controls deliberately bypass live scheduling for repeatable screenshots. A component board is not a production panel screenshot or lifecycle test.
- A separate Space Map completion correction marks a result failed when `trashFailures` is nonempty, so partial failure cannot be presented with a success-oriented completion heading. Its requested functional scope and native verification are tracked with the main remediation work.

Local source/whitespace checks and localization validation were reported successful by the implementation owner (830 keys, zero localization problems). This documentation pass checked its own whitespace and relative source links. Native compilation, new test execution, final PNG inspection, actual panel geometry, and CPU/GPU/energy measurements remain pending; the earlier native-before run must not be reused as acceptance for this patch.
