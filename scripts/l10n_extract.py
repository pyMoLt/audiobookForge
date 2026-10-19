#!/usr/bin/env python3
"""Collect user-facing German UI strings for the String Catalog (v3.1).

Scans Swift sources for string literals WITHOUT interpolation that look like
natural language and writes them as JSON (key -> existing English or "").
Interpolated texts are listed separately so they can be converted to
`String(localized:)` / Text interpolation by hand.

Usage: python3 scripts/l10n_extract.py > /tmp/strings.json
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "AudiobookForge", "AudiobookForge", "Sources")
SCAN = ["UI", "App", "Models", "Services/TopicClassifier.swift", "Services/LanguageDetector.swift", "Pipeline/TTS/TTSEngine.swift"]

LITERAL = re.compile(r'(?<![\\#])"((?:[^"\\\n]|\\.)*)"')
GERMAN_HINT = re.compile(r"[äöüÄÖÜß]|\b(der|die|das|und|oder|nicht|für|mit|ein|eine|wird|werden|ist|Buch|Kapitel|Stimme|Einstellungen)\b")


def looks_like_text(s: str) -> bool:
    if len(s) < 2 or "\\(" in s:
        return False
    if re.fullmatch(r"[a-z0-9_.\-]+", s):          # identifiers, SF symbols, raw values
        return False
    if s.startswith(("http", "/", "com.", "ABF", "abf-", "sidebar.", "player.", "reader.", "library.", "ambient.")):
        return False
    if re.fullmatch(r"[%\d\s.,:×x*+\-/()·]+[a-zA-Z%]*", s):  # formats like "%.2f×"
        return False
    return bool(re.search(r"[A-Za-zÄÖÜäöü]{2,}", s))


def files():
    for entry in SCAN:
        path = os.path.join(ROOT, entry)
        if os.path.isfile(path):
            yield path
            continue
        for d, _, names in os.walk(path):
            for n in names:
                if n.endswith(".swift") and "DebugAutomation" not in n:
                    yield os.path.join(d, n)


def main():
    plain, interpolated = {}, {}
    for path in sorted(files()):
        rel = os.path.relpath(path, ROOT)
        for lineno, line in enumerate(open(path, encoding="utf-8"), 1):
            code = line.split("//")[0] if '"' not in line.split("//")[0][-1:] else line
            if code.strip().startswith(("///", "//", "print(", "logger", "Logger")):
                continue
            for m in LITERAL.finditer(code):
                s = m.group(1)
                if "\\(" in s:
                    if GERMAN_HINT.search(s):
                        interpolated.setdefault(s, f"{rel}:{lineno}")
                elif looks_like_text(s):
                    plain.setdefault(s, f"{rel}:{lineno}")
    json.dump({"plain": plain, "interpolated": interpolated}, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
