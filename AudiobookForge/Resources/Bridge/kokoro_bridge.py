#!/usr/bin/env python3
"""
Bridge script invoked by AudiobookForge's KokoroEngine (Swift) as a subprocess.

Reads a full chapter (or chunk) of plain text and synthesizes it with Kokoro
via mlx-audio, streaming raw 16-bit mono PCM (s16le) on stdout so the Swift
side can pipe it straight into ffmpeg — no uncompressed WAV is ever written
to disk. Machine-parsable progress markers go to stderr so stdout stays a
pure binary PCM stream (library print/log noise is redirected to stderr as
well).

Protocol (stderr, one line each, ASCII):
  MODEL_LOADED
  SAMPLE_RATE <sample_rate>
  SEGMENT_DONE <index> <duration_seconds>
  DONE <total_duration_seconds> <segment_count>
  ERROR <message>

Anything else on stderr is diagnostic/log noise from mlx-audio itself and can
be ignored by the caller.
"""

import argparse
import json
import os
import sys

import numpy as np


def derive_lang_code(voice: str) -> str:
    # Kokoro convention: first letter of the voice id is the language/locale
    # bucket (a = American English, b = British English, ...).
    return voice[0] if voice else "a"


def main() -> int:
    # Keep stdout a pure binary PCM stream: save the real fd 1 first, then
    # send every Python-level print()/log (ours and mlx-audio's) to stderr.
    pcm_fd = os.dup(1)
    sys.stdout = sys.stderr
    pcm_out = os.fdopen(pcm_fd, "wb", buffering=0)

    def protocol(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    parser = argparse.ArgumentParser(description="AudiobookForge Kokoro bridge")
    parser.add_argument("--text-file", required=True, help="Path to a UTF-8 text file with the chapter content")
    parser.add_argument("--voice", default="af_heart")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--model", default="mlx-community/Kokoro-82M-bf16")
    parser.add_argument("--lang-code", default=None, help="Overrides the language code derived from the voice")
    parser.add_argument("--segments-json", default=None, help="Optional path to write per-segment timing metadata")
    parser.add_argument("--pauses-json", default=None, help="Optional path to a pause plan: {\"leadInMs\", \"tailMs\", \"pauseAfterMs\": [ms per segment]}")
    args = parser.parse_args()

    pauses = None
    if args.pauses_json:
        try:
            with open(args.pauses_json, "r", encoding="utf-8") as f:
                pauses = json.load(f)
        except Exception as exc:  # noqa: BLE001
            protocol(f"ERROR could not read pauses file: {exc}")
            return 1

    def pause_after(index: int) -> int:
        if pauses is None:
            return 0
        values = pauses.get("pauseAfterMs") or []
        return int(values[index]) if 0 <= index < len(values) else 0

    def lead_in_ms() -> int:
        return int(pauses.get("leadInMs", 0)) if pauses else 0

    def tail_ms() -> int:
        return int(pauses.get("tailMs", 0)) if pauses else 0

    def silence_samples(sample_rate: int, milliseconds: int) -> "np.ndarray":
        return np.zeros(int(sample_rate * milliseconds / 1000), dtype=np.float32)

    try:
        with open(args.text_file, "r", encoding="utf-8") as f:
            text = f.read().strip()
    except OSError as exc:
        protocol(f"ERROR could not read text file: {exc}")
        return 1

    if not text:
        protocol("ERROR chapter text is empty")
        return 1

    try:
        from mlx_audio.tts.utils import load_model
        from mlx_audio.tts.models.kokoro import pipeline as kokoro_pipeline
    except Exception as exc:  # noqa: BLE001
        protocol(f"ERROR failed to import mlx_audio (is the bridge venv set up correctly?): {exc}")
        return 1

    if args.lang_code == "g":
        # mlx-audio 0.5.0 has no German Kokoro language entry. German
        # fine-tuned checkpoints use espeak-ng phonemization for "de".
        kokoro_pipeline.LANG_CODES.setdefault("g", "de")

    try:
        model = load_model(model_path=args.model)
    except Exception as exc:  # noqa: BLE001
        protocol(f"ERROR failed to load model '{args.model}': {exc}")
        return 1

    protocol("MODEL_LOADED")

    # MLX keeps freed GPU buffers in a cache that otherwise grows to many GB
    # over a chapter (measured 2026-10-19: >4 GB after 17 segments, 46 GB swap
    # with two workers on a full book). Cap it and release after each segment.
    try:
        import mlx.core as _mlx

        _mlx.set_cache_limit(int(os.environ.get("ABF_MLX_CACHE_MB", "256")) * 1024 * 1024)
    except Exception:  # noqa: BLE001
        _mlx = None

    lang_code = args.lang_code or derive_lang_code(args.voice)
    if lang_code == "g":
        class GermanG2P:
            def __init__(self, base):
                self.base = base

            def __call__(self, text):
                phonemes, tokens = self.base(text)
                # German fine-tunes were trained with this substitution:
                # short ü (ʏ) is absent from the base Kokoro vocabulary.
                return phonemes.replace("ʏ", "y"), tokens

        german_pipeline = model._get_pipeline("g")
        german_pipeline.g2p = GermanG2P(german_pipeline.g2p)

    # One planned segment per line (the Swift side writes its pause plan
    # line by line). Kokoro splits overlong lines into several chunks on its
    # own, so generate per line and merge those chunks: exactly one segment
    # per line keeps read-along text and the pause plan on the right index.
    lines = [line.strip() for line in text.split("\n") if line.strip()]

    try:
        segments: list[dict] = []
        sample_rate = None
        cumulative_seconds = 0.0
        chunk_count = 0

        lead_written = False
        for i, line in enumerate(lines):
            parts = []
            token_count = 0
            for result in model.generate(
                text=line,
                voice=args.voice,
                speed=args.speed,
                lang_code=lang_code,
                verbose=False,
            ):
                parts.append(np.array(result.audio, dtype=np.float32).reshape(-1))
                token_count += result.token_count or 0
                if sample_rate is None:
                    sample_rate = result.sample_rate
            if not parts or sample_rate is None:
                continue
            audio = np.concatenate(parts)

            if not lead_written:
                protocol(f"SAMPLE_RATE {sample_rate}")
                if lead_in_ms() > 0:
                    pcm_out.write((silence_samples(sample_rate, lead_in_ms()) * 32767.0).astype("<i2").tobytes())
                    cumulative_seconds += lead_in_ms() / 1000.0
                lead_written = True

            duration = len(audio) / float(sample_rate)
            pause_ms = pause_after(i)
            pause_seconds = pause_ms / 1000.0

            segments.append(
                {
                    "index": i,
                    "startSeconds": cumulative_seconds,
                    # Duration includes the planned pause so read-along
                    # stays aligned across the silence.
                    "durationSeconds": duration + pause_seconds,
                    "tokenCount": token_count,
                    "text": line,
                }
            )
            cumulative_seconds += duration + pause_seconds
            chunk_count += 1

            pcm_out.write((np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes())
            if pause_ms > 0:
                pcm_out.write((silence_samples(sample_rate, pause_ms) * 32767.0).astype("<i2").tobytes())
            protocol(f"SEGMENT_DONE {i} {duration + pause_seconds:.3f}")
            if _mlx is not None:
                _mlx.clear_cache()

        if chunk_count == 0 or sample_rate is None:
            protocol("ERROR no audio segments were generated")
            return 1

        if tail_ms() > 0:
            pcm_out.write((silence_samples(sample_rate, tail_ms()) * 32767.0).astype("<i2").tobytes())
            cumulative_seconds += tail_ms() / 1000.0

        if args.segments_json:
            with open(args.segments_json, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "voice": args.voice,
                        "speed": args.speed,
                        "sampleRate": sample_rate,
                        "totalDurationSeconds": cumulative_seconds,
                        "segments": segments,
                    },
                    f,
                )

        protocol(f"DONE {cumulative_seconds:.3f} {chunk_count}")
        return 0
    except Exception as exc:  # noqa: BLE001
        protocol(f"ERROR generation failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
