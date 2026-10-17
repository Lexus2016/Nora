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
- Нативний CI на момент підготовки звіту: **ще не запущено**. Остаточний commit/run статус додається в супровідний результат; queued/failed не є PASS.

## Відкриті архітектурні межі

1. **Broad command race.** Cleanup/Projects усе ще застосовують Mole broad clean/purge з denylist відомих невибраних шляхів. Новий файл після fresh check може потрапити у run. Повне закриття потребує upstream atomic immutable plan/allowlist з identity recheck. Новий код не підміняє це небезпечним самописним permanent-delete executor і не вимикає модуль непомітно.
2. **Повнота текстового списку.** Malformed/ambiguous/empty/stale/incomplete відхиляються, але truncation точно на межі валідного рядка не виявити без authenticated count/checksum manifest. Aggregate Items не дорівнює кількості path rows.
3. **Blocking protection probe.** `MoleInstallation.unprotected` і synchronous loader мають двобічний pipe-протокол без керованого timeout/cancellation. Звичайний pipe run тепер joined, але цей окремий probe потребує міграції до managed runner; безпечне відновлення overlay не має випереджати helper.
4. **Format capability.** Minimum Mole version не гарантує текстовий формат; нові guards відмовляють на невідомому output, але повний capability handshake потребує backend підтримки.
5. **Recovery migration.** Нові journals виявляють зовнішні зміни whitelist; старі не містять applied bytes і зберігають попередній recovery contract. Конфлікт нового journal зберігає обидві версії й потребує ручного узгодження перед повторною спробою.
6. **Signed-Mac acceptance.** Ще потрібні callbacks/NSPanel, keyboard/default action, manual scrolling, native PTY/quit races, FDA/TCC, installed Mole compatibility і вимірювання disk delta. Навіть успішні hosted unit tests не замінюють це.

## Перед merge/release

Потрібні зелені native build/tests та compiler-derived localization check на точному commit; окремо ручний macOS acceptance у sandbox. Release/sign/notarize/merge не є частиною цієї публікації. До розв'язання наведених архітектурних обмежень не стверджувати, що всі можливі помилки або всі ризики очищення усунуто.
