#!/usr/bin/env python3
"""Nora localization.

  python3 scripts/l10n.py extract   collect UI keys into App/Localization/keys.json and list
                                    keys that uk.json / ru.json do not translate yet
  python3 scripts/l10n.py build     write App/Nora/Resources/Localizable.xcstrings

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
        keys.update(re.findall(r'scanTitle: "([^"]+)"', text))
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


def build():
    keys = json.load(open(os.path.join(L10N, "keys.json"), encoding="utf-8"))
    translations = {lang: load(lang) for lang in LANGS + ["en"]}
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
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    done = {lang: sum(1 for k in keys if k in translations[lang]) for lang in LANGS}
    print(f"wrote {os.path.relpath(CATALOG, ROOT)}: {len(keys)} keys, translated {done}")


if __name__ == "__main__":
    {"extract": extract, "build": build}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
