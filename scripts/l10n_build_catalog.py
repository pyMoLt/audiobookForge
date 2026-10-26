#!/usr/bin/env python3
"""Writes Resources/Localizable.xcstrings from scripts/l10n_<lang>.json.

Source language is German (the strings in the code); every entry carries its
translations: English (l10n_en.json) and, since v4, French, Spanish and
Italian (l10n_fr.json, l10n_es.json, l10n_it.json). Keys missing in a
language fall back to the English text. Re-run after editing:
    python3 scripts/l10n_build_catalog.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "scripts", "l10n_en.json")
OUT = os.path.join(ROOT, "AudiobookForge", "Resources", "Localizable.xcstrings")

en = json.load(open(SRC, encoding="utf-8"))
others = {}
for lang in ("fr", "es", "it"):
    path = os.path.join(ROOT, "scripts", f"l10n_{lang}.json")
    others[lang] = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
catalog = {"sourceLanguage": "de", "version": "1.0", "strings": {}}
missing = {lang: 0 for lang in others}
for key in sorted(en):
    localizations = {"en": {"stringUnit": {"state": "translated", "value": en[key]}}}
    for lang, table in others.items():
        if key in table:
            localizations[lang] = {"stringUnit": {"state": "translated", "value": table[key]}}
        else:
            missing[lang] += 1
            localizations[lang] = {"stringUnit": {"state": "needs_review", "value": en[key]}}
    catalog["strings"][key] = {"extractionState": "manual", "localizations": localizations}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(en)} Einträge → {os.path.relpath(OUT, ROOT)}; ohne Übersetzung (Englisch als Ersatz): {missing}")
