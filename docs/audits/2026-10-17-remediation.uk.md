# Nora: повторний аудит і виправлення, 17.10.2026

База: `main` / `915fc32e87b6b6040366ef39bde0da80dcdac47a` (повторно звірено через GitHub).

## Статус

Підтверджені дефекти U1–U8, C01–C06 та F1–F5 отримали зміни коду й синтетичні регресійні тести. F6 розділено на конкретні виправлення postcondition та залишкові межі зовнішнього backend. Це **не твердження про повну готовність релізу**: нативна збірка й синтетичні тести пройшли; інтерактивна перевірка, вимірювання продуктивності та архітектурні обмеження нижче лишаються окремими воротами приймання.

Політики наявних операцій permanent delete/Trash не змінено. Окремий новий нагадувач домашнього кошика додано за подальшим явним погодженням користувача; він має власне підтвердження незворотного видалення. Remove Mole залишається preview-only і тепер прямо це пояснює. Реальні файли користувача не очищалися, програми не встановлювалися й системні налаштування не змінювалися під час роботи.

Останній підтверджений native receipt і поточна матриця наведені наприкінці документа. Ранні записи нижче зберігають стан перевірки на момент відповідного етапу.

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
3. **Protection probe validation.** Міграцію `MoleInstallation.unprotected` і synchronous loader до bounded managed runner реалізовано й незалежно перевірено на рівні source. Timeout/cancellation, duplex stdout/stderr, strict framing та settlement мають synthetic regressions; exact-commit native validation ще pending. In-memory recovery hold не доводить cross-launch survivor containment.
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

## Повторна native перевірка та наступний safety patch

Commit `6a948521b883e616322f2c3e7942a62640c02a44`, Actions run `39047238038`: native build/tests PASS; app 187 cases (186 passed, 1 gated skip), MoleKit XCTest 22 (2 gated skips) і Swift Testing suites PASS. Compiler localization: 789 keys, 0 issues. Оглянуто 190 PNG (132 базові + по 29 з окремих uk/ru процесів): Security overlap усунуто, unavailable updates показують чесну помилку, Notice contrast ≥ приблизно 5.78:1. Додатково виправлено низький контраст failure lines у completion view; новий contrast regression потребує наступного native run.

Наступний patch додає bounded managed protection probes: nonblocking duplex I/O, deadline, обмеження output, strict UTF-8/count framing, cancellation із settlement/reap та recovery hold при невизначеному ownership. Protection load перенесено поза main actor; snapshot commit атомарний, stale generation/помилки не дозволяють editing. Початок exclusive run синхронно скасовує старий load. Незалежний source review не знайшов відкритого blocker; native compile/tests для цього patch ще pending, тож source checks не є runtime доказом.

Recovery hold є in-memory. Після аварійного завершення startup recovery не перевіряє surviving helper з попереднього процесу Nora; persisted cross-launch containment залишається архітектурним обмеженням. Broad-command allowlist race і невизначеність valid-prefix truncated preview також не усунені цим patch.


## ClamAV: окреме керування рушієм і сигнатурами

Додано installed engine version/location, явно датовану перевірку Homebrew catalog (з revisions), окремі дії engine upgrade та freshclam definitions update, build date/version on-disk бази, окремі success timestamps і результати/помилки/скасування в Security console. Catalog не названо глобальним доказом latest; перевірка сигнатур не названа оновленням рушія. Engine mutation блокується до завершення активних scan/startup tasks та фактичного виходу зупиненого watcher daemon. Existing daemon не названо оновленим після зміни binary на диску.

Усі нові tests використовують injected tools і temporary fixtures. Додано Settings renders для installed/outdated/failed-check/missing-homebrew/missing-engine/busy, 640×580 і 640×1600, EN/UK/RU; окремі process-language reruns потрібні для model strings. 840 localization keys проходять локальний check; compiler extraction та native pixels на цьому patch ще pending. Реальний brew/freshclam/clamd на Mac користувача не запускався.

Повторний pixel review також виявив декоративне перекриття українського Cleanup опису та обрізані російські Application captions при мінімальному вікні. Feature-local адаптивні ширини/scroll viewport виправлено, без приховування дій; наступний native render має це підтвердити.

## Native receipt: managed probes та ClamAV

Run `39049618579` / commit `021e52800a8dc6af1f637377398dbbfb9b48e6d8`: MoleKit XCTest 30 cases (28 passed, 2 gated skips), Swift Testing 80 cases/18 suites PASS; app 214 cases (213 passed, 1 gated skip), окремі uk/ru suites по 2 cases PASS. ManagedProbe timeout/cancellation/duplex stderr та Protection transient-exclusive-run regressions виконані на macOS. App compile issue у test-only semaphore helper виправлено; actor warning та unreachable switch default усунуто.

Export: 298 PNG (168 базових, по 65 uk/ru). Pixel review нового ClamAV та повторних localized layouts триває. Єдина failure цього run — compiler-derived catalog freshness: 830 живих keys проти 840 записаних, missing translations = 0. Наступний patch замінює keys точним compiler artifact та перебудовує catalog; також передає temporary fixture homes у screenshot/ClamAV AppModel instances. Остаточний зелений exact-commit gate ще pending; цей failed workflow не названо повним PASS.

## Додаткові приймальні зміни: кошик та іконки

Функціональна база `7a44cbae4d5a3a862a928cdf49cdfed1b1f7f8a3` пройшла весь native workflow
[39050856340](https://github.com/Lexus2016/Nora/actions/runs/39050856340): 214 App XCTest
випадків (213 успішних, 1 навмисно пропущений), окремі український і російський
запуски, 830 ключів без прогалин та строгий збіг каталогу з компілятором.
Переглянуто 298 PNG попереднього native запуску: ClamAV стани розрізняються,
переклади вміщуються, раніше підтверджені перекриття Cleanup та обрізання Apps
виправлені. Доступність прокручуваних дій через реальне натискання цим не доведена.

Новий нагадувач охоплює лише домашній `~/.Trash`, коли Nora працює. FSEvents є
основним джерелом змін; резервний 10-секундний таймер робить лише перевірку кореня,
не рекурсивний підрахунок. Повторні зміни об'єднуються, відхилений незмінений набір
не показується знову. Панель 520×260 має окремий перемикач нагадувань, ручний вхід
через меню/налаштування та другий явний крок незворотного видалення. Автоматичного
видалення немає. Тестові й візуальні моделі не створюють реальний файловий сервіс.

Виконавець використовує обмежений повний знімок, no-follow дескриптори,
переміщення без перезапису в приватну область на тому самому томі та перевірку
ідентичності перед видаленням захопленого об'єкта. Нові кореневі надходження не
додаються до підтвердженого набору. Журнал відновлення має незмінний manifest і
малий progress-файл; кожен крок не переписує весь manifest. Відновлення лише
повертає/зберігає залишки, ніколи не продовжує видалення. Результат повідомляє
кількість видалених записів, а не вигадані точні звільнені байти. Невизначений
стан відновлення, ACL приватної області, нечитабельний або пошкоджений журнал
блокують нову операцію. Інші команди Nora та переміщення карантину узгоджені з
активною операцією кошика; завершення застосунку очікує її зупинки.

Незалежний source-review виявив і виправив: недооблік після успішного unlink і
помилки fsync, залишки тимчасових журналів після аварії, строк життя flock,
сумісність із наявною директорією Nora 0755, ACL успадкування, квадратичний обсяг
запису журналу, відновлення монітора після shutdown, втрату відкладеної перевірки,
неповну взаємну заборону операцій та блокування FIFO під час читання старого
журналу. Додано 31 backend fixture test, 18 model tests, watcher та integration
тести і native PNG fixtures. Linux C harness пройшов 8 перевірок; це не заміна
нативній Swift/macOS компіляції.

Іконки зберігають вихідні ресурси. Об'єм, світло та тінь уточнено; декоративні
таймлайни вимикаються для прихованого/неактивного стану та Reduce Motion.
Маскот має дві короткі хвилі протягом 0,90 с, після чого зупиняється. Native
fixture перевіряє декодування кожного оригінального glass-ресурсу. Помилку
позитивного заголовка Space Map за часткового невдалого переміщення виправлено.
Перший native прохід іконок виявив непідтримуване встановлення read-only
accessibility environment у тесті; fixture виправлено. Реальний системний
Reduce Motion потребує окремої інтерактивної перевірки.

### Межі доказів для цього доповнення

- Native compile/test та фінальні PNG нового кошика: очікують фінального workflow.
- Реальні клавіатура/VoiceOver, Focus/Spaces, TCC/FDA та взаємодія NSPanel: не перевірені.
- Інший процес того самого UID або вже відкритий writable FD може змінити об'єкт;
  POSIX не надає атомарного compare-and-unlink. Це не обіцянка абсолютної атомарності.
- Hardlink-набори можуть консервативно зупинитися через зміну спільного ctime.
- Продуктивність CPU/GPU та великих реальних кошиків не виміряна; нульове
  навантаження, абсолютна перевага над конкурентами та безпомилковість не заявляються.
- Реальні користувацькі файли не видалялися. Реліз та merge не виконувалися.

Native запуск `65275321` підтвердив компіляцію нового App та 250 XCTest випадків
(249 успішних, 1 навмисно пропущений), по 3 тести в українському й російському
процесах і 880 ключів із чистим compiler diff. З 379 PNG незалежно переглянуто
50 унікальних зображень: усі 24 process-matched стани панелі кошика, 12 модулів,
іконки, маскот, Settings і частковий результат Space Map. Виявлене центрування
нижнього перемикача виправлено й перевірено новим native PNG з `92a6e15`.

Backend ще не прийнято цими двома запусками. Перший виявив тестовий шлях з
нерозкритим `/var`-посиланням; fixture тепер використовує `realpath` на наявному
тимчасовому батьківському каталозі. Другий виявив справжню macOS-сумісність ACL:
`acl_get_fd_np` повертає NULL/ENOENT, коли властивості ACL немає. Обробку замінено
на явні `fstatx_np` та `filesec_query_property`, без дозволу на невідому помилку.
Darwin iterator 0-success / -1-EINVAL-end не змінено. Додано окремі absent,
deny-only, mixed-allow та invalid-descriptor перевірки (разом 33 backend cases).
Джерела: [Apple acl_file.c](https://github.com/apple-oss-distributions/Libc/blob/main/posix1e/acl_file.c),
[Apple filesec.c](https://github.com/apple-oss-distributions/Libc/blob/main/gen/filesec.c).
Новий native прохід має перевірити це виправлення до прийняття функції.

Visual fixtures busy/cancel/stopping/recovery уточнено: вони відображають справжні
стани доступності контролів, але не створюють задач, токенів чи таймерів.
CI тепер не витрачає довгий App-прохід після backend failure; повний успішний
workflow, як і раніше, вимагає backend, App, локалізованих PNG та compiler-catalog
перевірок. Тести не замінені source-моделлю і не послаблені для зеленого статусу.


## Підсумковий native receipt та поточна матриця

Код `87bbe46ec9219df92cdd8e7d8eb245c3f13f95ae`, дерево
`7a4c88a960c064f2d6312484c29c622c7c3b0f65`, пройшов повний
[workflow 39053758425](https://github.com/Lexus2016/Nora/actions/runs/39053758425)
на macOS/Xcode 27. Усі 270 remote blobs звірено з попереднім деревом і точним
набором змін; вихідні бінарні ресурси збережено.

- MoleKit XCTest: 63 випадки, 60 успішних, 3 явні пропуски, 0 помилок.
- З них HomeTrashSafetyTests: 33 випадки, 32 успішних, 1 пропуск: файлова система
  відхиляє не-UTF-8 ім'я з EILSEQ, тому відповідний fixture неможливо створити.
- Решта backend skips: destructive Mole E2E вимкнено; зовнішні real-capture fixtures не задано.
- Swift Testing: 80 тестів у 18 suites, усі успішні.
- App XCTest: 251 випадок, 250 успішних, 1 пропуск через відсутній реальний ClamAV.
- Окремі український і російський process-language запуски: по 4 тести, усі успішні.
- 880 localization keys, 0 missing translations, 0 problems; compiler catalog збігається.
- Експортовано 406 PNG. Це кількість створених знімків, а не твердження про ручний
  перегляд кожного. Попередній незалежний перегляд охопив 50 PNG; фінальний
  process-matched набір кошика перевірено: усі 30 панелей проходять статичний
  огляд. У трьох Settings знімках тестовий viewport 640×260 обрізав останній
  status рядок; висоту fixture збільшено до 420 для повторного native огляду.
- Artifact `12108224742`, SHA-256
  `8c0c394aeb0f4a58e45f019d46a2db5c7d120928696da3c98e5c19cfae36a251`.

| Область | Підтверджено | Ще не доведено |
|---|---|---|
| U1–U8, C01–C06, F1–F5 | Компіляція, відповідні синтетичні регресії та статичні native layouts пройшли | Реальне прокручування, клавіатура, VoiceOver, усі інтерактивні переходи |
| Installers confirmation | Валідні/змінені selections, fragments і назви з пробілами перевірено fixtures | Точна причина конкретного користувацького випадку без Mole log |
| Managed probes / Protection | Timeout, cancel, duplex output і off-main regressions пройшли | Всі реальні зовнішні процеси/стани Mac |
| ClamAV | Окремі engine/definitions стани, помилки, busy/cancel і переклади перевірено | Реальна інсталяція, update та мережевий сценарій на Mac користувача |
| Домашній кошик | Snapshot identity, no-follow, ACL, staging, collision, cancellation, recovery та mutual-exclusion fixtures пройшли | Конкурентний same-UID процес/open writable FD; реальні TCC/FDA, Focus/Spaces та навантаження |
| Іконки/рух | Вихідні glass assets, policy tests, статичні poses, bounded mascot lifecycle | Візуальна плавність, системний Reduce Motion та CPU/GPU benchmark |
| Локалізація | EN/UK/RU каталог і process snapshots | Вісім додаткових мов лише заплановано в RELEASE-PLAN |
| Backend-контракт | Невизначені результати та небезпечні неповні previews блокуються/позначаються | Broad Mole rescan не є атомарним immutable allowlist; невідомі майбутні версії не вважаються протестованими |

Цей receipt закриває попередні pending native compile/backend gates. Не закриває
інтерактивні, performance та архітектурні межі. Реальні користувацькі файли не
видалялися, реліз/merge не виконувалися. Подальший commit цього звіту змінює лише
документацію та висоту Settings screenshot fixture; його точний SHA і workflow
слід звірити окремо перед передачею.
