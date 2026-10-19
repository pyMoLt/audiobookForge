#!/usr/bin/env python3
"""Writes Resources/Localizable.xcstrings from scripts/l10n_en.json.

Source language is German (the strings in the code); every entry carries its
English translation. Re-run after editing l10n_en.json:
    python3 scripts/l10n_build_catalog.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "scripts", "l10n_en.json")
OUT = os.path.join(ROOT, "AudiobookForge", "AudiobookForge", "Resources", "Localizable.xcstrings")

en = json.load(open(SRC, encoding="utf-8"))
catalog = {"sourceLanguage": "de", "version": "1.0", "strings": {}}
for key in sorted(en):
    catalog["strings"][key] = {
        "extractionState": "manual",
        "localizations": {"en": {"stringUnit": {"state": "translated", "value": en[key]}}},
    }
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(en)} Einträge → {os.path.relpath(OUT, ROOT)}")
