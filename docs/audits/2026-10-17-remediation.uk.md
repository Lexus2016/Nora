# Nora: повторний аудит і виправлення, 17.10.2026

База: `main` / `915fc32e87b6b6040366ef39bde0da80dcdac47a` (повторно звірено через GitHub).

## Статус

Підтверджені дефекти U1–U8, C01–C06 та F1–F5 отримали зміни коду й синтетичні регресійні тести. F6 розділено на конкретні виправлення postcondition та залишкові межі зовнішнього backend. Це **не твердження про повну готовність релізу**: нативна перевірка та архітектурні обмеження нижче лишаються окремими воротами приймання.

Політики permanent delete/Trash не змінено. Remove Mole залишається preview-only і тепер прямо це пояснює. Реальні файли користувача не очищалися, програми не встановлювалися й системні налаштування не змінювалися під час роботи.

## Матриця виправлень

| Знахідка | Зміна | Межа перевірки |
|---|---|---|
| U1: reset/stale scan | Busy guards, покоління scan, скасування з очікуванням завершення pipe-процесу; Smart Care не скидає незалежну активну операцію | Потрібні macOS async/process regressions |
| U2: стара категорія Cleanup | Новий scan і перехід Review нормалізують внутрішній маршрут до summary | Потрібна UI-перевірка |
| U3: застарілі Smart Care результати | Один runnable-набір для кнопки й виконання; completed/result/retry відокремлені від review | Unit regression додано |
| U4: зниклі дії | OrbAction має enabled/reason; Clean/Run/Remove лишаються видимими disabled; знайдений обсяг відокремлено від вибраного | Макет/NSPanel потребують runtime |
| U5: меню Clean | Назви й обсяг залежать від stage; counted-under не додається двічі; done не рекламує старі bytes | Source review |
| U6: Console приховує дію | Навігація закриває журнал, його відкриття не ховає orb; є видимий Close log | Runtime геометрії pending |
| U7: маршрути й retry | Done зі Smart Care повертає до Smart Care; error tiles мають Retry; review origin зберігається | Unit regression додано |
| U8: Terminal | За замовчуванням остання команда модуля; History/picker; initial tail; revision замість line-count; pause/jump; ручне прокручування зупиняє follow; truncation явно позначена | Native scrolling pending |
| C01: fail-open preview | Спільна validated-фабрика вимагає completion, свіжого readable list, валідних/неоднозначних рядків без дублів; positive-empty/incomplete/stale відхиляються | Valid-prefix truncation без backend manifest залишається нерозрізнюваною |
| C02: optimistic result/bytes | Cleanup не підміняє результат preview bytes; gated output відрізано від dry-run; відсутній report = unverified. Projects/Installers/Performance не обіцяють невиміряне звільнення | Backend report не є filesystem delta |
| C03: старий clean-list | Completion + mtime + read/parse validation на initial та pre-run scan | Timestamp precision потребує macOS |
| C04: installer failure = empty | Empty лише після успішного exit і явного no-installers marker; невідоме завершення = error | PTY fixture regressions |
| C05: приховані warnings | Review показує всі notes, FDA пояснення залишається доступним | Source review |
| C06: recovery failure | Видимий recovery outcome, Retry, блокування наступного run; новий journal зберігає applied bytes і відмовляє при зовнішньому конфлікті | Legacy journals не мають applied fingerprint |
| F1: Reinstall label | Назва Update Mole відповідає update-команді; exit 0 не названо доказом нової версії | Live updater не запускався |
| F2: handover/recovery | Strict newer + reviewed/refreshed target, ID, executable structure; persisted old/target version; legacy recovery консервативний | Це не launch/code-signature verification |
| F3: Space Map | Єдиний детермінований top-level набір для bytes/count/trash; parent+child не дублюються; stale/failed load відхилено | Injected Trash tests |
| F4: Protection fail-open | Defaults/read failure блокує editing; весь exclusive interval/recovery lock захищає редактор; Retry | Synthetic loader/read tests |
| F5: Tools silent failures | Touch ID перевіряє status/exit; completion Add потребує успішного preview; stderr/errors видимі; busy/generation guards | Реальних системних змін немає |
| F6: часткові outcomes | Uninstall перевіряє відсутність bundle/helper; malformed brew envelope відхилено; blocked/stopped updates не рахуються success | Зовнішній backend має власні postconditions |
| Security partial quarantine | Помилка launchctl status fail-closed; успішний unload + failed move явно повідомляє частковий ефект, без автоматичного запуску підозрілого агента | Synthetic error test; launchctl runtime pending |

R1: публікація orb обмежена активним модулем. Це вузьке посилення підтвердженого коду, а не доказ усунення непідтвердженої гіпотези про порядок callbacks для двох сцен одного модуля.

## Додатковий користувацький repro: Installers confirmation

Користувацький screenshot підтвердив відмову перевірки вибору, а не відсутність інсталяторів. Повного Mole log немає, тому конкретну причину цього випадку ще не доведено. Незалежно від нього знайдено й виправлено два відтворювані parser/handshake дефекти: filename з подвійними пробілами обрізався на першому padding-подібному роздільнику; review міг прийняти неповний prompt до його завершення. Parser тепер відділяє валідний size справа, зберігає filename; selected count звіряється точно на одному snapshot; final Enter можливий тільки після повного prompt і one-to-one review match. Додано синтетичні PTY regressions для valid flow, ANSI/UTF-8 fragments, delayed prompt, changed review/size. Перевірку безпеки не послаблено, screenshot/приватні шляхи до repo не додаються.

## Перевірки

- Повторно отримано повний GitHub tree; repo AGENTS/skills і попередніх Actions workflow немає. Вхідні source-файли звірено з blob SHA; додаткові build resources/C shim/fixtures відновлено за точними blob SHA. Невикористані binary assets локально не матеріалізувалися; публікація накладає тільки змінені шляхи на оригінальний remote tree і зберігає їх.
- `git diff --check`: PASS на інтеграційному дереві.
- `python3 scripts/l10n.py build` та `check`: PASS; нові ключі вручну додано українською та російською. Компіляторне `extract` ще має перевірити точні keys/types.
- Нові suites: CleanupLifecycleRegressionTests, CleanupValidationRegressionTests, OverlayConflictRegressionTests, ProcessCancellationRegressionTests, NavigationConsistencyRegressionTests, ToolsProtectionSpaceMapRegressionTests, AppsRemovalTests, SecurityPartialOutcomeTests. Розширено AppsOutsideTests, AppsBrewTests, CleanupScopeTests.
- Локальне середовище Linux не має Swift/Xcode. Жоден Python/source-model PASS не названо Swift compilation або passing native tests.
- Додано `.github/workflows/native-tests.yml`: офіційний standard `xcode-27` runner, read-only repository token, pinned actions, synthetic MoleKit/app tests, ad-hoc signing, compiler localization extraction. `NORA_MOLE_E2E=0`, `NORA_MOLE_SUDO=0`; production startup tasks у DEBUG test host вимкнено. Workflow не збирає DMG, не підписує Developer ID, не deploy і не release.
- Native run `39045329698` на `3ee6a6b`: MoleKit PASS (XCTest 22, 2 gated skips; Swift Testing 57 cases). Попередній parallel run мав PTY timeouts; serial mode усунув тестову конкуренцію, це не доказ production concurrency. App compile виявив Swift 6 isolation error console observer; виправлено перед наступним run. Run `39045925591` на `018bb2c`: native app build + 179 XCTest cases (1 gated skip) PASS; 80 PNG export PASS. Compiler extraction знайшов відсутній Retry і застарілі keys: оновлено за compiler output перед наступним run. Остаточний статус exact commit додається до результату; queued/failed не є PASS.
- Розширений прохід меню: див. [матрицю режимів](2026-10-17-menu-modes.uk.md). Додано attribution команд, History loading/retry/exit status, Security notice, Protection rollback та 13 tests. Також виправлено offline latest-release feedback/retry, zero-work Performance button, Space Map keyboard shortcut і доступні назви controls. 132 native snapshot probes чекають CI та огляду PNG; це не live click-through і не автоматичне схвалення дизайну.

## Відкриті архітектурні межі

1. **Broad command race.** Cleanup/Projects усе ще застосовують Mole broad clean/purge з denylist відомих невибраних шляхів. Новий файл після fresh check може потрапити у run. Повне закриття потребує upstream atomic immutable plan/allowlist з identity recheck. Новий код не підміняє це небезпечним самописним permanent-delete executor і не вимикає модуль непомітно.
2. **Повнота текстового списку.** Malformed/ambiguous/empty/stale/incomplete відхиляються, але truncation точно на межі валідного рядка не виявити без authenticated count/checksum manifest. Aggregate Items не дорівнює кількості path rows.
3. **Blocking protection probe.** `MoleInstallation.unprotected` і synchronous loader мають двобічний pipe-протокол без керованого timeout/cancellation. Звичайний pipe run тепер joined, але цей окремий probe потребує міграції до managed runner; безпечне відновлення overlay не має випереджати helper.
4. **Format capability.** Minimum Mole version не гарантує текстовий формат; нові guards відмовляють на невідомому output, але повний capability handshake потребує backend підтримки.
5. **Recovery migration.** Нові journals виявляють зовнішні зміни whitelist; старі не містять applied bytes і зберігають попередній recovery contract. Конфлікт нового journal зберігає обидві версії й потребує ручного узгодження перед повторною спробою.
6. **Signed-Mac acceptance.** Ще потрібні callbacks/NSPanel, keyboard/default action, manual scrolling, native PTY/quit races, FDA/TCC, installed Mole compatibility і вимірювання disk delta. Навіть успішні hosted unit tests не замінюють це.

## Перед merge/release

Потрібні зелені native build/tests та compiler-derived localization check на точному commit; окремо ручний macOS acceptance у sandbox. Release/sign/notarize/merge не є частиною цієї публікації. До розв'язання наведених архітектурних обмежень не стверджувати, що всі можливі помилки або всі ризики очищення усунуто.

## Нативний візуальний огляд

80 PNG з run `39045925591` завантажено для огляду фактичних пікселів. Знайдено підтверджений дефект Security при 1040×620: локалізовані кнопки розсували дві вузькі картки, текст/дії перекривалися; стартова сторінка стискала опис і setup controls. Виправлення: адаптивна ширина карток та opt-in scrolling для Security start зі збереженням orb clearance. Потрібна повторна перевірка PNG на новому commit. Наступний run додає 132 базові кадри та окремі uk/ru test-host language runs для model strings; environment locale сама по собі не є повною перевіркою перекладу.

## Ворота приймання продукту

| Напрям | Доказ у цій роботі | Що ще потрібне для release |
|---|---|---|
| Безпека | Fail-closed previews, exact Installers confirmation, recovery/rollback regressions | Atomic backend allowlist, bounded protection probe, signed Mac/FDA acceptance |
| Функціональність | Native MoleKit та app tests; source coverage усіх 12 модулів і допоміжних маршрутів | Контрольовані end-to-end дії з установленим Mole на окремому тестовому Mac |
| Швидкість/ефективність | Тривалість synthetic tests є в Actions logs | Повторювані benchmark datasets, scan latency/peak RAM/CPU/disk delta; порівняння з CleanMyMac не проводилось |
| UX/доступність | Native PNGs, min-size/localization probes, контрастні tests, labels/disabled states | VoiceOver, keyboard focus, реальний NSPanel/scroll/hit-testing, довгі production lists |
| Надійність | Cancellation, stale-write, partial-outcome, recovery й malformed-output tests | Soak tests, abrupt quit/power-loss, реальні PTY/permissions/network edge cases |
| Підтримка | Pinned safe CI, compiler localization gate, синтетичні fixtures, coverage matrix | Сумісність із версіями Mole, runtime regression ownership і release checklist |

Це вимірювані критерії, а не твердження про перевагу над конкурентом чи відсутність усіх майбутніх помилок. Остаточний статус exact SHA визначає відповідний GitHub Actions run; жоден queued/running статус не означає PASS.
