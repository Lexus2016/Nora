'use strict';
/* Nora prototype — all data is mock, shaped after real Mole CLI outputs (v1.59.1). */

// ---------- helpers ----------
const $ = (s, r = document) => r.querySelector(s);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const nf1 = new Intl.NumberFormat('uk-UA', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const nf0 = new Intl.NumberFormat('uk-UA', { maximumFractionDigits: 0 });
function mb(v) {
  if (v == null || isNaN(v)) return '—';
  if (v >= 1000) return (v >= 100000 ? nf0.format(v / 1000) : nf1.format(v / 1000)) + ' ГБ';
  if (v >= 1) return nf0.format(v) + ' МБ';
  return nf0.format(Math.max(1, v * 1000)) + ' КБ';
}
const ic = (id, cls = '') => `<svg class="ic ${cls}" aria-hidden="true"><use href="#${id}"/></svg>`;
const cmd = c => `<span class="cmd" title="${esc(c)}">${esc(c)}</span>`;
const sum = (arr, f) => arr.reduce((a, x) => a + (f(x) || 0), 0);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
function grad(name) { let h = 0; for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) % 360; return `linear-gradient(160deg,hsl(${h} 52% 58%),hsl(${(h + 28) % 360} 48% 38%))`; }
const initials = n => n.replace(/^(Adobe|Google)\s+/, '').split(/\s+/).filter(w => !/\d/.test(w)).slice(0, 2).map(w => w[0]).join('').toUpperCase();

// ---------- mock data ----------
const CLEAN = [
  { id: 'user', name: 'Основне користувача', items: [
    { id: 'u1', label: 'Кеш застосунків', path: '~/Library/Caches/* · 18 застосунків', mb: 2400, n: 18 },
    { id: 'u2', label: 'Журнали застосунків', path: '~/Library/Logs/*', mb: 12.8, n: 7 },
    { id: 'u3', label: 'Кошик', path: '~/.Trash', mb: 1100, n: 9, trash: true },
    { id: 'u4', label: 'Метадані Finder', path: 'FINDER_METADATA · .DS_Store', mb: null, prot: 'обов’язковий захист' } ] },
  { id: 'appc', name: 'Кеші застосунків', items: [
    { id: 'a1', label: 'App Store', path: '~/Library/Caches/com.apple.appstore', mb: 248.5, n: 8 },
    { id: 'a2', label: 'Spotify', path: '~/Library/Application Support/Spotify/PersistentCache', mb: 1300, n: 1 },
    { id: 'a3', label: 'Slack', path: '~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches', mb: 412, n: 3 },
    { id: 'a4', label: 'JetBrains', path: '~/Library/Caches/JetBrains*', mb: 2900, prot: 'типовий захист Mole' } ] },
  { id: 'brow', name: 'Браузери', items: [
    { id: 'b1', label: 'Safari', path: '~/Library/Caches/com.apple.Safari', mb: 642.1, n: 24 },
    { id: 'b2', label: 'Chrome', path: '~/Library/Caches/Google/Chrome', mb: 1200, n: 31 },
    { id: 'b3', label: 'Старі версії Chrome', path: '/Applications/Google Chrome.app/…/Versions/140.0.*', mb: 380, n: 2 },
    { id: 'b4', label: 'Браузери Playwright', path: '~/Library/Caches/ms-playwright*', mb: 1700, prot: 'типовий захист Mole' } ] },
  { id: 'dev', name: 'Інструменти розробника', items: [
    { id: 'd1', label: 'npm', path: '~/.npm/_cacache', mb: 1800, n: 1 },
    { id: 'd2', label: 'pnpm', path: '~/Library/pnpm/store/v10', mb: null, skip: 'pnpm зайнятий — Mole пропустить' },
    { id: 'd3', label: 'Xcode DerivedData', path: '~/Library/Developer/Xcode/DerivedData', mb: 6200, n: 14 },
    { id: 'd4', label: 'Go build cache', path: '~/Library/Caches/go-build', mb: 910, n: 1 },
    { id: 'd5', label: 'Homebrew', path: '~/Library/Caches/Homebrew', mb: 2100, n: 46 },
    { id: 'd6', label: 'Gradle', path: '~/.gradle/caches/*', mb: 3400, prot: 'типовий захист Mole' },
    { id: 'd7', label: 'Моделі Ollama', path: '~/.ollama/models/*', mb: 18200, prot: 'типовий захист Mole' } ] },
  { id: 'left', name: 'Залишки видалених застосунків', items: [
    { id: 'l1', label: 'Adobe Photoshop 2023', path: '~/Library/Application Support/Adobe/Adobe Photoshop 2023', mb: 1400, n: 46 },
    { id: 'l2', label: 'zoom.us', path: '~/Library/Application Support/zoom.us', mb: 180, n: 12 },
    { id: 'l3', label: 'Notion', path: '~/Library/Preferences/notion.id.plist', mb: 0.2, n: 1 } ] },
  { id: 'bkp', name: 'Резервні копії та прошивки', items: [
    { id: 'k1', label: 'Прошивка iPhone', path: '~/Library/iTunes/iPhone Software Updates/iPhone16,2_26.3_Restore.ipsw', mb: 6800, n: 1 } ] },
  { id: 'virt', name: 'Віртуалізація', items: [
    { id: 'v1', label: 'Журнали Docker Desktop', path: '~/Library/Containers/com.docker.docker/Data/log', mb: 220, n: 5 },
    { id: 'v2', label: 'Кеш UTM', path: '~/Library/Containers/com.utmapp.UTM/Data/Library/Caches', mb: null, n: 3, unknown: true } ] },
  { id: 'cloud', name: 'Хмара та Office', items: [
    { id: 'o1', label: 'Кеші Microsoft Office', path: '~/Library/Containers/com.microsoft.Word/Data/Library/Caches', mb: 310, n: 4 } ] },
  { id: 'sys', name: 'Системні', sudo: true, items: [
    { id: 's1', label: 'Системні журнали', path: '/private/var/log/*.gz', mb: 1200, n: 62 },
    { id: 's2', label: 'Звіти діагностики', path: '/Library/Logs/DiagnosticReports', mb: 320, n: 118 },
    { id: 's3', label: 'Оновлення Apple Silicon', path: '/Library/Updates', mb: 2100, n: 2 } ] },
];
const CLEAN_ITEMS = CLEAN.flatMap(s => s.items.map(i => ({ ...i, sec: s.id })));
const selectable = i => !i.prot && !i.skip;

const APPS = [
  { id: 'ps', name: 'Adobe Photoshop 2024', bid: 'com.adobe.Photoshop', src: 'Вручну', mb: 4200, used: '2 міс тому', d: 62 },
  { id: 'xcode', name: 'Xcode', bid: 'com.apple.dt.Xcode', src: 'App Store', mb: 14600, used: 'сьогодні', d: 0 },
  { id: 'hades', name: 'Hades II', bid: 'steam.app.1145350', src: 'Steam', mb: 9800, used: '5 міс тому', d: 150 },
  { id: 'pr', name: 'Adobe Premiere Pro 2024', bid: 'com.adobe.PremierePro.24', src: 'Вручну', mb: 3400, used: '2 тиж тому', d: 14 },
  { id: 'idea', name: 'IntelliJ IDEA', bid: 'com.jetbrains.intellij', src: 'Homebrew', mb: 2800, used: '3 дні тому', d: 3, cask: 'intellij-idea' },
  { id: 'docker', name: 'Docker', bid: 'com.docker.docker', src: 'Homebrew', mb: 2100, used: 'вчора', d: 1, cask: 'docker' },
  { id: 'arc', name: 'Arc', bid: 'company.thebrowser.Browser', src: 'Вручну', mb: 680, used: '3 міс тому', d: 95 },
  { id: 'slack', name: 'Slack', bid: 'com.tinyspeck.slackmacgap', src: 'App Store', mb: 512, used: 'сьогодні', d: 0 },
  { id: 'spotify', name: 'Spotify', bid: 'com.spotify.client', src: 'Homebrew', mb: 420, used: 'тиждень тому', d: 7, cask: 'spotify' },
  { id: 'figma', name: 'Figma', bid: 'com.figma.Desktop', src: 'Вручну', mb: 380, used: '4 дні тому', d: 4 },
  { id: 'zoom', name: 'zoom.us', bid: 'us.zoom.xos', src: 'Вручну', mb: 290, used: '5 міс тому', d: 152 },
  { id: 'tg', name: 'Telegram', bid: 'ru.keepcoder.Telegram', src: 'App Store', mb: 230, used: 'сьогодні', d: 0 },
  { id: 'vlc', name: 'VLC', bid: 'org.videolan.vlc', src: 'Homebrew', mb: 160, used: '8 міс тому', d: 240, cask: 'vlc' },
];
function appFiles(a) {
  const groups = [
    { t: 'Застосунок', mb: a.mb * 0.86, files: [a.src === 'Steam' ? `~/Library/Application Support/Steam/steamapps/common/${a.name}` : `/Applications/${a.name}.app`] },
    { t: 'Кеші та стан', mb: a.mb * 0.11, files: [`~/Library/Caches/${a.bid}`, `~/Library/HTTPStorages/${a.bid}`, `~/Library/Saved Application State/${a.bid}.savedState`] },
    { t: 'Служби запуску', mb: 0.1, files: [`~/Library/LaunchAgents/${a.bid}.helper.plist`] },
  ];
  if (a.cask) groups.push({ t: 'Homebrew', mb: 0, files: [`cask «${a.cask}» — Mole видалить через brew`] });
  const kept = [`~/Library/Application Support/${a.name}`, `~/Library/Preferences/${a.bid}.plist`];
  const refs = a.id === 'docker' ? ['~/.zshrc:42 · source ~/.docker/init-zsh.sh', '~/.claude.json:118 · MCP-сервер «docker»']
    : a.id === 'idea' ? ['~/.zshrc:17 · export PATH="…/IntelliJ IDEA.app/Contents/MacOS:$PATH"'] : [];
  return { groups, kept, refs, total: sum(groups, g => g.mb) };
}

const PROJECTS = [
  { path: '~/Projects/website', arts: [{ id: 'p1', k: 'node_modules', mb: 3800, age: '28 дн' }, { id: 'p2', k: 'dist', mb: 186, age: '<1 дн', recent: true }] },
  { path: '~/Projects/rust-app', arts: [{ id: 'p3', k: 'target', mb: 2200, age: '2 міс' }, { id: 'p4', k: 'dist', mb: 22, age: '5 дн', recent: true }] },
  { path: '~/GitHub/ml-lab', arts: [{ id: 'p5', k: '.venv', mb: 1900, age: '3 міс' }, { id: 'p6', k: '__pycache__', mb: 12, age: '3 міс' }, { id: 'p7', k: '.pytest_cache', mb: 3, age: '3 міс' }] },
  { path: '~/dev/ios-app', arts: [{ id: 'p8', k: 'build', mb: 1100, age: '5 міс' }] },
  { path: '~/Projects/landing-2024', arts: [{ id: 'p9', k: 'node_modules', mb: 940, age: '6 міс' }, { id: 'p10', k: 'dist', mb: 310, age: '6 міс' }] },
  { path: '~/.codex/worktrees/agent-7f2c', arts: [{ id: 'p11', k: 'node_modules', mb: null, age: '?', unverified: true }] },
];
const ARTS = PROJECTS.flatMap(p => p.arts.map(a => ({ ...a, proj: p.path })));
const artDefault = a => !a.recent && !a.unverified;

const INST = [
  { id: 'i1', name: 'ubuntu-24.04.3-desktop-arm64.iso', t: 'ISO', mb: 6100, src: 'Завантаження', age: '7 міс' },
  { id: 'i2', name: 'Xcode_26.1.xip', t: 'XIP', mb: 3400, src: 'Робочий стіл', age: '2 міс' },
  { id: 'i3', name: 'Photoshop_2024.dmg', t: 'DMG', mb: 1200, src: 'Завантаження', age: '4 міс' },
  { id: 'i4', name: 'Illustrator_Setup.pkg', t: 'PKG', mb: 920.4, src: 'Завантаження', age: '4 міс' },
  { id: 'i5', name: 'IntelliJ_IDEA.dmg', t: 'DMG', mb: 850.6, src: 'Завантаження', age: '3 тиж' },
  { id: 'i6', name: 'PyCharm_Pro.dmg', t: 'DMG', mb: 640.5, src: 'Homebrew', age: '5 тиж' },
  { id: 'i7', name: 'AppCode_Legacy.zip', t: 'ZIP', mb: 410.6, src: 'Завантаження', age: '1 рік' },
  { id: 'i8', name: 'Acrobat_Reader.dmg', t: 'DMG', mb: 220.4, src: 'Пошта', age: '6 міс' },
  { id: 'i9', name: 'Figma-Setup.dmg', t: 'DMG', mb: 180, src: 'Telegram', age: '2 тиж' },
  { id: 'i10', name: 'Kaku-0.9.pkg', t: 'PKG', mb: 96, src: 'iCloud', age: '1 міс' },
];
const FT_COL = { ISO: 'var(--c3)', XIP: 'var(--c6)', DMG: 'var(--c1)', PKG: 'var(--c2)', ZIP: 'var(--c7)' };

const OPT = [
  ['system_maintenance', 'Перевірка DNS і Spotlight', 'Оновлює кеш DNS і перевіряє стан індексу Spotlight'],
  ['cache_refresh', 'Оновлення кешу Finder', 'Оновлює мініатюри QuickLook і кеш іконок'],
  ['saved_state_cleanup', 'Старі стани застосунків', 'Прибирає збережені стани вікон, старші за 30 днів'],
  ['fix_broken_configs', 'Ремонт налаштувань', 'Виправляє пошкоджені plist-файли налаштувань'],
  ['network_optimization', 'Мережевий кеш', 'Оновлює кеш DNS'],
  ['sqlite_vacuum', 'Оптимізація баз даних', 'Стискає SQLite-бази Пошти, Safari і Повідомлень; пропускає, якщо застосунки відкриті'],
  ['prevent_network_dsstore', 'Без .DS_Store на мережевих дисках', 'Забороняє Finder створювати .DS_Store на SMB/AFP/NFS і USB'],
  ['legacy_overrides_audit', 'Застарілі перевизначення', 'Знімає приховані налаштування App Nap і перевірки образів від старих «твікерів»'],
  ['network_stack_optimize', 'Мережевий стек', 'Скидає таблицю маршрутів і ARP-кеш'],
  ['disk_permissions_repair', 'Ремонт дозволів', 'Виправляє дозволи в домашній теці'],
  ['spotlight_index_optimize', 'Індекс Spotlight', 'Перебудовує індекс, якщо пошук повільний'],
  ['spotlight_orphan_rules_cleanup', 'Сирітські правила Spotlight', 'Прибирає правила пошуку видалених застосунків'],
  ['periodic_maintenance', 'Періодичне обслуговування', 'Запускає щоденні, щотижневі й щомісячні скрипти macOS, якщо вони застаріли'],
  ['shared_file_list_repair', 'Списки Finder', 'Ремонтує обране і недавні документи'],
  ['disk_verify', 'Перевірка диска', 'Перевіряє цілісність файлової системи (вмикається окремо)'],
  ['login_items_audit', 'Об’єкти входу', 'Шукає зламані об’єкти автозапуску'],
  ['quarantine_cleanup', 'База карантину', 'Очищає історію завантажень Gatekeeper'],
  ['launch_agents_cleanup', 'Зламані LaunchAgents', 'Показує агенти, чиїх файлів уже немає'],
  ['notification_cleanup', 'Сповіщення', 'Прибирає старі доставлені сповіщення'],
  ['coreduet_cleanup', 'Дані використання', 'Прибирає старі дані відстеження використання'],
];
const OPT_OUT = {
  system_maintenance: ['applied', 'Кеш DNS оновлено, індекс Spotlight справний'], cache_refresh: ['applied', 'Мініатюри і кеш іконок оновлено'],
  saved_state_cleanup: ['applied', 'Прибрано 14 старих станів'], network_optimization: ['unchanged', 'Вже актуально'],
  sqlite_vacuum: ['attention', 'Закрийте Safari, щоб оптимізувати бази'], disk_verify: ['unavailable', 'Вимкнено: потрібен MOLE_ENABLE_DISK_VERIFY=1'],
  spotlight_index_optimize: ['skipped', 'Пошук швидкий — перебудова не потрібна'], periodic_maintenance: ['applied', 'Щотижневий скрипт запущено'],
  launch_agents_cleanup: ['skipped', 'Зламаних агентів не знайдено'],
};
const OUT_PILL = { applied: ['good', 'Застосовано'], unchanged: ['neutral', 'Без змін'], skipped: ['neutral', 'Пропущено'], unavailable: ['warn', 'Недоступно'], attention: ['crit', 'Потребує уваги'], excluded: ['neutral', 'Виключено'] };

const HIST = [
  { id: 'h1', c: 'clean', when: 'Сьогодні, 09:14', dur: '1 хв 52 с', mb: 12400, items: 412, a: [398, 0, 11, 3, 0], attr: 'run' },
  { id: 'h2', c: 'optimize', when: 'Вчора, 18:40', dur: '38 с', mb: 0, items: 20, a: [0, 0, 3, 0, 4], attr: 'run' },
  { id: 'h3', c: 'purge', when: '9 жовт., 22:05', dur: '14 с', mb: 6000, items: 2, a: [2, 0, 0, 0, 0], attr: 'run' },
  { id: 'h4', c: 'uninstall', when: '7 жовт., 11:30', dur: '9 с', mb: 4200, items: 31, a: [0, 31, 0, 0, 0], attr: 'run' },
  { id: 'h5', c: 'installer', when: '2 жовт., 16:12', dur: '6 с', mb: 3830, items: 5, a: [5, 0, 0, 0, 0], attr: 'run' },
  { id: 'h6', c: 'clean', when: '28 вер., 10:02', dur: '2 хв 10 с', mb: 9100, items: 356, a: [344, 0, 12, 0, 0], attr: 'command' },
  { id: 'h7', c: 'clean', when: '19 вер., 08:47', dur: 'немає мітки завершення', mb: 2100, items: 88, a: [80, 0, 6, 2, 0], attr: 'ambiguous' },
];
const CMD_COL = { clean: 'var(--c1)', purge: 'var(--c2)', uninstall: 'var(--c4)', installer: 'var(--c3)', optimize: 'var(--c5)' };
const CMD_UA = { clean: 'Очищення', purge: 'Проєкти', uninstall: 'Деінсталяція', installer: 'Інсталятори', optimize: 'Оптимізація' };
const CMD_IC = { clean: 'i-clean', purge: 'i-purge', uninstall: 'i-uninstall', installer: 'i-installer', optimize: 'i-optimize' };
const HIST_DAYS = [0, 0, 2100, 0, 0, 0, 0, 0, 0, 9100, 0, 0, 0, 0, 3830, 0, 0, 0, 0, 4200, 0, 0, 6000, 0, 0, 0, 0, 0, 0, 12400];
const HIST_DAY_CMD = [null, null, 'clean', null, null, null, null, null, null, 'clean', null, null, null, null, 'installer', null, null, null, null, 'uninstall', null, null, 'purge', null, null, null, null, null, null, 'clean'];

// Disk tree (MB). partial → size is a lower bound ("+"); unavailable → unknown.
const T = (n, s, kids, x = {}) => ({ n, s, kids, ...x });
const DISK = T('Macintosh HD', 692600, [
  T('Домашня тека', 286400, [
    T('Projects', 84100, [T('ml-lab', 31200), T('website', 9800), T('rust-app', 7400), T('ios-app', 6100), T('Інше', 29600)], { path: '~/Projects' }),
    T('Movies', 62000, [T('Final Cut', 41800), T('Screen Recordings', 14600), T('Інше', 5600)], { path: '~/Movies' }),
    T('Downloads', 41600, [T('Старші за 90 днів', 18200, null, { insight: 'Старі завантаження (90д+)' }), T('Інсталятори', 13500, null, { insight: 'див. Інсталятори' }), T('Інше', 9900)], { path: '~/Downloads' }),
    T('Documents', 38900, [T('Archive', 21000), T('Work', 12400), T('Інше', 5500)], { path: '~/Documents' }),
    T('Pictures', 31500, [T('Photos Library', 29800), T('Інше', 1700)], { path: '~/Pictures' }),
    T('Music', 12400, null, { path: '~/Music' }), T('Desktop', 9800, null, { path: '~/Desktop' }), T('Інше', 6100),
  ], { path: '~' }),
  T('Бібліотека користувача', 168200, [
    T('Application Support', 71300, [T('MobileSync (резервні копії iOS)', 24600, null, { insight: 'Резервні копії iOS' }), T('Adobe', 9800), T('Slack', 4100), T('Code', 3200), T('Інше', 29600)], { path: '~/Library/Application Support' }),
    T('Containers', 38400, [T('Docker', 31000, null, { clean: 'Docker Data' }), T('Інше', 7400)], { path: '~/Library/Containers' }),
    T('Developer', 29100, [T('DerivedData', 14200, null, { clean: 'Xcode DerivedData' }), T('CoreSimulator', 11800, null, { clean: 'Xcode Simulators' }), T('Archives', 3100, null, { clean: 'Xcode Archives' })], { path: '~/Library/Developer' }),
    T('Caches', 17900, null, { clean: 'кеші', path: '~/Library/Caches' }), T('Mail', 9300), T('Logs', 2200, null, { clean: 'журнали' }),
  ], { path: '~/Library' }),
  T('Програми', 64800, [T('Xcode', 14600), T('Adobe Photoshop 2024', 4200), T('Premiere Pro 2024', 3400), T('IntelliJ IDEA', 2800), T('Docker', 2100), T('Інше', 37700)], { path: '/Applications' }),
  T('Системна бібліотека', 52300, [T('Frameworks', 18400, null, { partial: true }), T('PrivateFrameworks', 15200, null, { partial: true }), T('Updates', 9100, null, { partial: true }), T('Інше', 9600, null, { partial: true })], { path: '/Library', partial: true }),
  T('Інше (знімки APFS, інші користувачі)', 120900, null, { unavailable: true }),
], { path: '/' });
const EXT_DISK = T('Archive (зовнішній)', 1412000, [T('Photos 2019–2024', 812000), T('Time Machine', 420000, null, { partial: true }), T('Video', 151000), T('Інше', 29000)], { path: '/Volumes/Archive' });
const LARGE = [
  ['~/Movies/Final Cut/Project 2025.fcpbundle', 38600], ['~/Library/Application Support/MobileSync/Backup/00008130-…', 24600], ['~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw', 31000],
  ['~/Downloads/ubuntu-24.04.3-desktop-arm64.iso', 6100], ['~/GitHub/ml-lab/data/train.parquet', 5200], ['~/Desktop/Xcode_26.1.xip', 3400], ['~/Documents/Archive/2023-backup.zip', 2900],
];

// ---------- state ----------
const VIEWS = ['overview', 'clean', 'uninstall', 'purge', 'installer', 'analyze', 'status', 'optimize', 'history', 'protect', 'settings', 'tools', 'security'];
const S = {
  view: VIEWS.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'overview',
  scen: { cli: 'ok', fda: true, admin: false },
  mbTop: 'mem',
  smart: { phase: 'landing', freed: 0 },
  prog: { pct: 0, status: '', step: 0 },
  clean: { phase: 'idle', sel: new Set(CLEAN_ITEMS.filter(selectable).map(i => i.id)), open: new Set(['dev', 'user']), progress: 0, result: null },
  un: { phase: 'landing', q: '', sort: 'size', src: 'Усі', sel: new Set(['ps', 'zoom']), focus: 'ps', perm: false, done: null },
  purge: { phase: 'landing', sel: new Set(ARTS.filter(artDefault).map(a => a.id)), empty: false },
  inst: { phase: 'landing', sel: new Set(INST.filter(i => i.id !== 'i7').map(i => i.id)) },
  an: { phase: 'landing', path: [], vol: 'hd', mode: 'sun' },
  sec: { phase: 'landing', scope: 'quick', clam: false, sel: new Set(), q: [] },
  opt: { phase: 'landing', excl: new Set(['disk_verify']), out: null, verify: false },
  hist: { f: 'all', open: 'h1' },
  prot: { tab: 'clean', off: new Set(), custom: ['~/Library/Caches/com.figma.Desktop', '~/Work/fixtures/.cache'], purgePaths: ['~/Projects', '~/GitHub', '~/dev'], optPaths: ['/Volumes/mail'] },
  set: { menubar: true, login: true, notify: true, schedule: 'weekly', mcp: false, debug: false, oplog: true, touchid: false, autoNora: true, autoMole: true, mbMode: 'cpu' },
  drawer: { open: false, cmd: '', lines: [], state: '', timer: null, onStop: null },
  mb: false, scenOpen: false, palIdx: 0,
};

// ---------- live metrics (random walk) ----------
const N = 60;
const live = {
  cpu: Array.from({ length: N }, (_, i) => 22 + 10 * Math.sin(i / 6) + Math.random() * 8),
  mem: Array.from({ length: N }, () => 58 + Math.random() * 2),
  down: Array.from({ length: N }, (_, i) => Math.max(0.02, 0.5 + 0.45 * Math.sin(i / 4) + Math.random() * 0.4)),
  up: Array.from({ length: N }, () => 0.05 + Math.random() * 0.12),
  rd: Array.from({ length: N }, () => 1 + Math.random() * 6),
  wr: Array.from({ length: N }, () => 4 + Math.random() * 20),
  cores: Array.from({ length: 14 }, (_, i) => (i < 10 ? 30 : 10) + Math.random() * 40),
  gpu: 12, temp: 58, fan: 1200, batt: 87, health: 92, swap: 1.3,
  // memory by app: helper processes are counted into the .app that owns them
  apps: [['Docker Desktop', 9, 3.4], ['Visual Studio Code', 12, 2.6], ['Google Chrome', 17, 2.1]],
  procs: [
    ['Code Helper (Renderer)', 4242, 104.0, 1.9], ['WindowServer', 155, 21.3, 0.6], ['Google Chrome Helper', 3110, 18.6, 1.2], ['mds_stores', 412, 11.2, 0.3],
    ['Docker Desktop', 2088, 7.9, 3.4], ['Slack Helper', 2771, 4.1, 0.8], ['Telegram', 1904, 2.3, 0.5], ['kernel_task', 0, 2.1, 0.2],
  ],
};
function tick() {
  const w = (arr, v, lo, hi) => { arr.push(clamp(v, lo, hi)); arr.shift(); };
  const last = a => a[a.length - 1];
  w(live.cpu, last(live.cpu) + (Math.random() - 0.5) * 9, 6, 96);
  w(live.mem, last(live.mem) + (Math.random() - 0.5) * 0.8, 48, 82);
  w(live.down, Math.abs(last(live.down) + (Math.random() - 0.48) * 0.35), 0.01, 4);
  w(live.up, Math.abs(last(live.up) + (Math.random() - 0.5) * 0.06), 0.01, 0.6);
  w(live.rd, Math.abs(last(live.rd) + (Math.random() - 0.5) * 3), 0.2, 40);
  w(live.wr, Math.abs(last(live.wr) + (Math.random() - 0.5) * 8), 0.5, 90);
  live.cores = live.cores.map((c, i) => clamp(c + (Math.random() - 0.5) * 18, 2, i < 10 ? 100 : 70));
  live.gpu = clamp(live.gpu + (Math.random() - 0.5) * 6, 2, 80);
  live.temp = clamp(live.temp + (Math.random() - 0.5) * 1.4, 44, 78);
  live.fan = Math.round(clamp(live.fan + (Math.random() - 0.5) * 120, 0, 3800));
  live.procs.forEach(p => { p[2] = clamp(p[2] + (Math.random() - 0.5) * (p[2] > 50 ? 8 : 3), 0.1, 160); });
  live.health = Math.round(clamp(96 - last(live.cpu) * 0.08 - (last(live.mem) - 50) * 0.12, 70, 98));
  document.querySelectorAll('[data-live]').forEach(el => { const f = LIVE[el.dataset.live]; if (f) el.innerHTML = f(); });
}

// ---------- charts ----------
function spark(vals, { w = 240, h = 46, max, color = 'var(--accent)', id = 's' } = {}) {
  const m = max || Math.max(...vals) * 1.15 || 1;
  const pts = vals.map((v, i) => [i / (vals.length - 1) * w, h - 2 - v / m * (h - 6)]);
  const d = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
  const end = pts[pts.length - 1];
  return `<svg viewBox="0 0 ${w} ${h}" width="100%" height="${h}" preserveAspectRatio="none" aria-hidden="true" style="display:block">
    <line x1="0" x2="${w}" y1="${h / 2}" y2="${h / 2}" stroke="var(--line)" stroke-width="1" stroke-dasharray="2 4" vector-effect="non-scaling-stroke"/>
    <path d="${d} L${w} ${h} L0 ${h}Z" fill="${color}" opacity=".13"/>
    <path d="${d}" fill="none" stroke="${color}" stroke-width="1.6" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>
    <circle cx="${end[0]}" cy="${end[1]}" r="2.6" fill="${color}" vector-effect="non-scaling-stroke"/></svg>`;
}
function ring(v, { size = 76, stroke = 7, color = 'var(--good)', label = '', sub = '' } = {}) {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  return `<div class="ring" style="width:${size}px;height:${size}px"><svg width="${size}" height="${size}" aria-hidden="true">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--surface-2)" stroke-width="${stroke}"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="${stroke}" stroke-linecap="round" stroke-dasharray="${(v / 100 * c).toFixed(1)} ${c.toFixed(1)}"/></svg>
    <div class="rv"><b style="font-size:${Math.round(Math.min(22, size * 0.3))}px">${label}</b>${sub ? `<small>${sub}</small>` : ''}</div></div>`;
}
const healthCol = h => h >= 85 ? 'var(--good)' : h >= 65 ? 'var(--warn)' : 'var(--crit)';
const healthWord = h => h >= 85 ? 'Добрий стан' : h >= 65 ? 'Є навантаження' : 'Потрібна увага';

// ---------- derived numbers ----------
const cleanTotal = () => sum(CLEAN_ITEMS.filter(i => S.clean.sel.has(i.id) && (i.sec !== 'sys' || S.scen.admin)), i => i.mb);
const cleanAvail = () => sum(CLEAN_ITEMS.filter(i => selectable(i) && (i.sec !== 'sys' || S.scen.admin)), i => i.mb);
const purgeTotal = () => sum(ARTS.filter(a => S.purge.sel.has(a.id)), a => a.mb);
const instTotal = () => sum(INST.filter(i => S.inst.sel.has(i.id)), i => i.mb);
const smartSafe = () => cleanAvail() + sum(ARTS.filter(artDefault), a => a.mb) + instTotal();

// ---------- console runner (simulated PTY) ----------
const L = (c, s) => ({ c, s });
function run(command, lines, { onLine, onDone, onStop, speed = 120 } = {}) {
  const d = S.drawer; clearTimeout(d.timer);
  Object.assign(d, { cmd: command, lines: [], state: 'run', onStop });
  let i = 0;
  const step = () => {
    if (d.state !== 'run') return;
    if (i < lines.length) { const ln = lines[i]; d.lines.push(ln); onLine && onLine(i, ln); i++; paintDrawer(); d.timer = setTimeout(step, speed + Math.random() * speed); }
    else { d.state = 'done'; d.lines.push(L('m', '— процес завершився з кодом 0')); paintDrawer(); onDone && onDone(); }
  };
  paintDrawer(); step();
}
function paintDrawer() {
  const d = S.drawer;
  $('#drawerCmd').textContent = d.cmd ? '$ ' + d.cmd : 'Консоль Mole — тут видно кожну команду, яку запускає Nora';
  $('#drawerState').innerHTML = d.state === 'run' ? '<span class="row" style="gap:6px"><span class="spin"></span>виконується</span>' : d.state === 'done' ? 'завершено' : d.state === 'stopped' ? 'зупинено' : '';
  $('#stopBtn').hidden = d.state !== 'run';
  $('#drawerBtn').classList.toggle('on', d.state === 'run');
  $('#drawerBody').innerHTML = d.lines.length ? d.lines.map(l => `<span class="${l.c}">${esc(l.s)}</span>`).join('\n') : '<span class="m">Поки що нічого не запускалося.</span>';
  const b = $('#drawerBody'); b.scrollTop = b.scrollHeight;
}
function setDrawer(open) { S.drawer.open = open; $('#drawer').hidden = !open; $('#drawerBtn').setAttribute('aria-pressed', open); if (open) paintDrawer(); }

// ---------- modules: neon scenes ----------
const MODS = {
  overview: { n: 'Розумний догляд', hero: 'vessel', c: ['#ff3ea5', '#6b22d9', '#17062f'], ic: 'i-overview' },
  clean: { n: 'Очищення', hero: 'clean', c: ['#1fe6a2', '#0d7d63', '#04201f'], ic: 'i-clean' },
  uninstall: { n: 'Програми', hero: 'uninstall', c: ['#38c8ff', '#2f3fe0', '#0b0a40'], ic: 'i-uninstall' },
  optimize: { n: 'Швидкодія', hero: 'optimize', c: ['#ffa53a', '#e2491d', '#360b0c'], ic: 'i-optimize' },
  analyze: { n: 'Аналіз диска', hero: 'analyze', c: ['#b34dff', '#5214cf', '#14053c'], ic: 'i-analyze' },
  status: { n: 'Стан системи', hero: 'status', c: ['#ff3d7f', '#3d1fb0', '#0c0a2c'], ic: 'i-status' },
  purge: { n: 'Проєкти', hero: 'purge', c: ['#ffc23a', '#e8662a', '#38110a'], ic: 'i-purge' },
  installer: { n: 'Інсталятори', hero: 'installer', c: ['#27ecd2', '#1572b3', '#061f3a'], ic: 'i-installer' },
  protect: { n: 'Захист', hero: 'protect', c: ['#36e2c2', '#13708a', '#071d2d'], ic: 'i-shield' },
  tools: { n: 'Інструменти', hero: 'settings', c: ['#a35cff', '#3f1a8c', '#13072a'], ic: 'i-tools' },
  history: { n: 'Історія', hero: 'history', c: ['#6a5cff', '#2b1c86', '#0d0a27'], ic: 'i-history' },
  security: { n: 'Безпека', hero: 'security', c: ['#ff3d6e', '#8a1fb8', '#1a0620'], ic: 'i-shield' },
  settings: { n: 'Налаштування', hero: 'settings', c: ['#8e86ff', '#35296f', '#110d29'], ic: 'i-settings' },
};
const RAIL = ['overview', 'clean', 'uninstall', 'optimize', 'analyze', 'status', 'security', null, 'tools', 'history'];
const LAND = {
  overview: ['Одна перевірка охоплює кеші, проєкти, інсталятори й великі файли. Нічого не видаляється без вашого перегляду.', [['i-clean', 'Кеші та журнали'], ['i-purge', 'Артефакти проєктів'], ['i-installer', 'Забуті інсталятори'], ['i-analyze', 'Великі й старі файли']]],
  clean: ['Приберіть кеші, журнали й залишки видалених програм. Кожен шлях можна переглянути до видалення.', [['i-clean', 'Кеші програм і браузерів'], ['i-purge', 'Інструменти розробника'], ['i-uninstall', 'Залишки видалених програм'], ['i-history', 'Журнали й Кошик']]],
  uninstall: ['Видаляйте програми разом із кешами, налаштуваннями та службами запуску. Особисті дані залишаються.', [['i-uninstall', 'Повне видалення із залишками'], ['i-folder', 'App Store, Homebrew і Steam'], ['i-shield', 'Спільні дані не чіпаються']]],
  optimize: ['DNS, Spotlight, кеш Finder, бази даних і мережа. Mole пропускає те, що зараз не потрібно.', [['i-optimize', '20 задач обслуговування'], ['i-rocket', 'Зламані об’єкти автозапуску'], ['i-status', 'Діагностика продуктивності']]],
  analyze: ['Подивіться, що займає місце, і перейдіть у будь-яку теку кількома кліками.', [['i-analyze', 'Карта сховища'], ['i-folder', 'Великі файли'], ['i-warn', 'Старі завантаження й резервні копії']]],
  purge: ['node_modules, target, build, .venv — усе, що відновлюється наступним збиранням.', [['i-purge', 'Групування за проєктами'], ['i-lock', 'Активні проєкти не чіпаються'], ['i-shield', 'Теки під Git захищені']]],
  security: ['Перевірка на вимогу: автозапуск, підписи й нотаризація програм, правила Apple XProtect і рушій ClamAV. Без захисту в реальному часі — лише чесні сигнали для перегляду.', [['i-rocket', 'Автозапуск і фонові служби'], ['i-check', 'Підписи й нотаризація'], ['i-shield', 'Правила Apple XProtect'], ['i-search', 'Рушій ClamAV']]],
  installer: ['Образи й пакети, які лишилися після встановлення програм.', [['i-installer', 'DMG, PKG, ISO, XIP, ZIP'], ['i-folder', 'Завантаження, iCloud, Пошта, Telegram'], ['i-check', 'Повторна перевірка перед видаленням']]],
};

// ---------- building blocks ----------
const glassSrc = k => `assets/glass/${k}.webp`;
const animPhase = () => { const t = performance.now() / 1000; return `--d6:-${(t % 6).toFixed(3)}s;--d14:-${(t % 1.4).toFixed(3)}s;--d11:-${(t % 1.1).toFixed(3)}s`; };
const hero = (key, st = 'idle', size = 0) => `<div class="hero3d" data-state="${st}" style="${animPhase()}${size ? `;width:${size}px;height:${size}px` : ''}"><img src="${glassSrc(key)}" alt="" draggable="false"></div>`;
const scanBtn = (label, action, busy, pct = 0, sub = '', inline = false) => `<div class="scan-wrap ${inline ? 'inline' : ''}"><button class="scan-btn ${busy ? 'busy' : ''}" data-a="${action}" style="--p:${Math.round(pct)}">${label}</button>${sub ? `<span class="scan-sub">${sub}</span>` : ''}</div>`;
function landing(key, o = {}) {
  const m = MODS[key], [lead, bl] = LAND[key], busy = !!o.busy, step = o.step ?? 0;
  return `<section class="landing ${busy ? '' : 'fade-in'}">${hero(m.hero, busy ? 'work' : 'idle')}
    <div><h1 class="title">${m.n}</h1>
      ${busy ? `<p class="status-line"><span class="spin"></span><span class="st-txt">${esc(o.status || 'Сканую…')}</span></p>` : `<p class="lead">${lead}</p>`}
      <ul class="bullets">${bl.map(([i, t], k) => `<li data-ic="${i}" style="${busy && k > step ? 'opacity:.45' : ''}"><span class="bico">${ic(busy && k < step ? 'i-check' : i)}</span>${t}</li>`).join('')}</ul>
      ${busy ? '' : o.extra || ''}</div></section>
    ${scanBtn(busy ? 'Стоп' : o.label || 'Сканувати', busy ? 'stopRun' : o.action, busy, S.prog.pct, busy ? `${Math.round(S.prog.pct)} %` : o.sub || '')}`;
}
const resHead = (key, title, sub, right = '', st = 'idle') => `<div class="res-head fade-in">${hero(MODS[key].hero, st)}<div class="sp"><h1 class="res-title">${title}</h1>${sub ? `<p>${sub}</p>` : ''}</div>${right}</div>`;
const donePanel = (key, big, sub, extra = '') => `<div class="panel done fade-in">${hero(MODS[key].hero, 'done')}<div>
  <h1 class="title" style="font-size:36px">Роботу виконано!</h1><div class="bigstat">${big}</div><div class="dim" style="margin-top:8px;font-size:15px">${sub}</div>${extra}
  <div class="row" style="margin-top:28px;flex-wrap:wrap"><button class="btn ghost" data-a="drawer">${ic('i-term')}Переглянути лог</button><span class="sp"></span><button class="btn primary" data-a="doneOk" data-v="${key}">OK</button></div></div></div>`;
function progress(i, n, status, step) {
  S.prog = { pct: (i + 1) / n * 100, status, step };
  const btn = document.querySelector('.scan-btn.busy');
  if (!btn) { render(true); return; }
  const pct = Math.round(S.prog.pct);
  btn.style.setProperty('--p', pct);
  const sub = document.querySelector('.scan-wrap .scan-sub'); if (sub) sub.textContent = pct + ' %';
  const st = document.querySelector('.status-line .st-txt'); if (st && status) st.textContent = status;
  if (step != null) document.querySelectorAll('.landing .bullets li').forEach((li, k) => {
    li.style.opacity = k > step ? '.45' : '';
    const want = k < step ? 'i-check' : li.dataset.ic;
    if (li.dataset.shown !== want) { li.dataset.shown = want; li.querySelector('.bico').innerHTML = ic(want); }
  });
}


// ---------- security (on-demand scan; never pre-selects findings) ----------
const SEC_FIND = [
  { id: 'f1', sev: 'crit', t: 'com.mac.updater.helper', p: '~/Library/LaunchAgents/com.mac.updater.helper.plist', why: 'Запускає непідписаний файл із /tmp і зараз завантажений', src: 'Аудит автозапуску', loaded: true },
  { id: 'f2', sev: 'crit', t: 'Setup_Player_Pro.dmg', p: '~/Downloads/Setup_Player_Pro.dmg', why: 'ClamAV: Osx.Adware.Bundlore', src: 'ClamAV 1.5.4' },
  { id: 'f3', sev: 'warn', t: 'SearchHelper.app', p: '~/Applications/SearchHelper.app', why: 'Збіг із правилом Apple XProtect (сімейство Adload)', src: 'Apple XProtect' },
  { id: 'f4', sev: 'warn', t: 'Free Video Converter.app', p: '/Applications/Free Video Converter.app', why: 'Підпис дійсний, але програма не нотаризована Apple', src: 'Gatekeeper' },
  { id: 'f5', sev: 'info', t: 'Розширення Chrome «Coupon Finder»', p: '~/Library/Application Support/Google/Chrome/Default/Extensions/…', why: 'Має доступ до всіх сайтів; встановлено не з Chrome Web Store', src: 'Аудит розширень' },
];
const SEV = { crit: ['crit', 'Небезпечно'], warn: ['warn', 'Підозріло'], info: ['neutral', 'До уваги'] };
function vSecurity() {
  const x = S.sec;
  const engines = `<div class="land-opts">
    <div class="tabs">${[['quick', 'Швидка'], ['full', 'Повна']].map(([k, n]) => `<button aria-selected="${x.scope === k}" data-a="secScope" data-v="${k}">${n}</button>`).join('')}</div>
    <div class="land-opt">${ic('i-search')}<span class="sp">${x.clam ? 'ClamAV 1.5.4 · бази оновлено сьогодні' : 'ClamAV не встановлено <span class="muted">· ≈110 МБ баз</span>'}</span>${x.clam ? '<span class="pill good">готово</span>' : '<button class="btn sm" data-a="secInstall">Встановити</button>'}</div>
    <div class="note">${x.scope === 'quick' ? 'Автозапуск, програми, Завантаження й Робочий стіл' : 'Уся домашня тека, крім хмарних файлів, що ще не завантажені'}. Перевірка на вимогу — без захисту в реальному часі.</div></div>`;
  if (x.phase === 'landing') return landing('security', { action: 'secScan', extra: engines });
  if (x.phase === 'scan' || x.phase === 'run') return landing('security', { busy: true, status: S.prog.status, step: S.prog.step });
  if (x.phase === 'done') return donePanel('security', `${x.moved} у карантині`, 'файли можна відновити з карантину будь-коли', `<div class="note" style="margin-top:10px">Перед переміщенням агент автозапуску вивантажено (<span class="mono">launchctl bootout</span>).</div>`);
  const list = SEC_FIND.filter(f => !x.q.includes(f.id));
  return `${resHead('security', `${list.length} знахідок для перегляду`, 'Жодна знахідка не позначена автоматично. Це сигнали, а не вирок: перевірте кожну.', `<button class="btn sm" data-a="secQuar">Карантин (${x.q.length})</button>`)}
  <div class="row fade-in" style="flex-wrap:wrap;gap:6px;margin-bottom:12px"><span class="pill good">${ic('i-check')}Аудит: 64 елементи автозапуску</span><span class="pill good">${ic('i-check')}Підписи: 212 програм</span><span class="pill good">${ic('i-check')}XProtect: 506 правил</span>${x.clam ? `<span class="pill good">${ic('i-check')}ClamAV: 18 412 файлів</span>` : '<span class="pill neutral">ClamAV не встановлено</span>'}</div>
  <div class="list fade-in">${list.map(f => `<div class="app" style="grid-template-columns:auto minmax(0,1fr) auto auto;cursor:default">
      <input type="checkbox" class="cb" aria-label="${esc(f.t)}" data-a="secCheck" data-v="${f.id}" ${x.sel.has(f.id) ? 'checked' : ''}>
      <div class="ell"><b>${esc(f.t)}</b> <span class="pill ${SEV[f.sev][0]}">${SEV[f.sev][1]}</span>${f.loaded ? ' <span class="pill warn">завантажений</span>' : ''}<div class="meta"><span>${esc(f.why)}</span></div><div class="mono muted ell" style="font-size:11px">${esc(f.p)}</div></div>
      <span class="tag">${f.src}</span><span class="row" style="gap:2px"><button class="iconbtn" title="Показати у Finder" data-a="toast" data-v="Відкрито у Finder">${ic('i-eye')}</button><button class="iconbtn" title="Ігнорувати" data-a="toast" data-v="Додано до винятків">${ic('i-x')}</button></span></div>`).join('') || '<div class="empty">Знахідок немає</div>'}</div>
  <div class="actionbar"><span class="tot">${x.sel.size ? `${x.sel.size} обрано` : 'Нічого не обрано'}</span><span class="dim">карантин зберігає шлях, власника й права для відновлення</span><span class="sp"></span><button class="btn danger" data-a="secMove" ${x.sel.size ? '' : 'disabled'}>${ic('i-shield')}У карантин</button></div>`;
}

// ---------- overview: smart care ----------
const SMART = [['mo clean --dry-run', 'Кеші та журнали'], ['mo purge --dry-run', 'Артефакти проєктів'], ['mo installer --dry-run', 'Інсталятори'], ['mo analyze --json ~', 'Великі й старі файли']];
function vOverview() {
  const sm = S.smart;
  if (sm.phase === 'landing') return landing('overview', { action: 'smart', sub: 'лише перегляд' });
  if (sm.phase === 'run') return landing('overview', { busy: true, status: S.prog.status, step: S.prog.step });
  if (sm.phase === 'done') return donePanel('overview', mb(sm.freed), 'звільнено безпечно · кеші, артефакти проєктів та інсталятори', `<div class="note" style="margin-top:10px">Великі файли Nora не чіпає автоматично — їх варто переглянути в «Аналізі диска».</div>`);
  const tiles = [['clean', 'Кеші та журнали', cleanAvail()], ['purge', 'Артефакти проєктів', sum(ARTS.filter(artDefault), a => a.mb)], ['installer', 'Інсталятори', instTotal()], ['analyze', 'Великі й старі файли', 42800]];
  const total = 994700, free = 302100, recl = smartSafe();
  const segs = [['Програми', 64800, 'var(--c3)'], ['Система', 52300, 'var(--c7)'], ['Інше', 120900, 'var(--c6)'], ['Бібліотека', 168200 - cleanAvail(), 'var(--c2)'], ['Домашня тека', 286400 - (recl - cleanAvail()), 'var(--c1)'], ['Можна звільнити', recl, 'repeating-linear-gradient(135deg,#ffd27a 0 4px,#ffb02e 4px 8px)']];
  return `<div class="fade-in">${resHead('overview', `Можна звільнити ${mb(recl)}`, 'Перегляньте категорію або запустіть безпечне очищення всього одразу.', `<span class="pill good">${ic('i-check')}перевірено щойно</span>`, sm.phase === 'runall' ? 'work' : 'idle')}
  <div class="panel" style="padding:18px;margin-bottom:14px"><div class="row" style="margin-bottom:10px"><b>Macintosh HD</b><span class="sp"></span><span class="dim num">${mb(total - free)} з ${mb(total)} використано</span></div>
    <div class="catbar" style="height:16px;border-radius:8px">${segs.map(([n, v, c]) => `<i title="${n}: ${mb(v)}" style="flex:${v};background:${c}"></i>`).join('')}<i style="flex:${free};background:rgba(255,255,255,.12)" title="Вільно: ${mb(free)}"></i></div>
    <div class="row" style="flex-wrap:wrap;gap:6px 16px;margin-top:10px;font-size:12px">${segs.map(([n, v, c]) => `<span class="row" style="gap:6px"><s style="width:9px;height:9px;border-radius:3px;background:${c}"></s>${n}</span>`).join('')}<span class="row muted" style="gap:6px"><s style="width:9px;height:9px;border-radius:3px;background:rgba(255,255,255,.2)"></s>Вільно ${mb(free)}</span></div></div>
  <div class="tiles4">${tiles.map(([k, n, v]) => { const src = glassSrc(MODS[k].hero); return `<button class="tile" data-a="go" data-v="${k}">${src ? `<img src="${src}" alt="">` : `<span class="bico">${ic(MODS[k].ic)}</span>`}<small>${n}</small><b>${mb(v)}</b><span class="row dim" style="gap:4px;font-size:12px">Переглянути${ic('i-chev')}</span></button>`; }).join('')}</div>
  ${scanBtn(sm.phase === 'runall' ? 'Стоп' : 'Запустити', sm.phase === 'runall' ? 'stopRun' : 'smartAll', sm.phase === 'runall', S.prog.pct, sm.phase === 'runall' ? `${Math.round(S.prog.pct)} %` : 'кеші, проєкти й інсталятори', true)}</div>`;
}

// ---------- clean ----------
function vClean() {
  const c = S.clean;
  if (c.phase === 'idle') return landing('clean', { action: 'cleanScan', extra: `<div class="land-opts">
    <label class="land-opt"><input type="checkbox" class="sw" data-a="cleanOptSys" ${S.scen.admin ? 'checked' : ''}><span class="sp">Системні кеші <span class="muted">· потрібен Touch ID або пароль</span></span></label>
    <label class="land-opt"><input type="checkbox" class="sw" data-a="cleanTrash" ${c.sel.has('u3') ? 'checked' : ''}><span class="sp">Очистити Кошик</span></label></div>` });
  if (c.phase === 'scan' || c.phase === 'run') return landing('clean', { busy: true, status: S.prog.status, step: S.prog.step });
  if (c.phase === 'done') { const r = c.result; return donePanel('clean', mb(r.freed), `звільнено · ${r.items} позицій · ${r.cats} категорій`, `<dl class="kv" style="max-width:360px;margin-top:16px"><dt>Вільно зараз</dt><dd>${mb(302100 + r.freed)}</dd><dt>Пропущено</dt><dd>1 · pnpm зайнятий</dd><dt>Whitelist</dt><dd>відновлено</dd></dl>`); }
  const selTotal = cleanTotal(), unchecked = CLEAN_ITEMS.filter(i => selectable(i) && !c.sel.has(i.id) && (i.sec !== 'sys' || S.scen.admin)).length;
  const secTot = s => sum(s.items.filter(i => c.sel.has(i.id)), i => i.mb);
  const cats = CLEAN.filter(s => (!s.sudo || S.scen.admin) && secTot(s) > 0), cols = ['var(--c1)', 'var(--c2)', 'var(--c3)', 'var(--c4)', 'var(--c5)', 'var(--c6)', 'var(--c7)', 'var(--c1)', 'var(--c2)'];
  return `${resHead('clean', 'Перегляд перед очищенням', `${CLEAN_ITEMS.length} позицій у ${CLEAN.length} розділах. Зніміть позначку з того, що хочете залишити.`, `<button class="btn sm" data-a="cleanScan">${ic('i-refresh')}Пересканувати</button>`)}
  <div class="split fade-in"><div>
    ${CLEAN.map(s => {
      const locked = s.sudo && !S.scen.admin, its = s.items, selN = its.filter(i => c.sel.has(i.id)).length, selableN = its.filter(selectable).length;
      const st = selN === 0 ? '' : selN === selableN ? 'checked' : 'data-ind="1"';
      return `<div class="sec ${c.open.has(s.id) ? 'open' : ''}"><div class="sec-h" data-a="secToggle" data-v="${s.id}">${ic('i-chev', 'chev')}
        ${locked ? `<span class="muted">${ic('i-lock')}</span>` : `<input type="checkbox" class="cb" aria-label="Увесь розділ ${esc(s.name)}" data-a="secCheck" data-v="${s.id}" ${st}>`}
        <h4 class="sp">${s.name}</h4><span class="muted" style="font-size:12px">${locked ? 'потрібні права адміністратора' : `${selN} з ${its.length}`}</span><span class="sz">${locked ? '' : mb(secTot(s))}</span></div>
        <div class="sec-b">${locked ? `<div class="locked">${ic('i-lock')}<div class="sp"><b>Без прав адміністратора системні шляхи не скануються</b><div class="note">Nora виконає <span class="mono">sudo -A -v</span> у тій самій сесії, що й Mole. Пароль не зберігається.</div></div><button class="btn sm primary" data-a="auth" data-v="cleanSys">${ic('i-touch')}Дозволити</button></div>` :
        its.map(i => { const dis = !selectable(i); return `<div class="item">
          <input type="checkbox" class="cb" aria-label="${esc(i.label)}" data-a="itemCheck" data-v="${i.id}" ${c.sel.has(i.id) ? 'checked' : ''} ${dis ? 'disabled' : ''}>
          <span class="lbl ell">${esc(i.label)} ${i.prot ? `<span class="pill neutral">${ic('i-shield')}${i.prot}</span>` : ''}${i.skip ? `<span class="pill warn">${i.skip}</span>` : ''}${i.unknown ? '<span class="pill neutral">розмір невідомий</span>' : ''}</span>
          <span class="sz num">${i.mb != null ? mb(i.mb) : '—'}</span>
          <span class="acts"><button class="iconbtn" title="Показати у Finder" data-a="toast" data-v="Відкрито у Finder: ${esc(i.path)}">${ic('i-eye')}</button>${dis ? '' : `<button class="iconbtn" title="Завжди захищати" data-a="protectItem" data-v="${i.id}">${ic('i-shield')}</button>`}</span>
          <span class="path" title="${esc(i.path)}">${esc(i.path)}</span></div>`; }).join('')}</div></div>`; }).join('')}
  </div>
  <aside class="card sticky"><div class="eyebrow">Буде очищено</div><div class="bigstat" style="margin:8px 0 14px">${mb(selTotal)}</div>
    <div class="catbar">${cats.map((s, i) => `<i style="flex:${secTot(s)};background:${cols[i]}" title="${esc(s.name)}"></i>`).join('')}</div>
    <div class="legend" style="margin-top:12px">${cats.map((s, i) => `<div><s style="background:${cols[i]}"></s><span class="sp ell">${s.name}</span><span class="num dim">${mb(secTot(s))}</span></div>`).join('')}</div>
    <div class="hr"></div><div class="note">${unchecked ? `${unchecked} знятих позицій буде тимчасово захищено на час запуску.` : 'Позначено все доступне.'}</div>
    <button class="btn primary" style="width:100%;margin-top:14px;height:40px" data-a="cleanConfirm" ${selTotal ? '' : 'disabled'}>${ic('i-clean')}Очистити ${mb(selTotal)}</button>
    <div style="margin-top:10px;text-align:center">${cmd(S.scen.admin ? 'sudo -A -v && mo clean' : 'mo clean')}</div></aside></div>`;
}

// ---------- uninstall ----------
function vUninstall() {
  const u = S.un;
  if (u.phase === 'landing') return landing('uninstall', { action: 'unScan' });
  if (u.phase === 'scan' || u.phase === 'run') return landing('uninstall', { busy: true, status: S.prog.status, step: S.prog.step });
  if (u.phase === 'done') return donePanel('uninstall', `${u.done.n} ${u.done.n === 1 ? 'програму' : 'програми'}`, `успішно видалено · ${mb(u.done.mb)} ${S.un.perm ? 'остаточно' : 'у Кошику'}`,
    u.done.refs.length ? `<div class="card" style="margin-top:16px;padding:14px"><b>Згадки в конфігураціях</b><div class="note">Mole їх не редагує — перевірте вручну:</div>${u.done.refs.map(r => `<div class="mono" style="margin-top:4px">${esc(r)}</div>`).join('')}</div>` : '');
  let apps = APPS.filter(a => (u.src === 'Усі' || a.src === u.src) && a.name.toLowerCase().includes(u.q.toLowerCase()));
  apps.sort(u.sort === 'size' ? (a, b) => b.mb - a.mb : u.sort === 'name' ? (a, b) => a.name.localeCompare(b.name) : (a, b) => b.d - a.d);
  const f = APPS.find(a => a.id === u.focus) || apps[0], sel = APPS.filter(a => u.sel.has(a.id)), total = sum(sel, a => appFiles(a).total), fl = f ? appFiles(f) : null;
  return `${resHead('uninstall', `${APPS.length} програм · ${mb(sum(APPS, a => a.mb))}`, 'Оберіть програми — праворуч видно, що саме буде видалено.')}
  <div class="row fade-in" style="flex-wrap:wrap;margin-bottom:12px"><input class="field" id="unQ" style="width:220px" placeholder="Пошук програм" value="${esc(u.q)}" data-a="unQ">
    <div class="tabs">${['Усі', 'App Store', 'Homebrew', 'Вручну', 'Steam'].map(s => `<button aria-selected="${u.src === s}" data-a="unSrc" data-v="${s}">${s}</button>`).join('')}</div><span class="sp"></span>
    <select class="field" id="unSort" data-a="unSort" aria-label="Сортування"><option value="size" ${u.sort === 'size' ? 'selected' : ''}>За розміром</option><option value="name" ${u.sort === 'name' ? 'selected' : ''}>За назвою</option><option value="used" ${u.sort === 'used' ? 'selected' : ''}>Давно не відкривали</option></select></div>
  <div class="split fade-in"><div class="list">${apps.map(a => `<div class="app ${a.id === u.focus ? 'focus' : ''}" data-a="unFocus" data-v="${a.id}">
      <input type="checkbox" class="cb" aria-label="Обрати ${esc(a.name)}" data-a="unCheck" data-v="${a.id}" ${u.sel.has(a.id) ? 'checked' : ''}>
      <span class="appico" style="background:${grad(a.name)}">${initials(a.name)}</span>
      <div class="ell"><b>${esc(a.name)}</b><div class="meta"><span>${a.src}</span><span>відкривали ${a.used}</span>${a.d > 90 ? '<span class="pill amber">давно не використовується</span>' : ''}</div></div>
      <span class="sz num">${mb(a.mb)}</span></div>`).join('') || '<div class="empty">Нічого не знайдено</div>'}</div>
  ${f ? `<aside class="card sticky"><div class="row" style="gap:12px"><span class="appico lg" style="background:${grad(f.name)}">${initials(f.name)}</span><div class="sp ell"><h3 style="font-size:16px">${esc(f.name)}</h3><div class="mono muted ell">${esc(f.bid)}</div></div></div>
    <div class="hr"></div><div class="eyebrow" style="margin-bottom:6px">Буде видалено · ${mb(fl.total)}</div>
    ${fl.groups.map(g => `<div class="fgroup"><h5><span class="sp">${g.t}</span><span class="num">${g.mb ? mb(g.mb) : ''}</span></h5>${g.files.map(p => `<div class="p" title="${esc(p)}">${esc(p)}</div>`).join('')}</div>`).join('')}
    <div class="hr"></div><div class="eyebrow" style="margin-bottom:6px">Особисті дані — залишаться</div>
    ${fl.kept.map(p => `<div class="fgroup" style="border:0;padding:1px 0"><div class="p">${esc(p)}</div></div>`).join('')}
    <button class="btn ghost sm" style="margin-top:8px" data-a="personalData">Обрати особисті дані…</button></aside>` : ''}</div>
  <div class="actionbar"><span class="tot">${sel.length ? `${sel.length} · ${mb(total)}` : 'Нічого не обрано'}</span>
    <div class="tabs"><button aria-selected="${!u.perm}" data-a="unPerm" data-v="0">У Кошик</button><button aria-selected="${u.perm}" data-a="unPerm" data-v="1">Остаточно</button></div>
    <span class="sp"></span><button class="btn" data-a="unDry" ${sel.length ? '' : 'disabled'}>Перегляд</button><button class="btn ${u.perm ? 'danger' : 'primary'}" data-a="unConfirm" ${sel.length ? '' : 'disabled'}>${ic('i-uninstall')}Видалити</button></div>`;
}
const unCmd = () => 'mo uninstall ' + (S.un.perm ? '--permanent ' : '') + APPS.filter(a => S.un.sel.has(a.id)).map(a => `"${a.name}"`).join(' ');

// ---------- optimize ----------
function vOptimize() {
  const o = S.opt;
  if (o.phase === 'landing') return landing('optimize', { action: 'optScan' });
  if (o.phase === 'scan' || o.phase === 'run') return landing('optimize', { busy: true, status: S.prog.status, step: S.prog.step });
  if (o.phase === 'done') { const cnt = Object.values(o.out).reduce((m, [k]) => (m[k] = (m[k] || 0) + 1, m), {}); return donePanel('optimize', `${cnt.applied || 0} ${(cnt.applied || 0) === 1 ? 'задача' : 'задачі'}`, `застосовано · ${cnt.unchanged || 0} без змін · ${(cnt.skipped || 0) + (cnt.excluded || 0)} пропущено`, cnt.attention ? `<div class="banner" style="margin-top:14px">${ic('i-warn')}<span class="sp">Закрийте Safari, щоб оптимізувати бази даних</span></div>` : ''); }
  return `${resHead('optimize', 'Діагностика готова', 'Тривалих перевантажень CPU немає. Вимкніть задачі, які не хочете запускати.', `<span class="pill good">${OPT.length - o.excl.size} з ${OPT.length} увімкнено</span>`)}
  <div class="list fade-in">${OPT.map(([id, n, d]) => { const on = !o.excl.has(id), out = o.out && o.out[id];
    return `<div class="task"><input type="checkbox" class="sw" aria-label="${esc(n)}" data-a="optToggle" data-v="${id}" ${on ? 'checked' : ''}>
      <span class="ell"><b>${n}</b></span><span>${!on ? '<span class="pill neutral">вимкнено</span>' : out ? `<span class="pill ${OUT_PILL[out[0]][0]}" title="${esc(out[1])}">${out[0] === 'applied' ? 'буде застосовано' : OUT_PILL[out[0]][1]}</span>` : ''}</span>
      <span class="d">${out && on ? esc(out[1]) : d}</span></div>`; }).join('')}</div>
  <div class="actionbar"><label class="row" style="font-size:12.5px"><input type="checkbox" class="sw" data-a="optVerify" ${o.verify ? 'checked' : ''}>Перевіряти диск <span class="muted">(довго)</span></label><span class="sp"></span>${cmd((o.verify ? 'MOLE_ENABLE_DISK_VERIFY=1 ' : '') + 'mo optimize')}<button class="btn primary" data-a="optRun">${ic('i-optimize')}Оптимізувати</button></div>`;
}

// ---------- analyze ----------
function anRoot() { return S.an.vol === 'hd' ? DISK : EXT_DISK; }
function anNode() { let n = anRoot(); for (const i of S.an.path) n = n.kids[i]; return n; }
function arc(cx, cy, r0, r1, a0, a1) {
  const p = (r, a) => [cx + r * Math.cos(a), cy + r * Math.sin(a)], large = a1 - a0 > Math.PI ? 1 : 0;
  const [x0, y0] = p(r1, a0), [x1, y1] = p(r1, a1), [x2, y2] = p(r0, a1), [x3, y3] = p(r0, a0);
  return `M${x0.toFixed(2)} ${y0.toFixed(2)} A${r1} ${r1} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)} L${x2.toFixed(2)} ${y2.toFixed(2)} A${r0} ${r0} 0 ${large} 0 ${x3.toFixed(2)} ${y3.toFixed(2)}Z`;
}
function squarify(items, x, y, w, h) {
  const out = [], total = sum(items, i => i.v); if (!total || w <= 0 || h <= 0) return out;
  let rest = items.filter(i => i.v > 0).map(i => ({ ...i, a: i.v * w * h / total }));
  while (rest.length) {
    const short = Math.min(w, h), worst = r => { const s = sum(r, z => z.a), mx = Math.max(...r.map(z => z.a)), mn = Math.min(...r.map(z => z.a)); return Math.max(short * short * mx / (s * s), s * s / (short * short * mn)); };
    let row = [rest[0]], i = 1;
    while (i < rest.length && worst([...row, rest[i]]) <= worst(row)) { row.push(rest[i]); i++; }
    const s = sum(row, z => z.a);
    if (w >= h) { const cw = s / h; let cy = y; row.forEach(r => { const hh = r.a / cw; out.push({ ...r, x, y: cy, w: cw, h: hh }); cy += hh; }); x += cw; w -= cw; }
    else { const ch = s / w; let cx = x; row.forEach(r => { const ww = r.a / ch; out.push({ ...r, x: cx, y, w: ww, h: ch }); cx += ww; }); y += ch; h -= ch; }
    rest = rest.slice(i);
  }
  return out;
}
const AN_COL = ['var(--c1)', 'var(--c2)', 'var(--c3)', 'var(--c4)', 'var(--c5)', 'var(--c6)', 'var(--c7)', 'var(--c1)'];
function treemap(node) {
  const W = 600, H = 420, tiles = squarify((node.kids || []).map((k, i) => ({ k, i, v: k.s })).sort((p, q) => q.v - p.v), 0, 0, W, H);
  const lab = (t, x, y, w, h, big) => (w > 64 && h > (big ? 34 : 22)) ? `<text x="${x + 8}" y="${y + 17}" fill="#fff" style="font:600 ${big ? 12.5 : 11}px var(--f-ui)">${esc(t.k.n.length > w / 7 ? t.k.n.slice(0, Math.max(3, Math.floor(w / 7) - 1)) + '…' : t.k.n)}</text>${h > (big ? 40 : 34) ? `<text x="${x + 8}" y="${y + 32}" fill="#fff" fill-opacity=".8" style="font:11px var(--f-ui)">${mb(t.k.s)}${t.k.partial ? '+' : ''}</text>` : ''}` : '';
  const R = (u, rx) => `x="${(u.x + 1).toFixed(1)}" y="${(u.y + 1).toFixed(1)}" width="${Math.max(0, u.w - 2).toFixed(1)}" height="${Math.max(0, u.h - 2).toFixed(1)}" rx="${rx}"`;
  const body = tiles.map(t => {
    const col = AN_COL[t.i % AN_COL.length], b = { x: t.x + 1, y: t.y + 1, w: t.w - 2, h: t.h - 2 };
    const sub = t.k.kids && b.w > 40 && b.h > 50 ? squarify(t.k.kids.map((k, i) => ({ k, i, v: k.s })).sort((p, q) => q.v - p.v), b.x + 3, b.y + 22, b.w - 6, b.h - 25) : [];
    return `<g><rect class="hit" ${R(b, 8)} fill="${col}" fill-opacity="${t.k.unavailable ? .3 : .85}" ${t.k.kids ? `data-a="anIn" data-v="${t.i}"` : ''}><title>${esc(t.k.n)} · ${mb(t.k.s)}</title></rect>
      ${sub.map(u => `<rect ${R(u, 4)} fill="${col}" fill-opacity="${u.k.insight || u.k.clean ? 1 : .6}"/><rect ${R(u, 4)} fill="url(#cush)" pointer-events="none"/>${u.k.insight || u.k.clean ? `<rect ${R(u, 4)} fill="url(#hatch)" pointer-events="none"/>` : ''}${lab(u, u.x, u.y + 1, u.w, u.h, false)}`).join('') || `<rect ${R(b, 8)} fill="url(#cush)" pointer-events="none"/>`}${sub.length ? (b.w > 70 ? `<text x="${b.x + 8}" y="${b.y + 16}" fill="#fff" style="font:600 12.5px var(--f-ui)">${esc((t.k.n + ' · ' + mb(t.k.s)).slice(0, Math.floor(b.w / 7.2)))}</text>` : '') : lab(t, b.x, b.y, b.w, b.h, true)}</g>`;
  }).join('');
  return `<svg class="tm" viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="Плиткова карта: ${esc(node.n)}" style="display:block">
    <defs><radialGradient id="cush" cx="30%" cy="25%" r="90%"><stop offset="0" stop-color="#fff" stop-opacity=".35"/><stop offset=".55" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".28"/></radialGradient>
    <pattern id="hatch" width="7" height="7" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="3" height="7" fill="#ffd27a" fill-opacity=".6"/></pattern></defs>${body}</svg>`;
}
function vAnalyze() {
  const a = S.an;
  if (a.phase === 'landing') return landing('analyze', { action: 'anScan', extra: `<div class="land-opts"><label class="land-opt">${ic('i-disk')}<select class="field sp" data-a="anVolSel" aria-label="Диск" style="border:0;background:transparent;padding:0"><option value="hd" ${a.vol === 'hd' ? 'selected' : ''}>Macintosh HD · 302 ГБ вільно</option><option value="ext" ${a.vol === 'ext' ? 'selected' : ''}>Archive · зовнішній</option></select></label></div>` });
  if (a.phase === 'scan') return landing('analyze', { busy: true, status: S.prog.status, step: S.prog.step });
  const node = anNode(), kids = node.kids || [], tot = sum(kids, k => k.s) || 1;
  let ang = -Math.PI / 2; const gap = 0.006, inner = [], outer = [];
  kids.forEach((k, i) => {
    const span = k.s / tot * Math.PI * 2, a0 = ang, a1 = ang + span, col = AN_COL[i % AN_COL.length]; ang = a1;
    inner.push(`<path d="${arc(200, 200, 74, 132, a0 + gap, a1 - gap)}" fill="${col}" ${k.unavailable ? 'fill-opacity=".3"' : ''} data-a="${k.kids ? 'anIn' : 'toast'}" data-v="${k.kids ? i : esc(k.n + ': ' + mb(k.s))}"><title>${esc(k.n)} · ${mb(k.s)}</title></path>`);
    if (k.kids) { const t2 = sum(k.kids, x => x.s); let b = a0; k.kids.forEach(g => { const s2 = g.s / t2 * span, b0 = b; b += s2; if (s2 > 0.02) outer.push(`<path d="${arc(200, 200, 136, 176, b0 + gap, b - gap)}" fill="${col}" fill-opacity="${g.insight || g.clean ? '.95' : '.5'}" data-a="anIn" data-v="${i}"><title>${esc(g.n)} · ${mb(g.s)}</title></path>`); }); }
  });
  const crumbs = [anRoot().n]; { let n = anRoot(); for (const i of a.path) { n = n.kids[i]; crumbs.push(n.n); } }
  const path = node.path || crumbs.slice(1).join('/'), sorted = kids.map((k, i) => ({ k, i })).sort((x, y) => y.k.s - x.k.s);
  return `<div class="fade-in"><div class="row" style="flex-wrap:wrap;margin-bottom:12px"><div class="crumbs">${crumbs.map((c, i) => `${i ? ic('i-chev', 'muted') : ''}<button data-a="anUp" data-v="${i}">${esc(c)}</button>`).join('')}</div>
    <span class="sp"></span><div class="tabs"><button aria-selected="${a.mode !== 'tree'}" data-a="anMode" data-v="sun">Кільця</button><button aria-selected="${a.mode === 'tree'}" data-a="anMode" data-v="tree">Плитки</button><button aria-selected="${a.mode === 'large'}" data-a="anMode" data-v="large">Великі файли</button></div>
    <button class="btn sm" data-a="anReset">${ic('i-disk')}Інший диск</button></div>
  ${a.mode === 'large' ? `<div class="list">${LARGE.map(([p, s]) => `<div class="entry"><span class="mono ell" style="grid-column:1/3" title="${esc(p)}">${esc(p)}</span><span class="num">${mb(s)}</span></div>`).join('')}</div>` :
  `<div class="an"><div class="panel" style="padding:16px">${a.mode === 'tree' ? treemap(node) : `<svg class="sun" viewBox="0 0 400 400" role="img" aria-label="Кільцева діаграма: ${esc(node.n)}">${inner.join('')}${outer.join('')}
      <g class="center" data-a="anUp" data-v="${Math.max(0, crumbs.length - 2)}"><circle cx="200" cy="200" r="70" fill="rgba(12,4,30,.55)"/>
      <text x="200" y="194" text-anchor="middle" fill="#fff" style="font:500 19px var(--f-display)">${mb(node.s)}${node.partial ? '+' : ''}</text>
      <text x="200" y="215" text-anchor="middle" fill="rgba(255,255,255,.7)" style="font:12px var(--f-ui)">${esc(node.n.length > 22 ? node.n.slice(0, 21) + '…' : node.n)}</text>
      ${a.path.length ? '<text x="200" y="234" text-anchor="middle" fill="#2ee6ff" style="font:11px var(--f-ui)">↑ рівнем вище</text>' : ''}</g></svg>`}
    <div class="row" style="margin-top:8px;justify-content:center">${cmd(`mo analyze --json "${path}"`)}</div></div>
  <div><div class="list">${sorted.map(({ k, i }) => `<div class="entry" ${k.kids ? `data-a="anIn" data-v="${i}" style="cursor:pointer"` : ''}><span class="sw-dot" style="background:${AN_COL[i % AN_COL.length]}"></span>
      <span class="ell"><b>${esc(k.n)}</b> ${k.insight ? `<span class="pill amber">${esc(k.insight)}</span>` : ''}${k.clean ? '<span class="pill info">Mole може очистити</span>' : ''}${k.partial ? '<span class="pill neutral">частково</span>' : ''}${k.unavailable ? '<span class="pill neutral">не виміряно</span>' : ''}</span>
      <span class="num">${k.unavailable ? 'невідомо' : mb(k.s) + (k.partial ? '+' : '')}</span><div class="bar"><i style="width:${(k.s / tot * 100).toFixed(1)}%;background:${AN_COL[i % AN_COL.length]}"></i></div></div>`).join('')}</div>
    <div class="row" style="margin-top:10px;flex-wrap:wrap"><button class="btn sm" data-a="toast" data-v="Відкрито у Finder">${ic('i-eye')}У Finder</button><button class="btn sm" data-a="toast" data-v="Quick Look">Quick Look</button><button class="btn sm" data-a="anTrash">${ic('i-uninstall')}У Кошик…</button></div>
    ${node.partial ? `<div class="banner" style="margin-top:10px">${ic('i-warn')}<span class="sp">Сканування часткове: «+» — нижня межа розміру.</span></div>` : ''}</div></div>`}</div>`;
}

// ---------- status ----------
const LIVE = {
  stHead: () => { const h = live.health; return `<div class="row" style="gap:18px;flex-wrap:wrap">${ring(h, { size: 92, stroke: 8, color: healthCol(h), label: h, sub: 'здоров’я' })}
    <div class="sp" style="min-width:220px"><div style="font:500 20px var(--f-display)">${healthWord(h)}</div><div class="note">Помірне навантаження CPU; пам’ять у нормі; диск заповнено на 70 %</div>
    <div class="row" style="flex-wrap:wrap;gap:6px;margin-top:8px"><span class="tag">MacBook Pro · M4 Pro</span><span class="tag">32 ГБ</span><span class="tag">macOS 26.4</span><span class="tag">аптайм 6 д</span></div></div></div>`; },
  stCpu: () => `<div class="card-h">${ic('i-cpu')}<h3>Процесор</h3><span class="sp"></span><span class="muted num">3,82 / 3,41 / 3,07</span></div>
    <div class="row" style="align-items:flex-end;gap:16px"><div class="bigv">${nf0.format(live.cpu.at(-1))}<small>%</small></div><div class="sp">${spark(live.cpu, { max: 100, h: 56, color: '#ff5cb4' })}</div></div>
    <div class="cores" style="margin-top:12px">${live.cores.map((c, i) => `<i class="${i >= 10 ? 'e' : ''}" style="height:${c.toFixed(0)}%"></i>`).join('')}</div>`,
  stMem: () => { const m = live.mem.at(-1); return `<div class="card-h">${ic('i-mem')}<h3>Пам’ять</h3><span class="sp"></span><span class="pill ${m > 75 ? 'warn' : 'good'}">${m > 75 ? 'тиск підвищений' : 'тиск нормальний'}</span></div>
    <div class="row" style="align-items:flex-end;gap:16px"><div class="bigv">${nf0.format(m)}<small>%</small></div><div class="sp">${spark(live.mem, { max: 100, h: 56, color: '#2ee6ff' })}</div></div>
    <dl class="kv" style="margin-top:12px"><dt>Використано</dt><dd>${nf1.format(32 * m / 100)} з 32 ГБ</dd><dt>Своп</dt><dd>1,3 ГБ</dd></dl>`; },
  stDisk: () => `<div class="card-h">${ic('i-disk')}<h3>Диск</h3><span class="sp"></span><span class="pill good">SMART ок</span></div><div class="bigv">70<small>% · 302 ГБ вільно</small></div>
    <div class="row" style="margin-top:12px;font-size:12px"><span class="dim" style="width:50px">Читання</span><div class="sp">${spark(live.rd, { h: 26, color: '#2ee6ff' })}</div><span class="num" style="width:68px;text-align:right">${nf1.format(live.rd.at(-1))} МБ/с</span></div>
    <div class="row" style="font-size:12px"><span class="dim" style="width:50px">Запис</span><div class="sp">${spark(live.wr, { h: 26, color: '#ff5cb4' })}</div><span class="num" style="width:68px;text-align:right">${nf1.format(live.wr.at(-1))} МБ/с</span></div>`,
  stNet: () => `<div class="card-h">${ic('i-net')}<h3>Мережа</h3><span class="sp"></span><span class="tag">utun4</span></div>
    <div class="row" style="gap:20px"><div><div class="muted" style="font-size:11.5px">↓ Завантаження</div><div class="bigv" style="font-size:20px">${nf1.format(live.down.at(-1))}<small>МБ/с</small></div></div><div><div class="muted" style="font-size:11.5px">↑ Віддача</div><div class="bigv" style="font-size:20px">${nf1.format(live.up.at(-1))}<small>МБ/с</small></div></div></div>
    <div style="margin-top:10px;position:relative">${spark(live.down, { h: 40, color: '#ffb02e' })}<div style="position:absolute;inset:0">${spark(live.up, { h: 40, max: Math.max(...live.down) * 1.15, color: '#2ee6ff' })}</div></div>`,
  stPower: () => `<div class="card-h">${ic('i-battery')}<h3>Живлення</h3><span class="sp"></span><span class="pill good">заряджається</span></div><div class="bigv">${live.batt}<small>%</small></div>
    <div class="bar" style="margin:10px 0"><i style="width:${live.batt}%;background:linear-gradient(90deg,#62f5b5,#2ee6ff)"></i></div><dl class="kv"><dt>Стан</dt><dd>92 % · 423 цикли</dd><dt>Температура</dt><dd>31 °C</dd></dl>`,
  stSensors: () => `<div class="card-h">${ic('i-thermo')}<h3>Температура</h3><span class="sp"></span><span class="pill good">штатно</span></div><dl class="kv"><dt>CPU</dt><dd>${nf0.format(live.temp)} °C</dd><dt>GPU</dt><dd>${nf0.format(live.temp - 6)} °C</dd><dt>Вентилятор</dt><dd>${nf0.format(live.fan)} об/хв</dd><dt>Графіка</dt><dd>${nf0.format(live.gpu)} %</dd></dl>`,
  stBt: () => `<div class="card-h">${ic('i-bt')}<h3>Bluetooth</h3></div>${[['AirPods Pro', 82], ['Magic Keyboard', 64], ['MX Master 3S', 18]].map(([n, v]) => `<div class="row" style="padding:4px 0"><span class="sp">${n}</span><div class="bar" style="width:70px"><i style="width:${v}%;background:${v < 20 ? 'var(--crit)' : 'var(--good)'}"></i></div><span class="num" style="width:38px;text-align:right">${v} %</span></div>`).join('')}`,
  stProcs: () => { const ps = [...live.procs].sort((a, b) => b[2] - a[2]).slice(0, 6), mx = Math.max(...ps.map(p => p[2]), 100);
    return `<div class="card-h"><h3>Процеси</h3><span class="sp"></span><span class="muted" style="font-size:12px">зомбі: 3 · Chrome for Testing</span></div><div class="tablewrap"><table class="ptable"><thead><tr><th>Процес</th><th>CPU</th><th class="r">%</th><th class="r">Пам’ять</th></tr></thead><tbody>
    ${ps.map(p => `<tr><td>${esc(p[0])}${p[2] > 100 ? ' <span class="pill crit">&gt;100 % · 6 хв</span>' : ''}</td><td style="width:32%"><div class="bar"><i style="width:${(p[2] / mx * 100).toFixed(0)}%;background:${p[2] > 100 ? 'var(--crit)' : 'linear-gradient(90deg,#ff3ea5,#b04dff)'}"></i></div></td><td class="r">${nf1.format(p[2])}</td><td class="r">${nf1.format(p[3])} ГБ</td></tr>`).join('')}</tbody></table></div>`; },
  mb: () => { const h = live.health, cell = (n, v, arr, col, max) => `<div class="qm-stat"><small>${n}</small><b>${v}</b>${arr ? spark(arr.slice(-30), { h: 18, max, color: col }) : ''}</div>`;
    const ps = [...live.procs].sort((a, b) => b[2] - a[2]).slice(0, 3);
    return `<div class="row" style="margin-bottom:8px">${ring(h, { size: 46, stroke: 5, color: healthCol(h), label: h })}<div class="sp"><b>${healthWord(h)}</b><div class="note">Помірне навантаження CPU; пам’ять у нормі</div></div></div>
    <div class="qm-stats">${cell('Процесор', nf0.format(live.cpu.at(-1)) + ' %', live.cpu, '#ff5cb4', 100)}${cell('Пам’ять', nf0.format(live.mem.at(-1)) + ' %', live.mem, '#2ee6ff', 100)}${cell('Мережа ↓', nf1.format(live.down.at(-1)) + ' МБ/с', live.down, '#ffb02e')}${cell('Диск · вільно', '302 ГБ', live.wr, '#c98bff')}</div>
    <div class="qm-stat row" style="margin-top:8px;gap:12px"><span style="color:var(--good)">${ic('i-battery')}</span><span class="sp">Батарея <b style="font:500 13px var(--f-ui)">${live.batt} %</b> · заряджається</span><span class="dim">${ic('i-thermo')} ${nf0.format(live.temp)} °C</span></div>
    ${mbTop(ps)}`; },
};
// "What is using the Mac": memory (composition, pressure, swap, apps with their helpers) or CPU.
// Read-only by design: it explains where memory goes; it never frees or kills anything.
function mbTop(ps) {
  const m = live.mem.at(-1), high = m > 75, total = 32, used = total * m / 100, cache = 4.8;
  const tab = (v, n) => `<button aria-pressed="${S.mbTop === v}" data-a="mbTop" data-v="${v}">${n}</button>`;
  const item = (name, note, value, share, kind) => `<div class="qm-item"><div class="row"><span class="sp ell">${name}${note ? ` <span class="dim">${note}</span>` : ''}</span><span class="num">${value}</span></div><div class="qm-track"><i class="${kind}" style="width:${Math.max(4, Math.min(100, share))}%"></i></div></div>`;
  let body;
  if (S.mbTop === 'cpu') {
    body = ps.map(p => item(esc(p[0]), p[2] > 100 ? '<span class="pill crit">довго &gt;100 %</span>' : '', nf1.format(p[2]) + ' %', p[2], 'cpu')).join('');
  } else {
    const top = live.apps[0][2];
    body = `<div class="qm-meter" title="Програми ${nf1.format(used - cache)} ГБ · кеш ${nf1.format(cache)} ГБ · вільно ${nf1.format(total - used)} ГБ"><i class="apps" style="width:${(used - cache) / total * 100}%"></i><i class="cache" style="width:${cache / total * 100}%"></i></div>
      <div class="row qm-memline"><span class="pill ${high ? 'warn' : 'good'}">тиск ${high ? 'підвищений' : 'нормальний'}</span><span class="sp num">${nf1.format(used)} з ${total} ГБ</span><span class="dim" title="Swap зменшиться, коли закриються програми, яким належать ці сторінки, або після перезавантаження">swap ${nf1.format(live.swap)} ГБ ⓘ</span></div>`
      + live.apps.map(a => item(esc(a[0]), `· ${a[1]} процесів`, nf1.format(a[2]) + ' ГБ', a[2] / top * 100, 'mem')).join('');
  }
  return `<div class="qm-top"><div class="row"><small class="dim sp">Найбільше навантажують</small><div class="seg seg-sm">${tab('mem', 'Пам’ять')}${tab('cpu', 'Процесор')}</div></div>${body}</div>`;
}
function vStatus() {
  return `<div class="st fade-in">
    <div class="card w6 row" style="gap:18px;align-items:center">${hero('status', 'idle', 120)}<div class="sp" data-live="stHead">${LIVE.stHead()}</div></div>
    <div class="card w3" data-live="stCpu">${LIVE.stCpu()}</div><div class="card w3" data-live="stMem">${LIVE.stMem()}</div>
    <div class="card w2" data-live="stDisk">${LIVE.stDisk()}</div><div class="card w2" data-live="stNet">${LIVE.stNet()}</div><div class="card w2" data-live="stPower">${LIVE.stPower()}</div>
    <div class="card w4" data-live="stProcs">${LIVE.stProcs()}</div>
    <div class="card w2"><div class="card-h">${ic('i-warn')}<h3>Сповіщення</h3></div>
      <div class="opt-row"><input type="checkbox" class="sw" id="pa" checked><label for="pa" class="sp">Довге навантаження CPU</label></div>
      <div class="opt-row"><label class="sp" for="pth">Поріг</label><select class="field" id="pth"><option>80 %</option><option selected>100 %</option><option>150 %</option></select></div>
      <div class="opt-row"><label class="sp" for="pwin">Протягом</label><select class="field" id="pwin"><option>2 хв</option><option selected>5 хв</option><option>15 хв</option></select></div></div>
    <div class="card w3" data-live="stSensors">${LIVE.stSensors()}</div><div class="card w3" data-live="stBt">${LIVE.stBt()}</div></div>`;
}

// ---------- purge & installer ----------
function vPurge() {
  const p = S.purge;
  if (p.phase === 'landing') return landing('purge', { action: 'purgeScan', extra: `<div class="land-opts"><div class="land-opt">${ic('i-folder')}<span class="sp mono">${S.prot.purgePaths.join(' · ')}</span><button class="btn sm" data-a="go" data-v="protect">Змінити</button></div></div>` });
  if (p.phase === 'scan' || p.phase === 'run') return landing('purge', { busy: true, status: S.prog.status, step: S.prog.step });
  if (p.phase === 'done') return donePanel('purge', `≈ ${mb(p.freed)}`, `звільнено · ${p.items} артефактів видалено`);
  const isDefault = ARTS.every(a => p.sel.has(a.id) === artDefault(a));
  return `${resHead('purge', `${mb(sum(ARTS.filter(artDefault), a => a.mb))} у ${PROJECTS.length} проєктах`, 'Артефакти, що змінювалися менше ніж 7 днів тому, не позначені. Розмір — оцінка.', `<label class="row" style="font-size:12.5px"><input type="checkbox" class="sw" data-a="purgeEmpty" ${p.empty ? 'checked' : ''}>Порожні теж</label>`)}
  <div class="fade-in">${PROJECTS.map(pr => `<div class="proj"><div class="proj-h">${ic('i-folder')}<b class="sp ell mono" style="font-size:12px">${esc(pr.path)}</b><span class="num dim">${mb(sum(pr.arts, a => a.mb))}</span></div>
    ${pr.arts.map(a => `<div class="art"><input type="checkbox" class="cb" aria-label="${esc(a.k)}" data-a="purgeCheck" data-v="${a.id}" ${p.sel.has(a.id) ? 'checked' : ''}><span class="mono">${esc(a.k)}</span><span class="path muted ell" style="font-size:12px">змінено ${a.age} тому</span>
      <span class="flag">${a.recent ? '<span class="pill warn">активний</span>' : a.unverified ? '<span class="pill neutral">не перевірено</span>' : ''}</span><span class="num dim" style="text-align:right;min-width:70px">${a.mb != null ? mb(a.mb) : 'не виміряно'}</span></div>`).join('')}</div>`).join('')}</div>
  <div class="actionbar"><span class="tot">${mb(purgeTotal())}</span><span class="dim">${p.sel.size} артефактів · видаляються остаточно</span><span class="sp"></span>${cmd(isDefault ? 'mo purge --yes' + (p.empty ? ' --include-empty' : '') : 'mo purge' + (p.empty ? ' --include-empty' : ''))}
    <button class="btn danger" data-a="purgeConfirm" ${p.sel.size ? '' : 'disabled'}>${ic('i-purge')}Видалити</button></div>`;
}
function vInstaller() {
  const s = S.inst;
  if (s.phase === 'landing') return landing('installer', { action: 'instScan' });
  if (s.phase === 'scan' || s.phase === 'run') return landing('installer', { busy: true, status: S.prog.status, step: S.prog.step });
  if (s.phase === 'done') return donePanel('installer', mb(s.freed), `звільнено · ${s.items} інсталяторів видалено`);
  return `${resHead('installer', `${INST.length} інсталяторів · ${mb(sum(INST, i => i.mb))}`, 'Кожен файл Mole ще раз перевіряє безпосередньо перед видаленням.', `<button class="btn sm ghost" data-a="instAll" data-v="1">Усі</button><button class="btn sm ghost" data-a="instAll" data-v="inv">Інвертувати</button>`)}
  <div class="list fade-in">${INST.map(i => `<div class="inst"><input type="checkbox" class="cb" aria-label="${esc(i.name)}" data-a="instCheck" data-v="${i.id}" ${s.sel.has(i.id) ? 'checked' : ''}>
    <span class="ftype" style="background:${FT_COL[i.t]}">${i.t}</span><div class="ell"><b class="ell">${esc(i.name)}</b><div class="muted" style="font-size:11.5px">${i.age} тому</div></div><span class="tag src">${i.src}</span><span class="num dim" style="text-align:right;min-width:70px">${mb(i.mb)}</span></div>`).join('')}</div>
  <div class="actionbar"><span class="tot">${mb(instTotal())}</span><span class="dim">${s.sel.size} з ${INST.length}</span><span class="sp"></span>${cmd('mo installer')}<button class="btn danger" data-a="instConfirm" ${s.sel.size ? '' : 'disabled'}>${ic('i-installer')}Видалити</button></div>`;
}

// ---------- tools ----------
function vTools() {
  const gi = k => `<img src="${glassSrc(k)}" alt="">`;
  const T2 = [
    ['purge', 'Проєкти', 'Прибрати node_modules, target, build та інші артефакти збирання.', `<button class="btn primary sm" data-a="go" data-v="purge">Сканувати</button>`],
    ['installer', 'Інсталятори', 'Знайти забуті DMG, PKG, ISO та XIP у Завантаженнях і хмарах.', `<button class="btn primary sm" data-a="go" data-v="installer">Сканувати</button>`],
    ['protect', 'Захист', 'Кеші, шляхи й задачі, яких Mole ніколи не торкнеться.', `<button class="btn sm" data-a="go" data-v="protect">Відкрити</button>`],
    ['clean', 'Зовнішній диск', 'Прибрати .DS_Store і ._-файли з флешки чи зовнішнього диска.', `<button class="btn sm" data-a="extClean">Обрати диск…</button>`],
    ['status', 'Touch ID для sudo', 'Підтверджувати системні дії відбитком замість пароля.', `<input type="checkbox" class="sw" aria-label="Touch ID для sudo" data-a="setToggle" data-v="touchid" ${S.set.touchid ? 'checked' : ''}>`],
    ['settings', 'Оновлення Mole', 'Встановлено 1.59.1 через Homebrew. Доступна 1.60.0.', `<span class="pill amber">нове</span><button class="btn primary sm" data-a="cliUpdate">Оновити</button>`],
    ['history', 'Raycast і Alfred', 'П’ять швидких команд: очистити, видалити, оптимізувати, аналіз, стан.', `<button class="btn sm" data-a="toast" data-v="Команди Raycast додано">Налаштувати</button>`],
    ['analyze', 'MCP для агентів', 'Агенти бачать стан системи й історію. Тільки читання — нічого не видаляє.', `<input type="checkbox" class="sw" aria-label="MCP-сервер" data-a="setToggle" data-v="mcp" ${S.set.mcp ? 'checked' : ''}>`],
    ['settings', 'Налаштування', 'Mole CLI, доступ, розклад перевірок, меню-бар і мова.', `<button class="btn sm" data-a="go" data-v="settings">Відкрити</button>`],
  ];
  return `<div class="fade-in"><div class="res-head"><div class="sp"><h1 class="title" style="margin:0">Інструменти</h1><p class="lead" style="margin:8px 0 0">Точкові дії та налаштування Mole в одному місці.</p></div></div>
  <div class="tools">${T2.map(([k, t, d, f]) => `<div class="card tool">${gi(MODS[k].hero)}<h3>${t}</h3><p>${d}</p><div class="foot">${f}</div></div>`).join('')}</div></div>`;
}

// ---------- history ----------
function vHistory() {
  const h = S.hist, list = HIST.filter(x => h.f === 'all' || x.c === h.f), freed = sum(HIST, x => x.mb), byCmd = Object.keys(CMD_UA).map(k => [k, sum(HIST.filter(x => x.c === k), x => x.mb)]).filter(([, v]) => v);
  const mx = Math.max(...HIST_DAYS), W = 600, H = 110, bw = W / HIST_DAYS.length, hl = live.health;
  return `<div class="fade-in"><div class="res-head"><div class="sp"><h1 class="title" style="margin:0">Історія активності</h1></div><span class="dim">з 14 вересня 2026</span></div>
  <div class="dash">
    <div class="card big" style="display:flex;flex-direction:column"><div class="row" style="align-items:flex-start"><div class="sp"><div class="dim">Рівень здоров’я Mac</div><div style="font:500 30px var(--f-display);color:var(--good);margin:6px 0">${healthWord(hl)}</div><div class="dim">MacBook Pro · ${hl} зі 100</div></div></div>
      <div style="display:grid;place-items:center;flex:1">${hero('vessel', 'idle', 230)}</div><div class="row" style="margin-top:18px"><b>Macintosh HD</b><span class="sp"></span><span class="dim num">693 ГБ з 995 ГБ</span></div><div class="bar" style="margin-top:8px;height:8px"><i style="width:70%"></i></div></div>
    <div class="card"><div class="dim">Звільнено за 30 днів</div><div class="bigv" style="font-size:32px;margin:8px 0 14px">${mb(freed)}</div>
      <div class="catbar" style="height:14px;border-radius:7px">${byCmd.map(([k, v]) => `<i style="flex:${v};background:${CMD_COL[k]}"></i>`).join('')}</div>
      <div class="legend" style="margin-top:12px">${byCmd.map(([k, v]) => `<div><s style="background:${CMD_COL[k]}"></s><span class="sp">${CMD_UA[k]}</span><b class="num">${mb(v)}</b></div>`).join('')}</div></div>
    <div class="card"><div class="dim">По днях</div><div class="bigv" style="font-size:32px;margin:8px 0 10px">${HIST.length} <small>сесій</small></div>
      <svg class="hist-chart" viewBox="0 0 ${W} ${H + 26}" role="img" aria-label="Звільнене місце по днях"><line x1="0" x2="${W}" y1="${H}" y2="${H}" stroke="rgba(255,255,255,.25)"/>
      ${HIST_DAYS.map((v, i) => v ? `<rect x="${(i * bw + 3).toFixed(1)}" y="${(H - v / mx * (H - 6)).toFixed(1)}" width="${(bw - 6).toFixed(1)}" height="${(v / mx * (H - 6)).toFixed(1)}" rx="3" fill="${CMD_COL[HIST_DAY_CMD[i]]}"><title>${CMD_UA[HIST_DAY_CMD[i]]}: ${mb(v)}</title></rect>` : '').join('')}
      <text x="0" y="${H + 22}" fill="rgba(255,255,255,.6)" style="font:18px var(--f-ui)">14 вер.</text><text x="${W}" y="${H + 22}" text-anchor="end" fill="rgba(255,255,255,.6)" style="font:18px var(--f-ui)">сьогодні</text></svg></div>
    <div class="card" style="grid-column:span 2"><div class="row" style="margin-bottom:8px"><b>Рекомендації: 3</b><span class="sp"></span></div>
      ${[['i-cpu', 'Code Helper тримає CPU вище 100 % понад 5 хв', 'status', 'Переглянути'], ['i-uninstall', 'Кошик займає 1,1 ГБ', 'clean', 'Очистити'], ['i-refresh', 'Доступна Mole 1.60.0', 'tools', 'Оновити']].map(([i, t, g, b]) => `<div class="opt-row"><span class="bico" style="width:34px;height:34px;border-radius:10px">${ic(i)}</span><span class="sp">${t}</span><button class="btn sm" data-a="go" data-v="${g}">${b}</button></div>`).join('')}</div>
  </div>
  <div class="row" style="margin:20px 0 10px;flex-wrap:wrap"><b style="font:500 15px var(--f-display)">Сесії</b><span class="sp"></span><div class="tabs">${['all', 'clean', 'uninstall', 'purge', 'installer', 'optimize'].map(f => `<button aria-selected="${h.f === f}" data-a="histF" data-v="${f}">${f === 'all' ? 'Усі' : CMD_UA[f]}</button>`).join('')}</div></div>
  <div class="list">${list.map(x => `<div class="sess" data-a="histOpen" data-v="${x.id}"><span class="cmdi" style="color:${CMD_COL[x.c]}">${ic(CMD_IC[x.c])}</span>
    <div class="ell"><b>${CMD_UA[x.c]}</b> <span class="muted">· ${x.when} · ${x.dur}</span>${x.attr === 'ambiguous' ? ' <span class="pill warn">межі сесії неточні</span>' : ''}</div>
    <span class="dim num" style="font-size:12px">${x.items} позицій</span><span class="num" style="min-width:70px;text-align:right">${x.mb ? '−' + mb(x.mb) : '—'}</span>
    <div style="grid-column:2/-1" class="muted"><span style="font-size:11.5px">видалено ${x.a[0]} · у Кошик ${x.a[1]} · пропущено ${x.a[2]} · помилок ${x.a[3]} · перебудовано ${x.a[4]}</span></div>
    ${h.open === x.id ? `<div class="oplog">${esc(OPLOG(x))}</div>` : ''}</div>`).join('')}</div></div>`;
}
const OPLOG = x => x.c === 'clean'
  ? `[2026-10-13 09:14:02] [clean] SESSION_START run_id=7c1e…\n[2026-10-13 09:14:05] [clean] REMOVED ~/Library/Caches/com.spotify.client (1.3GB)\n[2026-10-13 09:14:06] [clean] REMOVED ~/.npm/_cacache (1.8GB)\n[2026-10-13 09:14:06] [clean] SKIPPED ~/.gradle/caches whitelist\n[2026-10-13 09:14:09] [clean] SKIPPED ~/Library/pnpm/store busy\n[2026-10-13 09:14:40] [clean] FAILED /Library/Updates permission\n[2026-10-13 09:15:54] [clean] SESSION_END items=412`
  : `[${x.when}] [${x.c}] SESSION_START\n[${x.when}] [${x.c}] ${x.c === 'uninstall' ? 'TRASHED /Applications/Adobe Photoshop 2024.app' : x.c === 'optimize' ? 'REBUILT QuickLook thumbnails' : 'REMOVED ~/Projects/website/node_modules'}\n[${x.when}] [${x.c}] SESSION_END items=${x.items}`;

// ---------- protect ----------
const WL = [
  ['Кеші IDE', 14, ['Xcode DerivedData', 'JetBrains IDEs cache', 'Android Studio cache', 'VS Code runtime cache', 'Gradle build cache']],
  ['Компілятори', 13, ['Rust Cargo registry', 'Turbo monorepo cache', 'Next.js build cache', 'Vite build cache']],
  ['Пакетні менеджери', 10, ['npm package cache', 'pip cache', 'CocoaPods cache', 'Homebrew downloads']],
  ['AI / ML', 5, ['Моделі Ollama', 'LM Studio cache', 'Chrome on-device AI models']],
  ['Браузери', 4, ['Браузери Playwright', 'Chrome cache', 'Safari cache']],
  ['Системні', 6, ['Кошик', 'Apple Mail cache', 'QuickLook thumbnails']],
];
const WL_DEFAULT = new Set(['Gradle build cache', 'JetBrains IDEs cache', 'Моделі Ollama', 'Браузери Playwright']);
function vProtect() {
  const p = S.prot, isOn = n => WL_DEFAULT.has(n) ? !p.off.has(n) : p.off.has('+' + n);
  return `${resHead('protect', 'Що Mole ніколи не чіпатиме', '13 типових і 6 обов’язкових захистів. Nora переносить типові захисти у файл під час першого збереження, щоб вони не зникли.')}
  <div class="tabs fade-in" style="margin-bottom:14px">${[['clean', 'Кеші'], ['custom', 'Власні шляхи'], ['optimize', 'Оптимізація'], ['purge', 'Проєкти']].map(([v, n]) => `<button aria-selected="${p.tab === v}" data-a="protTab" data-v="${v}">${n}</button>`).join('')}</div>
  ${p.tab === 'clean' ? `<div class="tools" style="grid-template-columns:repeat(auto-fill,minmax(260px,1fr))">${WL.map(([g, n, items]) => `<div class="card"><div class="card-h"><h3>${g}</h3><span class="sp"></span><span class="muted" style="font-size:12px">${n} правил</span></div>
      ${items.map(it => `<div class="opt-row"><input type="checkbox" class="sw" aria-label="${esc(it)}" data-a="wlToggle" data-v="${esc(it)}" ${isOn(it) ? 'checked' : ''}><span class="sp">${it}</span>${WL_DEFAULT.has(it) ? '<span class="pill neutral">типово</span>' : ''}</div>`).join('')}</div>`).join('')}</div>` : ''}
  ${p.tab === 'custom' ? `<div class="card"><div class="card-h"><h3>Власні шляхи</h3><span class="sp"></span><button class="btn sm" data-a="protAdd">${ic('i-plus')}Додати теку…</button></div>${p.custom.map((c, i) => `<div class="opt-row"><span class="mono sp ell">${esc(c)}</span><button class="iconbtn" aria-label="Прибрати" data-a="protDel" data-v="${i}">${ic('i-x')}</button></div>`).join('')}</div>` : ''}
  ${p.tab === 'optimize' ? `<div class="card"><div class="card-h"><h3>Вимкнені задачі</h3></div><div class="row" style="flex-wrap:wrap;gap:6px">${[...S.opt.excl].map(x => `<span class="tag">${x}</span>`).join('') || '<span class="muted">немає</span>'}</div><div class="hr"></div><div class="card-h"><h3>Шаблони шляхів</h3></div>${p.optPaths.map(x => `<div class="opt-row"><span class="mono sp">${esc(x)}</span></div>`).join('')}</div>` : ''}
  ${p.tab === 'purge' ? `<div class="card"><div class="card-h"><h3>Де шукати проєкти</h3><span class="sp"></span><button class="btn sm" data-a="protAdd">${ic('i-plus')}Додати теку…</button></div>${p.purgePaths.map(x => `<div class="opt-row">${ic('i-folder')}<span class="mono sp">${esc(x)}</span></div>`).join('')}</div>` : ''}`;
}

// ---------- settings ----------
function vSettings() {
  const s = S.set, cli = S.scen.cli, sw = (k, id) => `<input type="checkbox" class="sw" id="${id}" data-a="setToggle" data-v="${k}" ${s[k] ? 'checked' : ''}>`;
  return `${resHead('settings', 'Налаштування', 'Mole CLI, доступ, автоматизація й вигляд.')}<div class="grid fade-in" style="max-width:860px">
  <div class="card"><div class="card-h"><h3>Mole CLI</h3><span class="sp"></span>${cli === 'ok' ? '<span class="pill good">працює</span>' : cli === 'old' ? '<span class="pill warn">застаріла версія</span>' : '<span class="pill crit">не знайдено</span>'}</div>
    <div class="set-row"><div class="t"><b class="mono">${cli === 'missing' ? '—' : '/opt/homebrew/bin/mo'}</b><small>Знайдено в PATH вашої оболонки. Nora не вбудовує Mole.</small></div><button class="btn sm" data-a="toast" data-v="Оберіть файл mo">Інший шлях…</button></div>
    <div class="set-row"><div class="t"><b>Версія ${cli === 'old' ? '1.42.0' : '1.59.1'} · Homebrew</b><small>Доступна 1.60.0 · мінімум для Nora 1.55</small></div><button class="btn sm primary" data-a="cliUpdate">Оновити</button></div>
    <div class="set-row"><div class="t"><b>Можливості CLI</b><div class="caps" style="margin-top:8px">${[['status --watch', 1], ['analyze --json', 1], ['history --json', 1], ['uninstall --list', 1], ['purge --yes', 1], ['JSON для dry-run', 0]].map(([n, ok]) => `<span class="pill ${ok ? 'good' : 'neutral'}">${ic(ok ? 'i-check' : 'i-x')}${n}</span>`).join('')}</div></div></div></div>
  <div class="card"><div class="card-h"><h3>Оновлення</h3></div>
    <div class="set-row"><div class="t"><b>Nora 0.1.0</b><small>Оновлюється сама через підписаний канал (Sparkle). Остання перевірка: сьогодні о 09:00</small></div><button class="btn sm" data-a="toast" data-v="У вас найновіша версія Nora">Перевірити зараз</button></div>
    <div class="set-row"><div class="t"><b>Встановлювати оновлення Nora автоматично</b></div>${sw('autoNora', 'stAutoNora')}</div>
    <div class="set-row"><div class="t"><b>Оновлювати Mole автоматично</b><small>Через той канал, яким встановлено Mole (зараз — Homebrew)</small></div>${sw('autoMole', 'stAutoMole')}</div></div>
  <div class="card"><div class="card-h"><h3>Доступ</h3></div>
    <div class="set-row"><div class="t"><b>Touch ID для sudo</b><small><span class="mono">mo touchid ${s.touchid ? 'disable' : 'enable'}</span></small></div>${sw('touchid', 'stTouch')}</div>
    <div class="set-row"><div class="t"><b>Повний доступ до диска</b><small>${S.scen.fda ? 'Надано' : 'Не надано — частина кешів не сканується'}</small></div><button class="btn sm" data-a="toast" data-v="Відкрито Параметри → Конфіденційність">${S.scen.fda ? 'Перевірити' : 'Надати…'}</button></div>
    <div class="set-row"><div class="t"><b>Журнал операцій</b><small>Основа розділу «Історія»</small></div>${sw('oplog', 'stOp')}</div></div>
  <div class="card"><div class="card-h"><h3>Автоматизація</h3></div>
    <div class="set-row"><div class="t"><b>Перевірка за розкладом</b><small>Лише перегляд і сповіщення — без видалення</small></div><select class="field" data-a="setSched"><option value="off">Вимкнено</option><option value="daily" ${s.schedule === 'daily' ? 'selected' : ''}>Щодня</option><option value="weekly" ${s.schedule === 'weekly' ? 'selected' : ''}>Щотижня</option></select></div>
    <div class="set-row"><div class="t"><b>Меню-бар</b><small>Що показувати поруч з іконкою · права кнопка — швидке меню · ⌥⌘N — відкрити</small>
      <div class="tabs" style="margin-top:8px">${[['icon', 'Іконка'], ['cpu', 'CPU'], ['spark', 'Графік'], ['multi', 'Кілька показників']].map(([k, n]) => `<button aria-selected="${S.set.mbMode === k}" data-a="mbMode" data-v="${k}">${n}</button>`).join('')}</div></div>${sw('menubar', 'stMb')}</div>
    <div class="set-row"><div class="t"><b>Запуск під час входу</b></div>${sw('login', 'stLogin')}</div></div>
  <div class="note">Nora — незалежний застосунок, не пов’язаний з Mole і не схвалений ним. Mole CLI © tw93, GPL-3.0. Офіційний застосунок автора — mole.fit.</div></div>`;
}

// ---------- shell ----------
const RENDER = { security: vSecurity, overview: vOverview, clean: vClean, uninstall: vUninstall, purge: vPurge, installer: vInstaller, analyze: vAnalyze, status: vStatus, optimize: vOptimize, history: vHistory, protect: vProtect, settings: vSettings, tools: vTools };
function renderRail() {
  $('#rail').innerHTML = `<div class="traffic" aria-hidden="true"><i></i><i></i><i></i></div>` + RAIL.map(k => {
    if (!k) return '<span class="gap"></span>';
    const m = MODS[k], src = glassSrc(m.hero);
    return `<button class="rail-btn" data-a="go" data-v="${k}" aria-label="${m.n}">${src ? `<img src="${src}" alt="">` : ic(m.ic)}<span class="tip">${m.n}</span>${k === 'tools' ? '<span class="dot"></span>' : ''}</button>`;
  }).join('');
}
function renderChrome() {
  const m = MODS[S.view];
  [['--m1', m.c[0]], ['--m2', m.c[1]], ['--m3', m.c[2]]].forEach(([k, v]) => document.documentElement.style.setProperty(k, v));
  document.querySelectorAll('.rail-btn').forEach(b => { const on = b.dataset.v === S.view || (b.dataset.v === 'tools' && ['purge', 'installer', 'protect', 'settings'].includes(S.view)); on ? b.setAttribute('aria-current', 'page') : b.removeAttribute('aria-current'); });
  $('#where').textContent = S.view === 'status' ? m.n.toUpperCase() : '';
  $('#adminPill').innerHTML = S.scen.admin ? `<button class="pillbtn on" data-a="auth" data-v="info">${ic('i-touch')}Адмін · 4:58</button>` : `<button class="pillbtn" data-a="auth" data-v="info">${ic('i-lock')}Без прав адміністратора</button>`;
  const b = [];
  if (S.scen.cli === 'old') b.push(`<div class="banner">${ic('i-warn')}<span class="sp">Встановлено <b>mo 1.42.0</b>. Nora потребує 1.55+: частину розділів вимкнено.</span><button class="btn sm" data-a="cliUpdate">Оновити Mole</button></div>`);
  if (!S.scen.fda) b.push(`<div class="banner">${ic('i-lock')}<span class="sp">Немає повного доступу до диска: Пошта, Safari й частина кешів не скануються.</span><button class="btn sm" data-a="toast" data-v="Відкрито Параметри → Конфіденційність">Надати доступ</button></div>`);
  $('#banners').innerHTML = b.join('');
}
function render(soft) {
  renderChrome();
  const main = $('#main');
  main.classList.toggle('noanim', !!soft);
  main.innerHTML = RENDER[S.view]();
  main.querySelectorAll('[data-ind]').forEach(el => { el.indeterminate = true; });
  if (S.scen.cli === 'missing') showCliMissing();
}
function go(v) { if (!RENDER[v]) return; S.view = v; try { history.replaceState(null, '', '#' + v); } catch (e) { /* sandboxed viewer */ } render(); $('#main').scrollTop = 0; }
function toast(msg) { const t = $('#toast'); t.textContent = msg; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => { t.hidden = true; }, 2600); }

// ---------- sheets ----------
function sheet(html) { $('#sheetBody').innerHTML = html; $('#sheet').hidden = false; const f = $('#sheetBody .btn.primary, #sheetBody .btn.danger'); f && f.focus(); }
function closeSheet() { $('#sheet').hidden = true; }
function authSheet(reason, then) {
  sheet(`<h3>Потрібні права адміністратора</h3><div class="auth"><div class="fp">${ic('i-touch')}</div><div class="sp"><b>${esc(reason)}</b><div class="note">Nora виконає <span class="mono">sudo -A -v</span> у тій самій сесії, що й команду Mole. Пароль вводиться в системному вікні й не зберігається.</div></div></div>
  <div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn primary" data-a="authOk">${ic('i-touch')}Дозволити</button></div>`);
  authSheet.then = then;
}
function showCliMissing() {
  sheet(`<div class="eyebrow">Перше налаштування</div><h3>Nora встановить Mole сама</h3>
  <p class="note" style="margin:0">Усю роботу з файлами виконує відкритий Mole CLI. Nora встановить його й надалі оновлюватиме — Термінал не потрібен.</p>
  <div class="card" style="padding:12px"><div class="row"><b class="sp">Знайдено Homebrew</b><span class="pill good">буде використано</span></div><div style="margin-top:6px">${cmd('brew install mole')}</div>
    <div class="note" style="margin-top:8px">Без Homebrew Nora завантажить офіційний інсталятор Mole закріпленої версії, перевірить контрольну суму й поставить у ~/.local/bin — без пароля адміністратора.</div></div>
  <div class="inst-steps" id="instSteps" hidden></div>
  <div class="foot"><button class="btn" data-a="toast" data-v="Оберіть файл mo">Вказати шлях…</button><button class="btn primary" data-a="cliInstall" id="instBtn">Встановити Mole</button></div>`);
}

// ---------- flows ----------
function smartScan() {
  const sm = S.smart; sm.phase = 'run'; S.prog = { pct: 0, status: 'Готую перевірку…', step: 0 }; render();
  const lines = SMART.flatMap(([c, n]) => [L('a', '$ ' + c), L('g', '  ✓ ' + n)]);
  run('nora smart-scan · 4 команди лише для перегляду', lines, { speed: 260,
    onLine: i => { const k = Math.floor(i / 2); if (S.view === 'overview') progress(i, lines.length, `${SMART[k][1]}…`, i % 2 ? k + 1 : k); },
    onDone: () => { sm.phase = 'results'; S.prog.pct = 0; if (S.view === 'overview') render(); },
    onStop: () => { sm.phase = 'landing'; render(); } });
}
function smartAll() {
  sheet(`<h3>Очистити ${mb(smartSafe())}?</h3><div class="legend">
    <div><s style="background:var(--c1)"></s><span class="sp">Кеші та журнали</span><span class="num dim">${mb(cleanAvail())}</span></div>
    <div><s style="background:var(--c2)"></s><span class="sp">Артефакти проєктів (типовий вибір Mole)</span><span class="num dim">${mb(sum(ARTS.filter(artDefault), a => a.mb))}</span></div>
    <div><s style="background:var(--c3)"></s><span class="sp">Інсталятори</span><span class="num dim">${mb(instTotal())}</span></div></div>
  <div class="note">Nora виконає по черзі <span class="mono">mo clean</span>, <span class="mono">mo purge --yes</span> і <span class="mono">mo installer</span> (обрані файли Nora позначить у меню Mole й звірить список перед підтвердженням). Великі файли не чіпаються.</div>
  <div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn primary" data-a="smartAllRun">Запустити</button></div>`);
}
function smartAllRun() {
  closeSheet(); const sm = S.smart, total = smartSafe(); sm.phase = 'runall'; S.prog = { pct: 0 }; render();
  const lines = [L('a', '$ mo clean'), L('m', 'nora: whitelist overlay +13 defaults'), L('g', `  ✓ Cleanup complete · ${mb(cleanAvail())}`), L('a', '$ mo purge --yes'), L('g', `  ✓ Purge complete · ${mb(sum(ARTS.filter(artDefault), a => a.mb))}`), L('a', '$ mo installer'), L('g', `  ✓ Installers cleaned · ${mb(instTotal())}`), L('m', 'nora: whitelist restored')];
  run('nora care · clean → purge → installer', lines, { speed: 280,
    onLine: i => { if (S.view === 'overview') progress(i, lines.length); },
    onDone: () => { sm.phase = 'done'; sm.freed = total; if (S.view === 'overview') render(); toast(`Звільнено ${mb(total)}`); },
    onStop: () => { sm.phase = 'results'; render(); } });
}
function cleanScan() {
  const c = S.clean; c.phase = 'scan'; S.prog = { pct: 0, status: 'Готую…', step: 0 }; render();
  const lines = [L('h', 'Clean Your Mac'), L('w', 'Dry Run Mode, Preview only, no deletions'), S.scen.admin ? L('g', '✓ Admin access available, system preview included') : L('m', '⚠ System caches need sudo — preview without system section')];
  CLEAN.forEach(s => { lines.push(L('a', '➤ ' + s.name)); s.items.forEach(i => lines.push(i.skip ? L('w', `  ◎ ${i.label} · skipped (${i.skip})`) : i.prot ? L('m', `  ◎ ${i.label} · protected`) : L('g', `  ✓ ${i.label} · ${i.n || 1} items, ${mb(i.mb)}`))); });
  lines.push(L('m', 'nora: preview parsed from ~/.config/mole/clean-list.txt'));
  let sec = 0;
  run(S.scen.admin ? 'sudo -A -v && mo clean --dry-run' : 'mo clean --dry-run', lines, { speed: 40,
    onLine: (i, ln) => { if (ln.s.startsWith('➤')) sec++; if (S.view === 'clean') progress(i, lines.length, `Сканую: ${CLEAN[Math.max(0, sec - 1)].name}`, Math.min(3, Math.floor(sec / 2.5))); },
    onDone: () => { c.phase = 'review'; if (S.view === 'clean') render(); },
    onStop: () => { c.phase = 'idle'; render(); } });
}
function cleanConfirm() {
  const unchecked = CLEAN_ITEMS.filter(i => selectable(i) && !S.clean.sel.has(i.id)).length;
  sheet(`<h3>Очистити ${mb(cleanTotal())}?</h3>
  <div class="note">Mole не вміє видаляти окремі позиції, тому Nora тимчасово додасть ${unchecked} знятих позицій і 13 типових захистів у whitelist, запустить очищення і відновить файл — навіть після збою.</div>
  <div class="note">Кеші й журнали видаляються остаточно; програми створять їх знову.</div>
  <div class="foot"><span class="sp">${cmd(S.scen.admin ? 'sudo -A -v && mo clean' : 'mo clean')}</span><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn primary" data-a="cleanRun">Очистити</button></div>`);
}
function cleanRun() {
  closeSheet();
  const c = S.clean, total = cleanTotal(), unchecked = CLEAN_ITEMS.filter(i => selectable(i) && !c.sel.has(i.id)).length;
  c.phase = 'run'; S.prog = { pct: 0, status: 'Готую whitelist…', step: 0 }; render();
  const lines = [L('m', 'nora: backup ~/.config/mole/whitelist'), L('m', `nora: overlay +${unchecked} unchecked, +13 Mole defaults`), L('h', 'Clean Your Mac'), S.scen.admin ? L('g', '✓ Admin access available') : L('m', 'System caches need sudo → nora answers: Space (skip)')];
  CLEAN.forEach(s => { if (s.sudo && !S.scen.admin) return; lines.push(L('a', '➤ ' + s.name)); s.items.forEach(i => { if (c.sel.has(i.id)) lines.push(L('g', `  ✓ ${i.label} · ${mb(i.mb)}`)); }); });
  lines.push(L('h', 'Cleanup complete'), L('g', `Tracked cleanup: ${mb(total)} | Items cleaned: 412`), L('m', 'nora: overlay removed, whitelist restored'));
  let sec = 0;
  run(S.scen.admin ? 'sudo -A -v && mo clean' : 'mo clean', lines, { speed: 55,
    onLine: (i, ln) => { if (ln.s.startsWith('➤')) sec++; if (S.view === 'clean') progress(i, lines.length, `Очищую: ${CLEAN[Math.max(0, sec - 1)].name}`, Math.min(3, Math.floor(sec / 2.5))); },
    onDone: () => { c.phase = 'done'; c.result = { freed: total, items: 412, cats: CLEAN.filter(s => s.items.some(i => c.sel.has(i.id))).length }; if (S.view === 'clean') render(); },
    onStop: () => { c.phase = 'review'; render(); toast('Зупинено. Whitelist відновлено.'); } });
}
function quickScan(key, state, command, lines, next, speed = 70) {
  state.phase = 'scan'; S.prog = { pct: 0, status: 'Сканую…', step: 0 }; render();
  run(command, lines, { speed, onLine: i => { if (S.view === key) progress(i, lines.length, lines[i].s.replace(/^\s*[✓○◎$]\s*/, '').slice(0, 60), Math.floor((i + 1) / lines.length * 3)); },
    onDone: () => { state.phase = next; if (S.view === key) render(); }, onStop: () => { state.phase = 'landing'; render(); } });
}
function unConfirm(dry) {
  const sel = APPS.filter(a => S.un.sel.has(a.id));
  if (dry) { run(unCmd().replace('mo uninstall', 'mo uninstall --dry-run'), [L('h', 'Uninstall preview'), ...sel.flatMap(a => { const f = appFiles(a); return [L('a', `✓ ${a.name}, ${mb(f.total)}`), ...f.groups.flatMap(g => g.files.map(p => L('m', '  ' + p)))]; }), L('w', 'Dry run: nothing removed')], { speed: 40 }); return; }
  sheet(`<h3>Видалити ${sel.length === 1 ? esc(sel[0].name) : sel.length + ' програми'}?</h3>
  <div class="legend">${sel.map(a => `<div><span class="appico" style="width:24px;height:24px;border-radius:7px;font-size:9px;background:${grad(a.name)}">${initials(a.name)}</span><span class="sp">${esc(a.name)}</span><span class="num dim">${mb(appFiles(a).total)}</span></div>`).join('')}</div>
  <div class="note">${S.un.perm ? '<b>Остаточно</b> — без Кошика.' : 'Файли буде переміщено в <b>Кошик</b>.'} Особисті дані залишаться. Nora відповість «y» на запит Mole лише після звірки списку файлів.</div>
  <div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn ${S.un.perm ? 'danger' : 'primary'}" data-a="unRun">Видалити</button></div>`);
}
function unRun() {
  closeSheet(); const u = S.un, sel = APPS.filter(a => u.sel.has(a.id)), total = sum(sel, a => appFiles(a).total), refs = sel.flatMap(a => appFiles(a).refs);
  u.phase = 'run'; S.prog = { pct: 0, status: 'Готую…', step: 0 }; render();
  const lines = [L('h', 'Files to be removed:'), ...sel.map(a => L('a', `✓ ${a.name}, ${mb(appFiles(a).total)}`)), L('m', 'Proceed with uninstallation? [y/N]  ← nora: preview matches, answering y'), ...sel.map(a => L('g', `  ✓ ${a.name} moved to Trash`)), L('g', `Removed ${sel.length} app(s), freed ${mb(total)}`)];
  run(unCmd(), lines, { speed: 140, onLine: i => { if (S.view === 'uninstall') progress(i, lines.length, i < sel.length + 2 ? 'Перевіряю файли…' : 'Видаляю…', Math.min(2, Math.floor(i / lines.length * 3))); },
    onDone: () => { u.phase = 'done'; u.done = { n: sel.length, mb: total, refs }; u.sel.clear(); if (S.view === 'uninstall') render(); }, onStop: () => { u.phase = 'list'; render(); } });
}
function purgeConfirm() {
  const isDefault = ARTS.every(a => S.purge.sel.has(a.id) === artDefault(a));
  sheet(`<h3>Видалити ${S.purge.sel.size} артефактів · ${mb(purgeTotal())}?</h3><div class="note">Вони відновлюються збиранням проєкту (npm install, cargo build…).</div>
  <div class="note">${isDefault ? 'Вибір збігається з типовим набором Mole — Nora запустить <span class="mono">mo purge --yes</span>.' : 'Вибір відрізняється від типового — Nora позначить ті самі пункти в меню Mole, звірить список на екрані й лише тоді підтвердить.'}</div>
  <div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn danger" data-a="purgeRun">Видалити</button></div>`);
}
function purgeRun() {
  closeSheet(); const p = S.purge, isDefault = ARTS.every(a => p.sel.has(a.id) === artDefault(a)), total = purgeTotal(), n = p.sel.size; p.phase = 'run'; render();
  const lines = [...(isDefault ? [] : [L('m', `nora: PTY menu driver — ${n} items, on-screen list verified ✓`)]), ...ARTS.filter(a => p.sel.has(a.id)).map(a => L('g', `  ✓ ${a.proj}/${a.k}`)), L('g', `Estimated space freed: ${mb(total)} | Items: ${n}`)];
  run(isDefault ? 'mo purge --yes' : 'mo purge', lines, { speed: 110, onLine: i => { if (S.view === 'purge') progress(i, lines.length, 'Видаляю артефакти…', Math.min(2, Math.floor(i / lines.length * 3))); },
    onDone: () => { p.phase = 'done'; p.freed = total; p.items = n; if (S.view === 'purge') render(); }, onStop: () => { p.phase = 'list'; render(); } });
}
function instRun() {
  closeSheet(); const s = S.inst, total = instTotal(), n = s.sel.size; s.phase = 'run'; render();
  const lines = [L('m', `nora: PTY menu driver — ${n} selected, on-screen list verified ✓`), ...INST.filter(i => s.sel.has(i.id)).map(i => L('g', `  ✓ ${i.name}`)), L('g', `Removed ${n} installers, freed ${mb(total)}`)];
  run('mo installer', lines, { speed: 110, onLine: i => { if (S.view === 'installer') progress(i, lines.length, 'Видаляю інсталятори…', Math.min(2, Math.floor(i / lines.length * 3))); },
    onDone: () => { s.phase = 'done'; s.freed = total; s.items = n; if (S.view === 'installer') render(); }, onStop: () => { s.phase = 'list'; render(); } });
}
function optRun() {
  const o = S.opt; o.phase = 'run'; render();
  const lines = [L('h', 'Optimize'), L('g', '✓ No sustained high-CPU bottleneck detected'), ...OPT.map(([id, n]) => { if (o.excl.has(id)) return L('m', `◎ ${n} · excluded`); const out = OPT_OUT[id] || ['unchanged']; return L(out[0] === 'applied' ? 'g' : out[0] === 'attention' ? 'w' : 'm', `${out[0] === 'applied' ? '→' : '◎'} ${n} · ${out[0]}`); })];
  run((o.verify ? 'MOLE_ENABLE_DISK_VERIFY=1 ' : '') + 'mo optimize', lines, { speed: 60, onLine: (i, ln) => { if (S.view === 'optimize') progress(i, lines.length, ln.s.replace(/^[→◎✓]\s*/, '').split(' · ')[0], Math.min(2, Math.floor(i / lines.length * 3))); },
    onDone: () => { o.out = Object.fromEntries(OPT.map(([id]) => [id, o.excl.has(id) ? ['excluded', 'Вимкнено'] : (id === 'disk_verify' && o.verify) ? ['applied', 'Файлова система справна'] : OPT_OUT[id] || ['unchanged', 'Вже в нормі']])); o.phase = 'done'; if (S.view === 'optimize') render(); },
    onStop: () => { o.phase = 'list'; render(); } });
}
function cliUpdate() {
  run('mo update', [L('h', 'Updating Mole'), L('a', '==> Upgrading mole 1.59.1 -> 1.60.0'), L('g', '✓ Mole updated to 1.60.0'), L('m', 'nora: re-probing capabilities via --help … ok')], { speed: 160, onDone: () => { if (S.scen.cli === 'old') S.scen.cli = 'ok'; render(); toast('Mole оновлено до 1.60.0'); } });
}

// ---------- palette ----------
const PAL = [
  ['Розумний догляд', 'nora smart-scan', () => { go('overview'); smartScan(); }], ['Очищення: перегляд', 'mo clean --dry-run', () => { go('clean'); cleanScan(); }],
  ['Видалити програму…', 'mo uninstall', () => go('uninstall')], ['Аналіз диска', 'mo analyze --json', () => go('analyze')],
  ['Швидкодія', 'mo optimize', () => go('optimize')], ['Стан системи', 'mo status --watch', () => go('status')],
  ['Проєкти', 'mo purge --dry-run', () => go('purge')], ['Інсталятори', 'mo installer --dry-run', () => go('installer')],
  ['Історія', 'mo history --json', () => go('history')], ['Touch ID для sudo', 'mo touchid enable', () => go('tools')],
  ['Оновити Mole', 'mo update', () => cliUpdate()], ['Показати консоль', '', () => setDrawer(true)],
];
function palRender() {
  const q = $('#palInput').value.toLowerCase(), list = PAL.filter(p => (p[0] + ' ' + p[1]).toLowerCase().includes(q));
  S.palIdx = clamp(S.palIdx, 0, Math.max(0, list.length - 1));
  $('#palList').innerHTML = list.map((p, i) => `<button class="pal-li ${i === S.palIdx ? 'on' : ''}" data-a="palRun" data-v="${PAL.indexOf(p)}">${esc(p[0])}${p[1] ? cmd(p[1]) : ''}</button>`).join('') || '<div class="empty">Немає збігів</div>';
  return list;
}
function palOpen(open) { $('#palette').hidden = !open; if (open) { $('#palInput').value = ''; S.palIdx = 0; palRender(); $('#palInput').focus(); } }

// ---------- scenarios & menu bar ----------
function renderScen() {
  const s = S.scen, radio = (k, v, n) => `<button aria-pressed="${s[k] === v}" data-a="scen" data-v="${k}:${v}">${n}</button>`;
  $('#scen').innerHTML = `<h4>Стани для перевірки</h4>
    <div class="row"><label>Mole CLI</label><div class="seg" style="margin-left:auto">${radio('cli', 'ok', 'Є')}${radio('cli', 'old', 'Застарілий')}${radio('cli', 'missing', 'Немає')}</div></div>
    <div class="row"><label>Повний доступ до диска</label><div class="seg" style="margin-left:auto">${radio('fda', true, 'Так')}${radio('fda', false, 'Ні')}</div></div>
    <div class="row"><label>Права адміністратора</label><div class="seg" style="margin-left:auto">${radio('admin', false, 'Немає')}${radio('admin', true, 'Сесія sudo')}</div></div>`;
}
// status item label by mode: icon only, icon + CPU, mini sparkline, several metrics
function mbLabel() {
  const m = S.set.mbMode, cpu = nf0.format(live.cpu.at(-1)) + ' %';
  if (m === 'icon') return '';
  if (m === 'spark') return `<span style="display:inline-block;width:38px;vertical-align:middle">${spark(live.cpu.slice(-24), { w: 76, h: 16, max: 100, color: '#ff8ac6' })}</span>`;
  if (m === 'multi') return `CPU ${cpu} · RAM ${nf0.format(live.mem.at(-1))} % · ↓${nf1.format(live.down.at(-1))}`;
  return cpu;
}
const MB_MENU = [['open', 'Відкрити Nora'], ['overview', 'Розумний догляд'], ['clean', 'Очищення'], ['optimize', 'Швидкодія'], ['status', 'Стан системи'], ['-'], ['pause', 'Призупинити оновлення'], ['settings', 'Налаштування…'], ['-'], ['quit', 'Вийти з Nora']];
function showMbMenu(x) {
  const m = $('#mbMenu'); m.innerHTML = MB_MENU.map(([k, t]) => k === '-' ? '<div class="hr" style="margin:4px 0"></div>' : `<button class="qm-row" style="width:100%" data-a="mbMenuAct" data-v="${k}">${t}${k === 'open' ? '<span class="sp"></span><span class="kbd">⌥⌘N</span>' : ''}</button>`).join('');
  m.hidden = false; m.style.left = Math.max(8, x - 120) + 'px';
}
function renderMb() {
  const gi = k => glassSrc(MODS[k].hero);
  $('#mbPop').innerHTML = `<div class="qm-head">${gi('overview') ? `<img src="${gi('overview')}" alt="">` : ''}<div class="sp"><b style="font:600 15px var(--f-display)">Nora</b><div class="note">MacBook Pro · аптайм 6 д</div></div><button class="iconbtn" title="Налаштування" data-a="mbAct" data-v="settings">${ic('i-settings')}</button></div>
  <div data-live="mb">${LIVE.mb()}</div>
  <div class="qm-call"><div class="sp"><small class="dim">Можна звільнити</small><div style="font:500 18px var(--f-display)">${mb(smartSafe())}</div></div><button class="btn primary sm" data-a="mbAct" data-v="smart">Очистити</button><button class="btn sm" data-a="mbAct" data-v="optimize">Оптимізувати</button></div>
  <div class="qm-nav">${['overview', 'clean', 'uninstall', 'optimize', 'analyze', 'status'].map(k => `<button class="qm-row" data-a="mbAct" data-v="${k}">${gi(k) ? `<img src="${gi(k)}" alt="">` : ic(MODS[k].ic)}<span class="ell">${MODS[k].n}</span></button>`).join('')}</div>
  <div class="qm-foot"><span class="sp">Mole 1.59.1 · є 1.60.0</span><button class="btn sm" data-a="mbAct" data-v="update">Оновити</button></div>
  <div class="row"><button class="btn primary sm sp" data-a="mbAct" data-v="open">Відкрити Nora</button><button class="btn ghost sm" data-a="mbAct" data-v="quit">Вийти</button></div>`;
}

// ---------- actions ----------
const A = {
  go: v => go(v),
  toggleScen: () => { S.scenOpen = !S.scenOpen; $('#scen').hidden = !S.scenOpen; $('#scenBtn').setAttribute('aria-pressed', S.scenOpen); if (S.scenOpen) renderScen(); },
  scen: v => { const [k, raw] = v.split(':'); S.scen[k] = raw === 'true' ? true : raw === 'false' ? false : raw; if (k === 'cli' && raw !== 'missing') closeSheet(); renderScen(); render(); },
  toggleMb: () => { S.mb = !S.mb; $('#mbPop').hidden = !S.mb; $('#mbBtn').setAttribute('aria-pressed', S.mb); if (S.mb) renderMb(); },
  mbMenuAct: v => { $('#mbMenu').hidden = true; if (v === 'pause') toast('Оновлення показників призупинено'); else A.mbAct(v); if (S.mb && v !== 'pause') {} },
  mbTop: v => { S.mbTop = v; document.querySelectorAll('[data-live="mb"]').forEach(el => { el.innerHTML = LIVE.mb(); }); },
  mbMode: v => { S.set.mbMode = v; $('#mbCpu').innerHTML = mbLabel(); render(true); },
  mbAct: v => { if (S.mb) A.toggleMb(); if (v === 'smart') { go('overview'); smartScan(); } else if (v === 'update') cliUpdate(); else if (v === 'quit') toast('Nora закрито (у прототипі вікно лишається)'); else go(v === 'open' ? S.view : v); },
  palette: () => palOpen(true), palRun: v => { palOpen(false); PAL[+v][2](); },
  drawer: () => setDrawer(!S.drawer.open),
  copyCmd: () => { const t = S.drawer.cmd; if (!t) return; try { navigator.clipboard.writeText(t).then(() => toast('Команду скопійовано'), () => toast(t)); } catch (e) { toast(t); } },
  stopRun: () => { const d = S.drawer; if (d.state !== 'run') return; clearTimeout(d.timer); d.state = 'stopped'; d.lines.push(L('w', '^C  nora: SIGINT → Mole завершує поточний крок')); paintDrawer(); d.onStop && d.onStop(); },
  toast: v => toast(v), closeSheet: () => closeSheet(),
  auth: v => authSheet(v === 'cleanSys' ? 'Системні кеші' : S.scen.admin ? 'Сесія активна ще 4:58' : 'Права для системних дій', v === 'cleanSys' ? 'cleanScan' : null),
  authOk: () => { S.scen.admin = true; closeSheet(); toast('Права адміністратора надано на 5 хвилин'); if (authSheet.then === 'cleanScan') cleanScan(); else render(); },
  doneOk: v => { const st = { overview: S.smart, clean: S.clean, uninstall: S.un, optimize: S.opt, purge: S.purge, installer: S.inst, security: S.sec }[v]; if (st) st.phase = v === 'clean' ? 'idle' : 'landing'; render(); },
  secScope: v => { S.sec.scope = v; render(true); },
  secInstall: () => run('brew install clamav', [L('a', '==> Installing clamav 1.5.4 (+ yara 4.5.8)'), L('g', '🍺  /opt/homebrew/Cellar/clamav/1.5.4'), L('m', 'nora: config → ~/Library/Application Support/Nora/clamav'), L('a', '$ freshclam'), L('g', 'daily.cvd updated · main.cvd · bytecode.cvd')], { speed: 260, onDone: () => { S.sec.clam = true; render(true); toast('ClamAV встановлено, бази оновлено'); } }),
  secScan: () => quickScan('security', S.sec, 'nora security-scan', [L('m', 'audit: launch agents/daemons, login items, extensions … 64'), L('m', 'codesign + spctl: 212 apps'), L('a', '$ yara XProtect.yara ~/Downloads /Applications'), ...(S.sec.clam ? [L('a', '$ clamd --foreground (session) · clamdscan --fdpass'), L('w', '  ~/Downloads/Setup_Player_Pro.dmg: Osx.Adware.Bundlore FOUND')] : []), L('g', '5 findings to review')], 'list', 220),
  secCheck: (v, el) => { el.checked ? S.sec.sel.add(v) : S.sec.sel.delete(v); render(true); },
  secMove: () => sheet(`<h3>Перемістити ${S.sec.sel.size} у карантин?</h3><div class="note">Агенти автозапуску спершу буде вивантажено. Файли переміщуються в карантин Nora разом із метаданими (шлях, власник, права, причина) і відновлюються одним кліком.</div><div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn danger" data-a="secMoveRun">У карантин</button></div>`),
  secMoveRun: () => { closeSheet(); const n = S.sec.sel.size; run('nora quarantine', [L('m', 'launchctl bootout gui/501/com.mac.updater.helper'), L('g', `moved ${n} item(s) → ~/Library/Application Support/Nora/Quarantine`)], { speed: 300, onDone: () => { S.sec.q.push(...S.sec.sel); S.sec.moved = n; S.sec.sel.clear(); S.sec.phase = 'done'; render(); } }); },
  secQuar: () => sheet(`<h3>Карантин</h3>${S.sec.q.length ? SEC_FIND.filter(f => S.sec.q.includes(f.id)).map(f => `<div class="opt-row"><span class="sp ell">${esc(f.t)}</span><button class="btn sm" data-a="secRestore" data-v="${f.id}">Відновити</button></div>`).join('') : '<div class="note">Карантин порожній.</div>'}<div class="foot"><button class="btn primary" data-a="closeSheet">Готово</button></div>`),
  secRestore: v => { S.sec.q = S.sec.q.filter(i => i !== v); closeSheet(); toast('Відновлено на попереднє місце'); render(true); },
  smart: () => smartScan(), smartAll: () => smartAll(), smartAllRun: () => smartAllRun(),
  cleanScan: () => cleanScan(), cleanConfirm: () => cleanConfirm(), cleanRun: () => cleanRun(),
  cleanOptSys: (v, el) => { if (el.checked && !S.scen.admin) { el.checked = false; authSheet('Системні кеші', null); } },
  cleanTrash: (v, el) => { el.checked ? S.clean.sel.add('u3') : S.clean.sel.delete('u3'); },
  secToggle: (v, el, e) => { if (e.target.closest('input')) return; S.clean.open.has(v) ? S.clean.open.delete(v) : S.clean.open.add(v); render(true); },
  secCheck: (v, el) => { CLEAN.find(s => s.id === v).items.filter(selectable).forEach(i => el.checked ? S.clean.sel.add(i.id) : S.clean.sel.delete(i.id)); render(true); },
  itemCheck: (v, el) => { el.checked ? S.clean.sel.add(v) : S.clean.sel.delete(v); render(true); },
  protectItem: v => { const i = CLEAN_ITEMS.find(x => x.id === v), p = i.path.split(' ·')[0]; S.clean.sel.delete(v); S.prot.custom.push(p); toast(`Додано до захисту: ${p}`); render(true); },
  unScan: () => quickScan('uninstall', S.un, 'mo uninstall --list', [L('m', 'Scanning /Applications, ~/Applications, Steam…'), ...APPS.map(a => L('g', `  ✓ ${a.name} · ${mb(a.mb)}`))], 'list', 45),
  unQ: (v, el) => { S.un.q = el.value; const pos = el.selectionStart; render(true); const n = $('#unQ'); n.focus(); n.setSelectionRange(pos, pos); },
  unSrc: v => { S.un.src = v; render(true); }, unSort: (v, el) => { S.un.sort = el.value; render(true); },
  unFocus: (v, el, e) => { if (e.target.closest('input')) return; S.un.focus = v; render(true); },
  unCheck: (v, el) => { el.checked ? S.un.sel.add(v) : S.un.sel.delete(v); S.un.focus = v; render(true); },
  unPerm: v => { S.un.perm = v === '1'; render(true); }, unDry: () => unConfirm(true), unConfirm: () => unConfirm(false), unRun: () => unRun(),
  personalData: () => sheet(`<h3>Особисті дані</h3><p class="note" style="margin:0">У Mole вибір особистих даних (клавіша <span class="mono">D</span>) є лише в інтерактивному режимі. Nora відкриє його у вбудованому терміналі.</p><div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn primary" data-a="pdTerm">${ic('i-term')}Відкрити в терміналі</button></div>`),
  pdTerm: () => { closeSheet(); run(unCmd(), [L('h', 'Files to be removed:'), L('m', 'Personal data kept: 2 paths'), L('w', 'D choose personal data   (інтерактивний режим)')], { speed: 120 }); },
  optScan: () => quickScan('optimize', S.opt, 'mo optimize --dry-run', [L('m', '⚙ System 18/32 GB RAM | 692/995 GB Disk | Uptime 6d'), L('g', '✓ No sustained high-CPU bottleneck detected'), ...OPT.slice(0, 8).map(([, n]) => L('m', `◎ ${n} · checked`))], 'list', 60),
  optToggle: (v, el) => { el.checked ? S.opt.excl.delete(v) : S.opt.excl.add(v); render(true); }, optVerify: (v, el) => { S.opt.verify = el.checked; render(true); }, optRun: () => optRun(),
  anScan: () => quickScan('analyze', S.an, `mo analyze --json "${S.an.vol === 'hd' ? '/' : '/Volumes/Archive'}"`, [L('m', 'Scanning overview…'), L('g', '  ✓ Домашня тека'), L('g', '  ✓ Бібліотека користувача'), L('g', '  ✓ Програми'), L('w', '  ◎ Системна бібліотека · partial'), L('g', '  ✓ Insights: Old Downloads (90d+), iOS Backups')], 'map', 160),
  anVolSel: (v, el) => { S.an.vol = el.value; S.an.path = []; },
  anIn: v => { S.an.path = [...S.an.path, +v]; render(true); }, anUp: v => { S.an.path = S.an.path.slice(0, +v); render(true); },
  anMode: v => { S.an.mode = v; render(true); }, anReset: () => { S.an.phase = 'landing'; S.an.path = []; render(); },
  anTrash: () => sheet(`<h3>Перемістити «${esc(anNode().n)}» у Кошик?</h3><div class="note">Як і в <span class="mono">mo analyze</span>: елемент іде в Кошик після підтвердження, його можна відновити.</div><div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn danger" data-a="closeSheet">У Кошик</button></div>`),
  purgeScan: () => quickScan('purge', S.purge, 'mo purge --dry-run', [L('h', 'Purge Project Artifacts'), ...ARTS.map(a => L(a.recent ? 'w' : 'g', `  ${a.recent ? '○' : '✓'} ${a.proj}/${a.k}`))], 'list', 60),
  purgeCheck: (v, el) => { el.checked ? S.purge.sel.add(v) : S.purge.sel.delete(v); render(true); }, purgeEmpty: (v, el) => { S.purge.empty = el.checked; render(true); },
  purgeConfirm: () => purgeConfirm(), purgeRun: () => purgeRun(),
  instScan: () => quickScan('installer', S.inst, 'mo installer --dry-run', [L('h', 'Scanning Downloads, Desktop, Homebrew, iCloud, Mail, Telegram'), ...INST.map(i => L('m', `  ○ ${i.name}  ${mb(i.mb)}`))], 'list', 60),
  instCheck: (v, el) => { el.checked ? S.inst.sel.add(v) : S.inst.sel.delete(v); render(true); },
  instAll: v => { INST.forEach(i => { const on = v === '1' ? true : !S.inst.sel.has(i.id); on ? S.inst.sel.add(i.id) : S.inst.sel.delete(i.id); }); render(true); },
  instConfirm: () => sheet(`<h3>Видалити ${S.inst.sel.size} інсталяторів · ${mb(instTotal())}?</h3><div class="note">Nora позначить ті самі файли в меню Mole і звірить список на екрані перед підтвердженням.</div><div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn danger" data-a="instRun">Видалити</button></div>`),
  instRun: () => instRun(),
  extClean: () => sheet(`<h3>Зовнішній диск</h3><div class="note">Mole прибере лише метадані macOS (.DS_Store, ._*) з обраного тому.</div><select class="field" aria-label="Том"><option>/Volumes/USB-STICK</option><option>/Volumes/Archive</option></select><div class="foot"><button class="btn" data-a="closeSheet">Скасувати</button><button class="btn primary" data-a="extRun">Очистити</button></div>`),
  extRun: () => { closeSheet(); run('mo clean --external /Volumes/USB-STICK', [L('h', 'Clean External Volume'), L('g', '  ✓ .DS_Store · 214 files'), L('g', '  ✓ AppleDouble ._* · 1 380 files')], { speed: 160, onDone: () => toast('Метадані з USB-STICK прибрано') }); },
  histF: v => { S.hist.f = v; render(true); }, histOpen: v => { S.hist.open = S.hist.open === v ? null : v; render(true); },
  protTab: v => { S.prot.tab = v; render(true); }, protDel: v => { S.prot.custom.splice(+v, 1); render(true); }, protAdd: () => toast('Відкриється вибір теки'),
  wlToggle: (v, el) => { const key = WL_DEFAULT.has(v) ? v : '+' + v; (WL_DEFAULT.has(v) ? !el.checked : el.checked) ? S.prot.off.add(key) : S.prot.off.delete(key); toast('Збережено в ~/.config/mole/whitelist'); },
  setToggle: (v, el) => { S.set[v] = el.checked; if (v === 'touchid') run(`mo touchid ${el.checked ? 'enable' : 'disable'}`, [L('m', 'Requires admin → system dialog'), L('g', `✓ Touch ID for sudo ${el.checked ? 'enabled' : 'disabled'}`)], { speed: 200 }); },
  setSched: (v, el) => { S.set.schedule = el.value; toast('Розклад збережено'); },
  cliUpdate: () => cliUpdate(),
  cliInstall: () => {
    const steps = ['Пошук Homebrew', 'Встановлення mole', 'Перевірка mo --version', 'Перевірка можливостей CLI'], box = $('#instSteps');
    if (!box) return; box.hidden = false; $('#instBtn').disabled = true;
    const paint = k => { box.innerHTML = steps.map((t, i) => `<div class="inst-step">${i < k ? `<span style="color:var(--good)">${ic('i-check')}</span>` : i === k ? '<span class="spin"></span>' : '<span style="width:16px"></span>'}<span class="${i > k ? 'muted' : ''}">${t}</span></div>`).join(''); };
    paint(0);
    run('brew install mole', [L('a', '==> Fetching mole'), L('a', '==> Installing mole'), L('g', '🍺  /opt/homebrew/Cellar/mole/1.59.1'), L('m', 'nora: mo --version → 1.59.1'), L('m', 'nora: capabilities 7/7 ok')], { speed: 380,
      onLine: i => paint(Math.min(3, i)), onDone: () => { paint(4); setTimeout(() => { S.scen.cli = 'ok'; closeSheet(); if (S.scenOpen) renderScen(); render(); toast('Mole встановлено — Nora готова до роботи'); }, 500); } });
  },
};
document.addEventListener('click', e => {
  const el = e.target.closest('[data-a]');
  if (el && el.tagName !== 'SELECT' && !(el.tagName === 'INPUT' && el.type !== 'checkbox')) { const f = A[el.dataset.a]; if (f) f(el.dataset.v, el, e); }
  if (e.target === $('#sheet') && S.scen.cli !== 'missing') closeSheet();
  if (e.target === $('#palette')) palOpen(false);
});
document.addEventListener('contextmenu', e => { if (e.target.closest('#mbBtn')) { e.preventDefault(); if (S.mb) A.toggleMb(); showMbMenu(e.clientX); } });
document.addEventListener('mousedown', e => { const m = $('#mbMenu'); if (m && !m.hidden && !e.target.closest('#mbMenu')) m.hidden = true; });
document.addEventListener('input', e => { const el = e.target; if (el.id === 'palInput') { S.palIdx = 0; palRender(); } else if (el.dataset.a === 'unQ') A.unQ(null, el); });
document.addEventListener('change', e => { const el = e.target; if (el.tagName === 'SELECT' && el.dataset.a && A[el.dataset.a]) A[el.dataset.a](el.value, el, e); });
document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); palOpen($('#palette').hidden); return; }
  if (e.key === 'Escape') { if (!$('#palette').hidden) palOpen(false); else if (!$('#sheet').hidden && S.scen.cli !== 'missing') closeSheet(); return; }
  if (!$('#palette').hidden && ['ArrowDown', 'ArrowUp', 'Enter'].includes(e.key)) {
    e.preventDefault(); const list = palRender();
    if (e.key === 'Enter') { const p = list[S.palIdx]; if (p) { palOpen(false); p[2](); } return; }
    S.palIdx += e.key === 'ArrowDown' ? 1 : -1; palRender(); return;
  }
  if ((e.metaKey || e.ctrlKey) && /^[1-8]$/.test(e.key)) { e.preventDefault(); go(RAIL.filter(Boolean)[+e.key - 1]); }
});

document.addEventListener('pointermove', e => { const h = e.target.closest && e.target.closest('.hero3d'); document.querySelectorAll('.hero3d').forEach(el => { if (el !== h) { el.style.removeProperty('--rx'); el.style.removeProperty('--ry'); } }); if (!h) return; const r = h.getBoundingClientRect(); h.style.setProperty('--ry', (((e.clientX - r.left) / r.width - 0.5) * 16).toFixed(1) + 'deg'); h.style.setProperty('--rx', (-((e.clientY - r.top) / r.height - 0.5) * 12).toFixed(1) + 'deg'); });
renderRail(); render(); paintDrawer();
setInterval(tick, 1000);
(function menubarClock() {
  const upd = () => { const d = new Date(); $('#clock').textContent = d.toLocaleDateString('uk-UA', { weekday: 'short', day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString('uk-UA', { hour: '2-digit', minute: '2-digit' }); $('#mbCpu').innerHTML = mbLabel(); };
  $('#mbIco').src = glassSrc('vessel');
  upd(); setInterval(upd, 1000);
})();
