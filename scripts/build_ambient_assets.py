#!/usr/bin/env python3
"""Build the ambient sound assets (v3.1) from CC0 field recordings.

For every scene the app plays
  * a seamless bed loop  -> Resources/Ambient/<scene>.m4a       (75-100 s, stereo)
  * 4-8 one-shot events  -> Resources/Ambient/<scene>_evt_<n>.m4a (crackles, thunder ...)

Sources are Freesound sounds licensed CC0 1.0 (public domain). The script
downloads the public HQ previews, VERIFIES the CC0 license on each sound page
before using it, and writes docs/AMBIENT_LIZENZEN.md.

Usage:  python3 -I scripts/build_ambient_assets.py <download-cache-dir>
Needs:  numpy, ffmpeg, curl
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "AudiobookForge", "Resources", "Ambient")
DOC = os.path.join(ROOT, "THIRD_PARTY.md")
SR = 44100
TMP_DIR = "/tmp"  # replaced in main() by the download cache

# scene -> bed sources (first usable wins), event sources and event style.
SCENES = {
    "fire": {
        "bed": ["visionear/sounds/501417", "BonnyOrbit/sounds/484338", "nielstii/sounds/346321"],
        "events": ["nielstii/sounds/346321", "NomadApe/sounds/444920", "florianreichelt/sounds/563766", "samarobryn/sounds/414767"],
        "event": {"kind": "transient", "length": (0.35, 1.4), "count": 8},
    },
    "rain": {
        "bed": ["YostPeter/sounds/523405", "Garuda1982/sounds/852917", "LilMati/sounds/515942"],
        "events": ["Erbsland-Music/sounds/428605", "florianreichelt/sounds/683102", "bolkmar/sounds/451126"],
        "event": {"kind": "transient", "length": (0.3, 1.2), "count": 6},
    },
    "storm": {
        "bed": ["jodybruchon/sounds/459465", "Ryding/sounds/125963", "crazyadamos/sounds/427550", "MrPokephile/sounds/154732"],
        "events": ["Nimlos/sounds/359151", "SpeedY/sounds/17059", "AyaDrevis/sounds/652690", "Emulius/sounds/744723", "BlondPanda/sounds/778374"],
        "event": {"kind": "whole", "length": (5.0, 14.0), "count": 5},
    },
    "ocean": {
        "bed": ["Ninochka/sounds/440712", "Profispiesser/sounds/583062", "L.Finck/sounds/636551", "TRP/sounds/573179"],
        "events": ["L.Finck/sounds/636552", "Sacha.Julien/sounds/724583"],
        "event": {"kind": "swell", "length": (4.0, 7.0), "count": 4},
    },
    "water": {
        "bed": ["Sclolex/sounds/324208", "Fenodyrie/sounds/615250", "RyanKingArt/sounds/529214", "TRP/sounds/567730"],
        "events": ["florianreichelt/sounds/683102", "bolkmar/sounds/451126", "beskhu/sounds/273870", "casstway/sounds/519991"],
        "event": {"kind": "transient", "length": (0.25, 0.9), "count": 6},
    },
    "forest": {
        "bed": ["felix.blume/sounds/868746", "aurelien.leveque/sounds/417532", "anne82/sounds/276067", "hopflog/sounds/752783"],
        "events": ["SarahAGGross/sounds/737476", "SarahAGGross/sounds/737477", "SarahAGGross/sounds/737478"],
        "event": {"kind": "swell", "length": (1.5, 3.5), "count": 6},
    },
    "cyberpunk": {
        "bed": ["puppetmaster685719/sounds/641211", "RaucousRaptor/sounds/563887", "felix.blume/sounds/705049"],
        "events": ["felix.blume/sounds/705049", "RaucousRaptor/sounds/563887"],
        "event": {"kind": "swell", "length": (2.0, 6.0), "count": 5},
    },
    "train": {
        "bed": ["bisanu6/sounds/143205", "Yoyodaman234/sounds/341208", "AListair_Hamilton_241200/sounds/767178", "KentVideoProduction/sounds/533718"],
        "events": ["kangaroovindaloo/sounds/442211", "Rok_e/sounds/720609", "mlekoman/sounds/199536", "tom_woysky/sounds/316616", "Juandamb/sounds/430629"],
        "event": {"kind": "transient", "length": (0.4, 1.6), "count": 5},
        # No CC0 rail-joint recording found (all CC-BY): synthesise them.
        "synth": "rail_joints",
    },
}


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def fetch_page(path):
    req = urllib.request.Request("https://freesound.org/people/%s/" % path, headers={"User-Agent": "Mozilla/5.0"})
    return urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")


def source_info(path, cache):
    """Returns (preview_url, title, author) if the sound is CC0, else None."""
    meta_file = os.path.join(cache, path.replace("/", "_") + ".json")
    if os.path.exists(meta_file):
        return json.load(open(meta_file))
    html = fetch_page(path)
    if "creativecommons.org/publicdomain/zero/1.0" not in html:
        return None
    preview = re.search(r"https://cdn\.freesound\.org/previews/[^\"]+-hq\.mp3", html)
    title = re.search(r'<meta property="og:title" content="([^"]+)"', html)
    if not preview:
        return None
    info = {"preview": preview.group(0), "title": title.group(1) if title else path,
            "author": path.split("/")[0], "url": "https://freesound.org/people/%s/" % path}
    json.dump(info, open(meta_file, "w"))
    return info


def load(path, cache):
    info = source_info(path, cache)
    if not info:
        print("  skip (not CC0 / no preview):", path)
        return None, None
    mp3 = os.path.join(cache, path.replace("/", "_") + ".mp3")
    if not os.path.exists(mp3):
        req = urllib.request.Request(info["preview"], headers={"User-Agent": "Mozilla/5.0"})
        open(mp3, "wb").write(urllib.request.urlopen(req, timeout=60).read())
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", mp3, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         check=True, stdout=subprocess.PIPE).stdout
    audio = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()
    return audio, info


def rms_windows(mono, win):
    n = len(mono) // win
    return np.sqrt(np.mean(mono[: n * win].reshape(n, win) ** 2, axis=1) + 1e-12)


def steady_segment(audio, seconds):
    """The window of `seconds` with the most even loudness (no voices,
    bumps or handling noise) — a good bed."""
    win = SR // 2
    levels = 20 * np.log10(rms_windows(audio.mean(axis=1), win))
    span = int(seconds * 2)
    if len(levels) <= span:
        return audio
    best, best_score = 0, 1e9
    for start in range(0, len(levels) - span, 2):
        part = levels[start:start + span]
        score = part.std() + 0.3 * max(0, part.max() - np.median(part) - 6)
        if score < best_score:
            best, best_score = start, score
    return audio[best * win: best * win + int(seconds * SR)]


def seamless(audio, fade_seconds=3.0):
    """Equal-power crossfade of the tail into the head → loops without a seam."""
    f = int(fade_seconds * SR)
    t = np.linspace(0, np.pi / 2, f)[:, None]
    head, tail = audio[:f], audio[-f:]
    mixed = tail * np.cos(t) + head * np.sin(t)
    return np.concatenate([mixed, audio[f:-f]])


def normalize(audio, target_db):
    rms = np.sqrt(np.mean(audio ** 2) + 1e-12)
    gain = 10 ** (target_db / 20) / rms
    out = audio * gain
    peak = np.abs(out).max()
    if peak > 0.95:
        out *= 0.95 / peak
    return out


def fade(audio, fin=0.01, fout=0.08):
    a = audio.copy()
    i, o = int(fin * SR), int(fout * SR)
    if i: a[:i] *= np.linspace(0, 1, i)[:, None]
    if o: a[-o:] *= np.linspace(1, 0, o)[:, None] ** 2
    return a


def write_m4a(audio, path, bitrate):
    pcm = os.path.join(TMP_DIR, "encode.f32")
    audio.astype(np.float32).tofile(pcm)
    run(["ffmpeg", "-y", "-v", "quiet", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-i", pcm,
         "-c:a", "aac", "-b:a", bitrate, "-movflags", "+faststart", path])
    os.remove(pcm)


def extract_events(audio, style):
    lo, hi = style["length"]
    mono = audio.mean(axis=1)
    if style["kind"] == "whole":
        # Thunder etc.: the loudest stretch of the file.
        win = SR // 4
        levels = rms_windows(mono, win)
        peak = int(levels.argmax())
        start = max(0, peak * win - int(0.6 * SR))
        length = int(min(hi, max(lo, len(mono) / SR - start / SR)) * SR)
        return [fade(audio[start:start + length], 0.05, min(2.5, length / SR * 0.35))]
    win = int(0.02 * SR) if style["kind"] == "transient" else SR // 4
    levels = rms_windows(mono, win)
    background = np.median(levels)
    order = np.argsort(levels)[::-1]
    picks, used = [], []
    for idx in order:
        if levels[idx] < background * (3.0 if style["kind"] == "transient" else 1.4):
            break
        center = idx * win
        if any(abs(center - u) < hi * SR for u in used):
            continue
        used.append(center)
        length = int(np.random.default_rng(int(idx)).uniform(lo, hi) * SR)
        start = max(0, center - int(0.03 * SR if style["kind"] == "transient" else length * 0.35))
        clip = audio[start:start + length]
        if len(clip) > SR * lo * 0.8:
            picks.append(fade(clip, 0.004 if style["kind"] == "transient" else 0.3, 0.06 if style["kind"] == "transient" else 0.8))
        if len(picks) >= 12:
            break
    return picks


BED_LUFS = -26.0
EVENT_LUFS = -24.0


def loudness_normalize(path, target_lufs):
    """Two-pass EBU R128 loudnorm (linear gain, true-peak limited), so every
    scene sounds equally loud at the same volume setting. RMS + peak scaling
    left sharp-peaked beds (crackling fire) 24 dB quieter than steady ones."""
    probe = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af",
                            "loudnorm=I=%.1f:TP=-2:LRA=20:print_format=json" % target_lufs, "-f", "null", "-"],
                           capture_output=True, text=True).stderr
    stats = json.loads(probe[probe.rindex("{"):probe.rindex("}") + 1])
    if "inf" in (stats["input_i"] + stats["target_offset"]):
        # Too short/quiet for an integrated measurement (a single drop):
        # keep the RMS-based level from normalize().
        return
    tmp = path + ".norm.m4a"
    filt = ("loudnorm=I=%.1f:TP=-2:LRA=20:measured_I=%s:measured_TP=%s:measured_LRA=%s:measured_thresh=%s:offset=%s:linear=true"
            % (target_lufs, stats["input_i"], stats["input_tp"], stats["input_lra"], stats["input_thresh"], stats["target_offset"]))
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", path, "-af", filt + ",aresample=44100",
         "-c:a", "aac", "-b:a", "160k", tmp])
    os.replace(tmp, path)


def synth_rail_joints(seed):
    """Bogies over a rail joint: two "clack-clack" pairs (front and rear
    bogie of a carriage). Synthesised — no recording under CC0 exists for
    this, so the sound is our own: a low wheel thump plus a short metallic
    click per wheel, slightly varied per event."""
    rng = np.random.default_rng(seed)
    gap_axles = rng.uniform(0.11, 0.15)      # two axles of one bogie
    gap_bogies = rng.uniform(0.75, 1.05)     # front -> rear bogie
    length = gap_bogies + gap_axles + 0.5
    out = np.zeros((int(length * SR), 2))
    t = np.arange(int(0.25 * SR)) / SR
    for start in (0.05, 0.05 + gap_axles, 0.05 + gap_bogies, 0.05 + gap_bogies + gap_axles):
        freq = rng.uniform(55, 80)
        thump = np.sin(2 * np.pi * freq * t) * np.exp(-t * rng.uniform(22, 32))
        noise = rng.standard_normal(len(t))
        click = np.convolve(noise, np.ones(4) / 4, mode="same") * np.exp(-t * 140) * 0.35
        hit = (thump + click) * rng.uniform(0.75, 1.0)
        i = int(start * SR)
        pan = rng.uniform(-0.15, 0.15)
        out[i:i + len(hit), 0] += hit * (1 - pan)
        out[i:i + len(hit), 1] += hit * (1 + pan)
    return out


def main():
    global TMP_DIR
    cache = os.path.abspath(sys.argv[1])
    TMP_DIR = cache
    os.makedirs(cache, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    credits = []
    for scene, spec in SCENES.items():
        print("scene", scene)
        bed = None
        for path in spec["bed"]:
            audio, info = load(path, cache)
            if audio is None or len(audio) < 70 * SR:
                continue
            length = min(95, len(audio) / SR - 2)
            bed = seamless(steady_segment(audio, length + 3))
            credits.append((scene, "Grundteppich", info))
            break
        if bed is None:
            print("  NO BED for", scene)
            continue
        write_m4a(normalize(bed, -24), os.path.join(OUT, scene + ".m4a"), "160k")
        loudness_normalize(os.path.join(OUT, scene + ".m4a"), BED_LUFS)

        for old in os.listdir(OUT):
            if old.startswith(scene + "_evt_"):
                os.remove(os.path.join(OUT, old))
        events = []
        for path in spec["events"]:
            audio, info = load(path, cache)
            if audio is None:
                continue
            found = extract_events(audio, spec["event"])
            if found:
                credits.append((scene, "Einzelereignisse", info))
                events.extend(found[: max(2, spec["event"]["count"] // len(spec["events"]) + 1)])
        if not events and spec.get("synth") == "rail_joints":
            events = [synth_rail_joints(n) for n in range(spec["event"]["count"])]
            credits.append((scene, "Einzelereignisse", {"title": "Schienenstöße (synthetisch, scripts/build_ambient_assets.py)",
                                                         "url": "../scripts/build_ambient_assets.py", "author": "AudiobookForge (eigene Synthese)"}))
        events = events[: spec["event"]["count"]]
        for n, clip in enumerate(events, 1):
            write_m4a(normalize(clip, -20), os.path.join(OUT, "%s_evt_%d.m4a" % (scene, n)), "128k")
            loudness_normalize(os.path.join(OUT, "%s_evt_%d.m4a" % (scene, n)), EVENT_LUFS)
        print("  bed %.0fs, %d events" % (len(bed) / SR, len(events)))

    with open(DOC, "w") as f:
        f.write("# Ambient-Lizenzen (v3.1)\n\nStand: erzeugt von `scripts/build_ambient_assets.py`.\n\n")
        f.write("Alle Klänge stammen aus Feldaufnahmen auf Freesound unter **CC0 1.0 (Public Domain)** — ")
        f.write("das Skript prüft die Lizenz auf jeder Soundseite, bevor es eine Aufnahme verwendet. ")
        f.write("Namensnennung ist nicht erforderlich, erfolgt hier aber als Dank.\n\n")
        f.write("| Szene | Verwendung | Aufnahme | Urheber:in | Lizenz |\n|---|---|---|---|---|\n")
        for scene, use, info in credits:
            f.write("| %s | %s | [%s](%s) | %s | CC0 1.0 |\n" % (scene, use, info["title"].replace("|", "/"), info["url"], info["author"]))
        f.write("\nVerarbeitung: ruhigstes Fenster als Grundteppich gewählt, Naht per 3-s-Equal-Power-Kreuzblende, ")
        f.write("Lautheit nach EBU R128 angeglichen (Grundteppich %.0f LUFS, Ereignisse %.0f LUFS),"  % (BED_LUFS, EVENT_LUFS))
        f.write(" Lautheit angeglichen, AAC 160 kbit/s Stereo; Einzelereignisse aus den lautesten Stellen geschnitten ")
        f.write("und in der App zufällig verteilt (Stereo-Panorama, Tonhöhe, Lautstärke).\n")


if __name__ == "__main__":
    main()
