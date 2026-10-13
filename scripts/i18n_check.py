#!/usr/bin/env python3
"""Report Ukrainian prototype copy that has no entry in prototype/i18n-en.js or i18n-ru.js.

Usage: python3 scripts/i18n_check.py   (exit code 1 if anything is missing)

A "fragment" is a run of display text inside one literal: ASCII quotes, backticks,
`${`, tags and entities end it, exactly as the browser will later see the text.
"""
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "prototype"
CYR = "Ѐ-ӿ"
RUN = re.compile(r"[\w" + CYR + r"’ʼ \t,.:;!?«»()\[\]—–\-…/%+№·°×→←↑↓≈≤≥⌘⌥⇧↵✓●○➤]+")


def fragments():
    seen = []
    for name in ("index.html", "app.js"):
        for line in (ROOT / name).read_text().splitlines():
            for match in RUN.finditer(html.unescape(line)):
                text = match.group(0).strip()
                if re.search("[" + CYR + "]", text) and text not in seen:
                    seen.append(text)
    return seen


def dictionary(lang="en"):
    source = (ROOT / f"i18n-{lang}.js").read_text()
    return json.loads("{" + source[source.index("{") + 1 : source.rindex("}")] + "}")


# A value still in the source language: any Cyrillic in English, Ukrainian-only letters in Russian.
LEFTOVER = {"en": "[" + CYR + "]", "ru": "[ІіЇїЄєҐґ]"}


def main():
    found, failed = fragments(), False
    for lang, leftover in LEFTOVER.items():
        table = dictionary(lang)
        missing = [f for f in found if f not in table]
        untranslated = [k for k, v in table.items() if re.search(leftover, v)]
        for text in missing:
            print(f"{lang} missing: {text}")
        for key in untranslated:
            print(f"{lang} untranslated: {key}")
        print(f"{lang}: {len(found)} fragments, {len(table)} entries, {len(missing)} missing")
        failed = failed or bool(missing or untranslated)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
