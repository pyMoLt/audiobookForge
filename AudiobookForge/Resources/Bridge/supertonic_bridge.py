#!/usr/bin/env python3
"""AudiobookForge's line-oriented Supertonic 3 MLX synthesis bridge.

Streams raw 16-bit mono PCM (s16le) on stdout so the Swift side can pipe it
straight into ffmpeg — no uncompressed WAV is ever written to disk.
Progress markers go to stderr so stdout stays a pure binary PCM stream.
"""

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np


def bounded_chunks(text: str, max_chars: int) -> list[str]:
    from supertonic_mlx.tts import chunk_text

    pieces = []
    for chunk in chunk_text(text, max_len=max_chars):
        if len(chunk) <= max_chars:
            pieces.append(chunk)
            continue
        words = chunk.split()
        current = ""
        for word in words:
            if current and len(current) + len(word) + 1 > max_chars:
                pieces.append(current)
                current = ""
            current += (" " if current else "") + word
        if current:
            pieces.append(current)
    return pieces


def trim_silence(samples: np.ndarray, sample_rate: int, threshold_db: float = -45.0, keep_seconds: float = 0.06) -> np.ndarray:
    """Drops leading/trailing near-silence from one synthesized chunk.

    Supertonic pads every chunk with ~0.5 s of silence in front and ~1 s at
    the end; concatenated, that turned each chunk boundary into an audible
    1.2-1.5 s gap mid-paragraph. Trimming to a short margin leaves the
    configured --pause-seconds as the only gap between chunks."""
    if samples.size == 0:
        return samples
    window = max(1, int(sample_rate * 0.02))
    padded = np.pad(np.abs(samples), (0, (-samples.size) % window))
    frames = padded.reshape(-1, window).max(axis=1)
    loud = np.nonzero(frames > 10 ** (threshold_db / 20))[0]
    if loud.size == 0:
        return samples
    keep = int(sample_rate * keep_seconds)
    start = max(0, loud[0] * window - keep)
    end = min(samples.size, (loud[-1] + 1) * window + keep)
    return samples[start:end]


def main() -> int:
    # Keep stdout a pure binary PCM stream: save the real fd 1 first, then
    # send every Python-level print()/log (ours and supertonic's) to stderr.
    pcm_fd = os.dup(1)
    sys.stdout = sys.stderr
    pcm_out = os.fdopen(pcm_fd, "wb", buffering=0)

    def protocol(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    parser = argparse.ArgumentParser()
    parser.add_argument("--text-file", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--voice", default="M1")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--steps", type=int, default=8)
    parser.add_argument("--chunk-characters", type=int, default=250)
    parser.add_argument("--pause-seconds", type=float, default=0.25)
    parser.add_argument("--segments-json", type=Path)
    args = parser.parse_args()

    sys.path.insert(0, str(args.runtime))
    from supertonic_mlx import SupertonicMLX

    text = args.text_file.read_text(encoding="utf-8").strip()
    if not text:
        protocol("ERROR Kein Text zum Vorlesen vorhanden")
        return 1
    if not 1 <= args.steps <= 20 or not 40 <= args.chunk_characters <= 300 or not 0 <= args.pause_seconds <= 2:
        protocol("ERROR Ungültige Supertonic-Einstellungen")
        return 1

    tts = SupertonicMLX.from_pretrained(args.model)
    style = tts.get_voice_style(args.voice)
    protocol("MODEL_LOADED")
    protocol(f"SAMPLE_RATE {tts.sample_rate}")
    chunks = bounded_chunks(text, args.chunk_characters)
    protocol(f"SEGMENTS_TOTAL {len(chunks)}")
    segments = []
    cumulative = 0.0
    for index, chunk in enumerate(chunks):
        wav, duration = tts.synthesize(chunk, "de", style, total_step=args.steps, speed=args.speed, silence_duration=0)
        samples = np.asarray(wav[0, : int(tts.sample_rate * float(duration[0]))], dtype=np.float32)
        samples = trim_silence(samples, tts.sample_rate)
        pcm_out.write((np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2").tobytes())
        seconds = len(samples) / tts.sample_rate
        segments.append({"index": index, "startSeconds": cumulative, "durationSeconds": seconds, "text": chunk})
        cumulative += seconds
        protocol(f"SEGMENT_DONE {index} {seconds:.3f}")
        if index + 1 < len(chunks) and args.pause_seconds > 0:
            silence = np.zeros(int(tts.sample_rate * args.pause_seconds), dtype=np.float32)
            pcm_out.write((silence * 32767.0).astype("<i2").tobytes())
            cumulative += len(silence) / tts.sample_rate

    if args.segments_json:
        args.segments_json.write_text(json.dumps({"segments": segments}, ensure_ascii=False), encoding="utf-8")
    protocol(f"DONE {cumulative:.3f} {len(chunks)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR {error}", file=sys.stderr, flush=True)
        raise
