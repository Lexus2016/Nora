// Prototype localization: English, Ukrainian, Russian. The public prototype opens in English;
// `?lang=uk` or `?lang=ru` shows the other two (the README screenshots use them). Not stored.
// The app itself follows the system language.
// Ukrainian is the source copy; English and Russian come from i18n-en.js / i18n-ru.js. The source
// strings stay untouched (app.js compares some of them); rendered text and labels are translated
// after every DOM change.
(function () {
  const SUPPORTED = ['en', 'uk', 'ru'];
  const LOCALES = { en: 'en-US', uk: 'uk-UA', ru: 'ru-RU' };
  const param = new URLSearchParams(location.search).get('lang');
  const lang = SUPPORTED.includes(param) ? param : 'en';

  window.NORA_LANG = lang;
  window.NORA_LOCALE = LOCALES[lang];
  document.documentElement.lang = lang;
  if (lang === 'uk') return;

  const DICT = (lang === 'ru' ? window.NORA_RU : window.NORA_EN) || {};
  if (!Object.keys(DICT).length) return; // a dictionary that failed to load: keep the source text
  const CYR = /[Ѐ-ӿ]/;
  const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // Longest first, and never inside a word: one-letter fragments ("з", "у") must not hit "зараз".
  const fragments = new RegExp(
    '(?<![\\p{L}\\p{N}])(?:' + Object.keys(DICT).sort((a, b) => b.length - a.length).map(escape).join('|') + ')(?![\\p{L}\\p{N}])',
    'gu'
  );
  const has = k => Object.prototype.hasOwnProperty.call(DICT, k);
  const upper = new Map(Object.keys(DICT).map(k => [k.toUpperCase(), k]));
  // What we wrote, per node and attribute: Russian output is Cyrillic too and must not be translated again.
  const done = new WeakMap();
  const doneAttr = new WeakMap();
  // Whole text first; then text app.js upper-cased or cut to "…" after rendering; then fragments.
  const whole = t => {
    if (has(t)) return DICT[t];
    if (t === t.toUpperCase() && upper.has(t)) return DICT[upper.get(t)].toUpperCase();
    if (t.endsWith('…') && t.length > 8) {
      const head = t.slice(0, -1), key = Object.keys(DICT).find(k => k.startsWith(head));
      if (key) { const v = DICT[key]; return v.length > head.length + 1 ? v.slice(0, head.length).trimEnd() + '…' : v; }
    }
    return null;
  };
  const tr = s => {
    if (!s || !CYR.test(s)) return s;
    const t = s.trim(), w = whole(t);
    if (w !== null) return s.replace(t, () => w);
    return s.replace(fragments, m => DICT[m]);
  };

  const ATTRS = ['title', 'placeholder', 'aria-label', 'alt'];
  const text = n => {
    const p = n.parentNode;
    if (p && (p.nodeName === 'SCRIPT' || p.nodeName === 'STYLE')) return;
    if (done.get(n) === n.nodeValue || !CYR.test(n.nodeValue)) return;
    const v = tr(n.nodeValue);
    if (v !== n.nodeValue) n.nodeValue = v; // write only on change, or the observer would loop
    done.set(n, n.nodeValue);
  };
  const attrs = el => {
    const mine = doneAttr.get(el) || {};
    for (const a of ATTRS) {
      const old = el.getAttribute(a);
      if (!old || !CYR.test(old) || mine[a] === old) continue;
      const v = tr(old);
      mine[a] = v;
      if (v !== old) el.setAttribute(a, v);
    }
    doneAttr.set(el, mine);
  };
  const walk = root => {
    if (root.nodeType === 3) return text(root);
    if (root.nodeType !== 1) return;
    attrs(root);
    const it = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let n = it.nextNode(); n; n = it.nextNode()) n.nodeType === 3 ? text(n) : attrs(n);
  };

  new MutationObserver(list => {
    for (const m of list) {
      if (m.type === 'characterData') text(m.target);
      else if (m.type === 'attributes') attrs(m.target);
      else m.addedNodes.forEach(walk);
    }
  }).observe(document.documentElement, {
    subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS,
  });
  walk(document.documentElement);
  document.title = tr(document.title);
})();
