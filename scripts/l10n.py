#!/usr/bin/env python3
"""Nora localization.

  python3 scripts/l10n.py extract   collect UI keys into App/Localization/keys.json and list
                                    keys that uk.json / ru.json do not translate yet
  python3 scripts/l10n.py build     write App/Nora/Resources/Localizable.xcstrings
  python3 scripts/l10n.py check     exit 1 when a key lacks a uk/ru translation, a translation's
                                    format specifiers differ from the key's, a plural misses
                                    "other", or the committed catalog is not what build writes

Keys come from the compiler's .stringsdata (build the app first) plus the keys Nora builds at
run time: module titles and summaries, orb titles. A translation is either a string or a plural
object {"one": ..., "few": ..., "many": ..., "other": ...} for keys with a single %lld.
English plurals for counted keys live in en.json.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L10N = os.path.join(ROOT, "App", "Localization")
DERIVED = os.path.join(ROOT, "build", "DerivedData", "Build", "Intermediates.noindex", "Nora.build")
CATALOG = os.path.join(ROOT, "App", "Nora", "Resources", "Localizable.xcstrings")
LANGS = ["uk", "ru"]


def runtime_keys():
    keys = set()
    module = open(os.path.join(ROOT, "App", "Nora", "Core", "Module.swift"), encoding="utf-8").read()
    for block in ("var titleText: String", "var summary: String"):
        start = module.index(block)
        body = module[start:module.index("\n    }\n", start)]
        keys.update(re.findall(r'case \.[a-zA-Z]+: "([^"]+)"', body))
    for path in glob.glob(os.path.join(ROOT, "App", "Nora", "**", "*.swift"), recursive=True):
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r'OrbAction\(title: ([^,]+?),', text):
            keys.update(re.findall(r'"([^"\\]+)"', m.group(1)))
        keys.update(re.findall(r'scanTitle(?:: String)?(?: =|:) "([^"]+)"', text))
        keys.update(re.findall(r'LocalizedStringKey\("([^"\\]+)"\)', text))
    return keys


def compiled_keys():
    keys = set()
    files = [f for f in glob.glob(os.path.join(DERIVED, "**", "*.stringsdata"), recursive=True) if "Tests" not in f]
    if not files:
        sys.exit("No .stringsdata found: build the app first (xcodebuild ... build).")
    for f in files:
        data = json.load(open(f, encoding="utf-8"))
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    return keys


def load(lang):
    path = os.path.join(L10N, f"{lang}.json")
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}


def extract():
    keys = sorted(k for k in compiled_keys() | runtime_keys() if k.strip() and not re.fullmatch(r"[%@\d\s\W]*", k))
    os.makedirs(L10N, exist_ok=True)
    json.dump(keys, open(os.path.join(L10N, "keys.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{len(keys)} keys")
    for lang in LANGS:
        missing = [k for k in keys if k not in load(lang)]
        print(f"{lang}: {len(missing)} missing")
        if missing:
            json.dump(missing, open(os.path.join(L10N, f"missing-{lang}.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, dict):
        return {"variations": {"plural": {form: unit(text) for form, text in value.items()}}}
    return unit(value)


def catalog_text(keys, translations):
    strings = {}
    for key in keys:
        entry = {"localizations": {}}
        for lang in ["en"] + LANGS:
            if key in translations[lang]:
                entry["localizations"][lang] = localization(translations[lang][key])
        if not entry["localizations"]:
            entry = {}
        strings[key] = entry
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfFeEgGcCsSpaA%]")


def specifiers(text):
    return sorted(m for m in SPECIFIER.findall(text) if m != "%%")


def check():
    """Read-only: nothing in the source tree changes. Exit 1 on any problem."""
    keys = json.load(open(os.path.join(L10N, "keys.json"), encoding="utf-8"))
    translations = {lang: load(lang) for lang in LANGS + ["en"]}
    problems = []
    if len(set(keys)) != len(keys):
        problems.append("keys.json has duplicate keys")
    for lang in LANGS + ["en"]:
        path = os.path.join(L10N, f"{lang}.json")
        if os.path.exists(path):
            pairs = json.load(open(path, encoding="utf-8"), object_pairs_hook=lambda p: p)
            names = [k for k, _ in pairs]
            if len(set(names)) != len(names):
                problems.append(f"{lang}.json has duplicate keys")
    for key in keys:
        want = specifiers(key)
        for lang in LANGS + ["en"]:
            value = translations[lang].get(key)
            if value is None:
                if lang != "en":
                    problems.append(f"{lang}: missing {key!r}")
                continue
            forms = value if isinstance(value, dict) else {"": value}
            if isinstance(value, dict) and "other" not in value:
                problems.append(f"{lang}: plural without 'other' for {key!r}")
            for form, text in forms.items():
                if specifiers(text) != want:
                    problems.append(f"{lang}{'/' + form if form else ''}: format {specifiers(text)} != {want} in {key!r}")
    current = open(CATALOG, encoding="utf-8").read() if os.path.exists(CATALOG) else ""
    if current != catalog_text(keys, translations):
        problems.append(f"{os.path.relpath(CATALOG, ROOT)} is stale: run build")
    for problem in problems:
        print(problem)
    print(f"{len(keys)} keys, {len(problems)} problems")
    sys.exit(1 if problems else 0)


def build():
    keys = json.load(open(os.path.join(L10N, "keys.json"), encoding="utf-8"))
    translations = {lang: load(lang) for lang in LANGS + ["en"]}
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(catalog_text(keys, translations))
    done = {lang: sum(1 for k in keys if k in translations[lang]) for lang in LANGS}
    print(f"wrote {os.path.relpath(CATALOG, ROOT)}: {len(keys)} keys, translated {done}")


if __name__ == "__main__":
    {"extract": extract, "build": build, "check": check}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
