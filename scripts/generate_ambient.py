#!/usr/bin/env python3
"""
generate_ambient.py — erzeugt die Ambient-Loops für den App-Player (Plan 9.6).

Alles wird SELBST prozedural synthetisiert (gefilterte Rauschprozesse) —
keine fremden Aufnahmen, damit ist die Lizenzlage eindeutig (dokumentiert in
docs/AMBIENT_LIZENZEN.md). Ausgabe: 90-Sekunden-Loops als AAC (.m4a, Mono,
64 kbit/s, <= 2,5 MB) in AudiobookForge/Resources/Ambient/.

  fire  — Kaminfeuer: braunes Rauschen + zufällige Knack-Impulse
  rain  — Regen: bandpass-gefiltertes Rosa-Rauschen + einzelne Tropfen
  water — Wasser/Wellen: langsam moduliertes Tiefpass-Rauschen

"Streicher" entfällt (Plan 9.6: falls keine geeigneten Aufnahmen mit klarer
Lizenz existieren — prozedurale Streicher klingen nicht natürlich) und ist
dokumentiert.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np

SAMPLE_RATE = 24000
SECONDS = 90
OUT = Path(__file__).resolve().parents[1] / "AudiobookForge/AudiobookForge/Resources/Ambient"


def rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def lowpass(data: np.ndarray, alpha: float) -> np.ndarray:
    out = np.empty_like(data)
    acc = 0.0
    for i, x in enumerate(data):
        acc += alpha * (x - acc)
        out[i] = acc
    return out


def make_fire() -> np.ndarray:
    r = rng(7)
    n = SAMPLE_RATE * SECONDS
    # Braunes Rauschen (integriertes weißes Rauschen) als Grundlüstern
    brown = np.cumsum(r.normal(0, 1, n))
    brown /= np.abs(brown).max()
    base = lowpass(brown, 0.02) * 1.4
    # Knack-Impulse: kurze, exponentiell abklingende Bursts
    crackle = np.zeros(n)
    for _ in range(int(SECONDS * 6.5)):
        pos = r.integers(0, n - 800)
        length = r.integers(120, 700)
        burst = r.normal(0, 1, length) * np.exp(-np.linspace(0, 7, length))
        crackle[pos:pos + length] += burst * r.uniform(0.3, 1.0)
    crackle = lowpass(crackle, 0.25)
    mix = base * 0.55 + crackle * 0.9
    # Sanftes globales Atmen (Feuer ebbt an)
    t = np.linspace(0, 2 * np.pi, n)
    mix *= 1 + 0.12 * np.sin(t * 0.9 + 0.3)
    # Naht glätten: Ende an Anfang anpassen (Kreuzblende über 1 s)
    return crossfade_loop(mix)


def make_rain() -> np.ndarray:
    r = rng(13)
    n = SAMPLE_RATE * SECONDS
    # Rosa Rauschen (Regen-Grundrauschen)
    white = r.normal(0, 1, n)
    pink = np.empty_like(white)
    acc = 0.0
    for i, x in enumerate(white):
        acc = 0.985 * acc + x
        pink[i] = acc
    pink /= np.abs(pink).max()
    # Bandpass-artige Nachbearbeitung (Hochpass-Anteil zurückmischen)
    body = lowpass(pink, 0.12)
    hiss = pink - body
    mix = body * 1.2 + hiss * 0.35
    # Einzelne Tropfen (kurze Sinus-Blips)
    for _ in range(int(SECONDS * 14)):
        pos = r.integers(0, n - 2000)
        length = r.integers(300, 1400)
        freq = r.uniform(900, 2600)
        t = np.linspace(0, length / SAMPLE_RATE, length)
        blip = np.sin(2 * np.pi * freq * t) * np.exp(-np.linspace(0, 9, length)) * r.uniform(0.05, 0.16)
        mix[pos:pos + length] += blip
    # Leichte Intensitätsschwankung (Windböen)
    t = np.linspace(0, 2 * np.pi, n)
    mix *= 1 + 0.15 * np.sin(t * 0.4 + 1.1) + 0.06 * np.sin(t * 1.7)
    return crossfade_loop(mix)


def make_water() -> np.ndarray:
    r = rng(29)
    n = SAMPLE_RATE * SECONDS
    white = r.normal(0, 1, n)
    smooth = lowpass(white, 0.035)
    smooth /= np.abs(smooth).max()
    # Wellen: zwei sehr langsame Modulationen unterschiedlicher Phase
    t = np.linspace(0, 2 * np.pi, n)
    wave = 0.6 + 0.4 * np.sin(t * 0.55) * np.sin(t * 0.23 + 1.3)
    mix = smooth * wave
    # Schaum-Anteil (hell) zurückmischen
    foam = lowpass(white, 0.3) * 0.22 * (wave ** 2)
    mix = mix * 0.9 + foam
    mix /= np.abs(mix).max() * 1.1
    return crossfade_loop(mix)


def crossfade_loop(data: np.ndarray, fade_seconds: float = 1.0) -> np.ndarray:
    """Blendet das Ende in den Anfang ein, damit der Loop nahtlos ist."""
    n = int(SAMPLE_RATE * fade_seconds)
    fade_in = np.linspace(0, 1, n)
    data[:n] = data[:n] * fade_in + data[-n:] * (1 - fade_in)
    # Und den globalen Pegel auf angenehme Lautstärke normalisieren
    peak = np.percentile(np.abs(data), 99.5)
    return (data / peak * 0.7).astype(np.float32)


def write_wav(path: Path, data: np.ndarray) -> None:
    import wave
    pcm = (np.clip(data, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm.tobytes())


def encode_m4a(wav: Path, m4a: Path) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-i", str(wav), "-c:a", "aac", "-b:a", "64k", "-ac", "1", str(m4a)],
        check=True,
    )


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    loops = {
        "fire": make_fire,
        "rain": make_rain,
        "water": make_water,
    }
    for name, factory in loops.items():
        wav = OUT / f"{name}-tmp.wav"
        m4a = OUT / f"{name}.m4a"
        print(f"generiere {name} …", flush=True)
        write_wav(wav, factory())
        encode_m4a(wav, m4a)
        wav.unlink()
        size = m4a.stat().st_size
        print(f"  -> {m4a.name}: {size / 1024:.0f} KB", flush=True)
        if size > 2_500_000:
            print(f"  !! zu groß (> 2,5 MB)", file=sys.stderr)
            return 1
    print("Alle Ambient-Loops erzeugt.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
