#!/usr/bin/env python3
"""
tts_bench.py — Messskript des Recherche-Schritts 8.6 (Umsetzungsplan v3).

Misst je Engine/Stimme auf DIESEM Mac:
  - Wanduhrzeit, Audiolänge, RTF (Real-Time-Factor) je Lauf (Standard: 3)
  - RAM-Spitze (ps RSS des Synthese-Prozesses, 50-ms-Sampling)
  - Fehler (leere/beschädigte Ausgaben, Timeouts)
  - Parallelität 1 und 2 (Skalierung)

Kandidaten werden über Kommandozeilen-Vorlagen definiert (BRIDGES unten) —
alles, was sich per Shell anstoßen lässt, ist messbar: die App-Bridges,
piper, mlx-audio-CLI, OmniVoice. Neue Engines brauchen nur einen Eintrag.

AUSFÜHRUNG NUR NUTZERGERECHTET — das Skript installiert nichts und lädt
keine Modelle; fehlende Umgebungen führen zu einem sauberen "skipped".

Beispiele:
    python3 scripts/tts_bench.py --list
    python3 scripts/tts_bench.py --engine kokoro-de-martin --runs 3
    python3 scripts/tts_bench.py --engine kokoro-de-martin --parallel 2
    python3 scripts/tts_bench.py --all --out docs/hoerproben/v3/messungen.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import threading
import time
import wave
from dataclasses import dataclass, asdict, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Messtexte (Plan 8.6): 3 Absätze DE-Medizin (~1200 Zeichen), 3 Absätze
# EN-Medizin, je 1 Roman-Absatz DE/EN, 1 synthetisches 10.000-Zeichen-Kapitel.
# ---------------------------------------------------------------------------

TEXT_DE_MEDIZIN = (
    "Die akute Appendizitis ist die häufigste chirurgische Notfall­erkrankung "
    "des Bauchraums. Typisch ist ein beginnender periumbilikaler Schmerz, der "
    "nach sechs bis zwölf Stunden in den rechten Unterbauch wandert (McBurney-Punkt). "
    "Bei der Untersuchung finden sich Loslassschmerz, defensiver Befund und häufig "
    "eine leichte Leukozytose von etwa 12.000 bis 15.000 pro Mikroliter. "
    "Die Diagnose stützt sich auf Anamnese, klinische Untersuchung, Labor und "
    "Sonografie; die Sensitivität der Sonografie liegt in erfahrenen Händen über "
    "achtzig Prozent.\n\n"
    "Die Therapie der Wahl ist dieappendektomie ist die laparoskopische "
    "Appendektomie, möglichst innerhalb von 24 Stunden nach Diagnosestellung. "
    "Eine antibiotische Therapie allein kommt nur bei selektierten Patienten mit "
    "unkomplizierter Entzündung infrage. Perforationen erfordern eine perioperative "
    "Antibiotikatherapie, zum Beispiel mit Ceftriaxon und Metronidazol, über "
    "drei bis fünf Tage.\n\n"
    "Differentialdiagnostisch müssen bei Frauen Adnexitis und Extrauteringravidität, "
    "bei allen Patienten Mesenteriallymphknoten­entzündung, Morbus Crohn und "
    "Nierenkolik ausgeschlossen werden. Bei Kindern und Schwangeren ist die "
    "Symptomatik oft atypisch, was die Diagnose verzögern kann."
)

TEXT_EN_MEDIZIN = (
    "Acute appendicitis remains the most common surgical emergency of the "
    "abdomen. The classic presentation begins with periumbilical pain that "
    "migrates to the right lower quadrant within six to twelve hours, localizing "
    "at McBurney's point. Physical examination typically reveals rebound "
    "tenderness, guarding, and a mild leukocytosis of about twelve thousand to "
    "fifteen thousand cells per microliter.\n\n"
    "The treatment of choice is laparoscopic appendectomy, ideally within "
    "twenty-four hours of diagnosis. Antibiotic-only management is reserved for "
    "selected patients with uncomplicated disease. Perforation mandates a three to "
    "five day course of broad-spectrum antibiotics such as ceftriaxone combined "
    "with metronidazole.\n\n"
    "In women, adnexitis and ectopic pregnancy must be excluded; in all patients, "
    "mesenteric adenitis, Crohn's disease, and renal colic mimic the condition. "
    "Children and pregnant patients often present atypically, delaying diagnosis."
)

TEXT_DE_ROMAN = (
    "Der Regen fiel in dichten Strömen auf die cobblestones des Hafenviertels, "
    "als Elias die Tür der Buchhandlung hinter sich schloss. Zwischen den "
    "Regalen, die nach altem Papier und Kaffee rochen, wartete das Manuskript, "
    "das alles verändern sollte."
)

TEXT_EN_ROMAN = (
    "The rain came down in sheets over the cobblestones of the harbor quarter "
    "as Elias pulled the shop door shut behind him. Between the shelves, "
    "smelling of old paper and coffee, the manuscript waited — the one that "
    "would change everything."
)

TEXT_DE_KAPITEL_10K = (
    "Kapitel eins. Die Pathophysiologie des septischen Schocks verläuft in "
    "drei Stadien, die ineinander übergehen. Im warmen Schock herrscht eine "
    "periphere Vasodilatation mit hohem Herzzeitvolumen. "
) * 1  # Der 10k-Kapiteltext wird unten synthetisch verlängert.


def chapter_text_10k() -> str:
    paragraphs = []
    filler = (
        "Der Patient stellt sich mit Fieber, Tachykardie und Hypotonie vor. "
        "Die Laborwerte zeigen eine Erhöhung der Entzündungsparameter. "
        "Nach Volumengabe bessert sich der Blutdruck nur unzureichend. "
        "Die Katecholamintherapie wird nach standardisiertem Protokoll begonnen. "
        "Eine Quelle der Infektion wird mittels Bildgebung gesucht. "
    )
    seed = 0
    while sum(len(p) for p in paragraphs) < 10_000:
        seed += 1
        paragraphs.append(f"Absatz {seed}. " + filler)
    return "\n\n".join(paragraphs)[:10_000]


# ---------------------------------------------------------------------------
# Kandidaten: Kommandozeilen-Vorlagen. Pfad-Platzhalter werden von außen
# gesetzt (--var KEY=VALUE). Alles, was nicht eingerichtet ist, wird skipped.
# ---------------------------------------------------------------------------

@dataclass
class BenchCase:
    key: str
    engine: str
    voice: str
    language: str
    command: list          # Platzhalter {TEXTFILE} {OUTFILE} und --var-Variablen
    produces_wav: bool = True
    notes: str = ""


BRIDGES: dict[str, list[BenchCase]] = {}

def register(case: BenchCase) -> None:
    BRIDGES.setdefault(case.engine, []).append(case)


# Bestehende App-Bridges (Pfade via --var BRIDGE_PYTHON, KOKORO_BRIDGE, ...)
register(BenchCase(
    key="kokoro-de-martin", engine="kokoro-mlx", voice="martin", language="de",
    command=["{BRIDGE_PYTHON}", "{KOKORO_BRIDGE}", "--text-file", "{TEXTFILE}",
             "--voice", "{VOICE_FILE_MARTIN}", "--speed", "1.0",
             "--model", "{MODEL_DIR_MARTIN}", "--lang-code", "g"],
    produces_wav=False,  # rohes s16le PCM auf stdout
    notes="App-Bridge: PCM auf stdout; Audiolänge aus SAMPLE_RATE + Bytes.",
))
register(BenchCase(
    key="kokoro-en-heart", engine="kokoro-mlx", voice="af_heart", language="en",
    command=["{BRIDGE_PYTHON}", "{KOKORO_BRIDGE}", "--text-file", "{TEXTFILE}",
             "--voice", "af_heart", "--speed", "1.0",
             "--model", "{KOKORO_MODEL_REPO}", "--lang-code", "a"],
    produces_wav=False,
    notes="Wie kokoro-de-martin, englische Originalstimme.",
))
register(BenchCase(
    key="piper-de-thorsten-medium", engine="piper", voice="de_DE-thorsten-medium", language="de",
    command=["{PIPER_BIN}", "-m", "{PIPER_VOICE_ONNX}", "-c", "{PIPER_VOICE_JSON}",
             "--output-file", "{OUTFILE}"],
    produces_wav=True,
))
register(BenchCase(
    key="supertonic3-M1", engine="supertonic", voice="M1", language="de",
    command=["{BRIDGE_PYTHON}", "{SUPERTONIC_BRIDGE}", "--text-file", "{TEXTFILE}",
             "--model", "{SUPERTONIC_MODEL}", "--runtime", "{SUPERTONIC_RUNTIME}",
             "--voice", "M1"],
    produces_wav=False,
))
# Nachrüstbar ohne App-Änderung (8.6-Ergebnisse) — mlx-audio CLI:
register(BenchCase(
    key="omnivoice-bf16", engine="omnivoice", voice="zero-shot", language="de",
    command=["{BRIDGE_PYTHON}", "-m", "mlx_audio.tts.generate",
             "--model", "mlx-community/OmniVoice", "--text", "{TEXT_INLINE}",
             "--output-path", "{OUTDIR}"],
    produces_wav=True,
    notes="Lokal vorhanden (LM-Studio-Ordner); RTF/RAM messen, Deutsch probehören.",
))

TEXTS = {
    "de-medizin": TEXT_DE_MEDIZIN,
    "en-medizin": TEXT_EN_MEDIZIN,
    "de-roman": TEXT_DE_ROMAN,
    "en-roman": TEXT_EN_ROMAN,
    "de-kapitel-10k": None,  # lazy via chapter_text_10k()
}


# ---------------------------------------------------------------------------
# Messung
# ---------------------------------------------------------------------------

@dataclass
class RunResult:
    case: str
    text_key: str
    run: int
    parallel: int
    wall_seconds: float | None = None
    audio_seconds: float | None = None
    rtf: float | None = None
    rss_peak_mb: float | None = None
    error: str | None = None


def peak_rss_monitor(pid: int, stop: threading.Event, box: list) -> None:
    peak = 0
    while not stop.is_set():
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                                 capture_output=True, text=True, check=True)
            peak = max(peak, int(out.stdout.strip() or 0))
        except Exception:
            break
        time.sleep(0.05)
    box.append(peak / 1024.0)


def audio_duration(path: Path) -> float | None:
    if not path.exists() or path.stat().st_size == 0:
        return None
    if path.suffix == ".wav":
        with wave.open(str(path), "rb") as handle:
            return handle.getnframes() / float(handle.getframerate())
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                              "format=duration", "-of", "csv=p=0", str(path)],
                             capture_output=True, text=True, check=True)
        return float(out.stdout.strip())
    except Exception:
        return None


def pcm_duration_from_bytes(byte_count: int, sample_rate: int) -> float:
    return byte_count / (2.0 * sample_rate)


def run_case(case: BenchCase, text_key: str, text: str, run: int, parallel: int,
             variables: dict, workdir: Path) -> RunResult:
    result = RunResult(case=case.key, text_key=text_key, run=run, parallel=parallel)
    textfile = workdir / f"{case.key}-{text_key}-p{parallel}-{run}.txt"
    outfile = workdir / f"{case.key}-{text_key}-p{parallel}-{run}.wav"
    textfile.write_text(text, encoding="utf-8")

    command = [c.replace("{TEXTFILE}", str(textfile)).replace("{OUTFILE}", str(outfile))
               .replace("{TEXT_INLINE}", text).replace("{OUTDIR}", str(workdir))
               for c in case.command]
    for key, value in variables.items():
        command = [c.replace("{" + key + "}", value) for c in command]

    started = time.monotonic()
    rss_box: list = []
    stop = threading.Event()
    try:
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        monitor = threading.Thread(target=peak_rss_monitor,
                                    args=(proc.pid, stop, rss_box), daemon=True)
        monitor.start()
        if case.produces_wav:
            stderr_bytes = proc.communicate(timeout=3600)[1]
            proc.wait(timeout=60)
        else:
            pcm_bytes = b""
            while True:
                chunk = proc.stdout.read(1 << 16)
                if not chunk:
                    break
                pcm_bytes += chunk
            proc.wait(timeout=60)
            stderr_bytes = proc.stderr.read() or b""
            # s16le mono; Sample-Rate aus dem stderr-Protokoll lesen.
            sample_rate = 24000
            for line in stderr_bytes.decode("utf-8", "replace").splitlines():
                if line.startswith("SAMPLE_RATE "):
                    sample_rate = int(line.split()[1])
            outfile.write_bytes(b"")  # Dauer wird aus den Bytes berechnet
            result.audio_seconds = pcm_duration_from_bytes(len(pcm_bytes), sample_rate)
        stop.set()
        if proc.returncode != 0:
            result.error = f"exit {proc.returncode}: {stderr_bytes.decode('utf-8', 'replace')[:300]}"
            return result
        if result.audio_seconds is None:
            result.audio_seconds = audio_duration(outfile)
        if result.audio_seconds in (None, 0):
            result.error = "keine/leere Ausgabe"
            return result
        result.wall_seconds = time.monotonic() - started
        result.rtf = result.wall_seconds / result.audio_seconds
        result.rss_peak_mb = max(rss_box) if rss_box else None
    except Exception as exc:  # noqa: BLE001
        stop.set()
        result.error = f"{type(exc).__name__}: {exc}"
    finally:
        stop.set()
        textfile.unlink(missing_ok=True)
        outfile.unlink(missing_ok=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="TTS-Benchmark (Plan 8.6)")
    parser.add_argument("--engine", help="Case-Key (siehe --list)")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--parallel", type=int, default=1, choices=[1, 2])
    parser.add_argument("--texts", default="de-medizin,en-medizin,de-kapitel-10k")
    parser.add_argument("--var", action="append", default=[], help="KEY=VALUE für Befehlsplatzhalter")
    parser.add_argument("--out", help="Ergebnis-JSON (Default: stdout)")
    args = parser.parse_args()

    all_cases = {c.key: c for cases in BRIDGES.values() for c in cases}
    if args.list:
        for key, case in all_cases.items():
            print(f"{key:32s} {case.engine:12s} {case.language}  {case.notes}")
        return 0

    keys = list(all_cases) if args.all else ([args.engine] if args.engine else [])
    if not keys:
        parser.error("--engine KEY oder --all angeben (--list zeigt alle)")

    variables = dict(kv.split("=", 1) for kv in args.var if "=" in kv)
    workdir = Path(args.out or ".").parent if args.out else Path(".")
    workdir.mkdir(parents=True, exist_ok=True)

    results: list[RunResult] = []
    for key in keys:
        case = all_cases[key]
        for text_key in args.texts.split(","):
            text = chapter_text_10k() if TEXTS.get(text_key) is None and text_key == "de-kapitel-10k" else TEXTS.get(text_key, "")
            if not text:
                continue
            for parallel in ([1, 2] if args.parallel == 2 else [1]):
                if parallel == 2:
                    # Zwei identische Prozesse gleichzeitig (Skalierungsmessung)
                    threads: list = []
                    boxed: list = []
                    def worker(i):
                        boxed.append(run_case(case, text_key, text, i, parallel, variables, Path(workdir)))
                    for i in range(2):
                        t = threading.Thread(target=worker, args=(i,))
                        threads.append(t)
                    started = time.monotonic()
                    for t in threads: t.start()
                    for t in threads: t.join()
                    wall = time.monotonic() - started
                    for r in boxed:
                        r.wall_seconds = wall / 2  # pro Instanz
                        if r.audio_seconds:
                            r.rtf = r.wall_seconds / r.audio_seconds
                        results.append(r)
                else:
                    for run in range(1, args.runs + 1):
                        results.append(run_case(case, text_key, text, run, parallel, variables, Path(workdir)))

    payload = {
        "machine": subprocess.run(["system_profiler", "SPHardwareDataType"],
                                  capture_output=True, text=True).stdout[:2000],
        "cases": [asdict(r) for r in results],
    }
    rendered = json.dumps(payload, ensure_ascii=False, indent=2)
    if args.out:
        Path(args.out).write_text(rendered, encoding="utf-8")
        print(f"Ergebnisse: {args.out} ({len(results)} Läufe)")
    else:
        print(rendered)

    # Kurzüfassung
    print("\n=== RTF-Übersicht (Median) ===")
    grouped: dict[tuple, list] = {}
    for r in results:
        if r.rtf:
            grouped.setdefault((r.case, r.text_key, r.parallel), []).append(r.rtf)
    for (case, text_key, parallel), values in sorted(grouped.items()):
        print(f"{case:28s} {text_key:16s} p={parallel}  RTF {statistics.median(values):.3f}  RAM max siehe JSON")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
