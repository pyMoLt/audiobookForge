#!/usr/bin/env python3
"""
Bridge script invoked by AudiobookForge's OmniVoiceEngine (Swift) as a subprocess.

Reads a chapter of plain text (one sentence per line, prepared by the engine's
pause planner) and synthesizes it with OmniVoice (k2-fsa, MLX weights from
mlx-community/OmniVoice-bfloat16) via mlx-audio, streaming raw 16-bit mono PCM
(s16le) on stdout so the Swift side can pipe it straight into ffmpeg — no
uncompressed audio is ever written to disk. Progress markers go to stderr
(same protocol as kokoro_bridge.py, plus the plan-8.4 pause plan via
--pauses-json).

OmniVoice is a non-autoregressive masked-diffusion model: generation needs a
maximum duration per segment (--duration-scale chars/sec + safety margin);
trailing near-silence the model pads to the requested duration is trimmed so
chapter boundaries stay tight.

Protocol (stderr, one line each, ASCII):
  MODEL_LOADED
  SAMPLE_RATE <sample_rate>
  SEGMENT_DONE <index> <duration_seconds>   (duration includes the pause)
  DONE <total_duration_seconds> <segment_count>
  ERROR <message>
"""

import argparse
import json
import os
import sys

import numpy as np


def trim_trailing_silence(samples: np.ndarray, sample_rate: int, threshold_db: float = -45.0, keep_seconds: float = 0.06) -> np.ndarray:
    """Drops trailing near-silence OmniVoice pads to the requested duration."""
    if samples.size == 0:
        return samples
    window = max(1, int(sample_rate * 0.02))
    padded = np.pad(np.abs(samples), (0, (-samples.size) % window))
    frames = padded.reshape(-1, window).max(axis=1)
    loud = np.nonzero(frames > 10 ** (threshold_db / 20))[0]
    if loud.size == 0:
        return samples
    keep = int(sample_rate * keep_seconds)
    end = min(samples.size, (loud[-1] + 1) * window + keep)
    return samples[:end]


def main() -> int:
    # Keep stdout a pure binary PCM stream: save the real fd 1 first, then
    # send every Python-level print()/log (ours and mlx-audio's) to stderr.
    pcm_fd = os.dup(1)
    sys.stdout = sys.stderr
    pcm_out = os.fdopen(pcm_fd, "wb", buffering=0)

    def protocol(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    parser = argparse.ArgumentParser(description="AudiobookForge OmniVoice bridge")
    parser.add_argument("--text-file", required=True, help="Path to a UTF-8 text file, one sentence per line")
    parser.add_argument("--model", required=True, help="Path to the OmniVoice MLX model directory")
    parser.add_argument("--language", default="de", help="BCP-47 language tag (de, en, ...)")
    parser.add_argument("--duration-scale", type=float, default=13.0, help="Chars per second used to estimate each segment's maximum duration")
    parser.add_argument("--duration-margin", type=float, default=1.35, help="Safety factor on the duration estimate")
    parser.add_argument("--min-duration", type=float, default=1.2, help="Minimum requested duration per segment")
    parser.add_argument("--max-duration", type=float, default=30.0, help="Maximum requested duration per segment")
    parser.add_argument("--num-steps", type=int, default=32, help="Iterative unmasking steps (4-64)")
    parser.add_argument("--ref-audio", default=None, help="Optional reference audio file for voice cloning (any sample rate, clipped to 10s)")
    parser.add_argument("--ref-text", default=None, help="Transcript of the reference audio (recommended for a good speaker match)")
    parser.add_argument("--speed", type=float, default=1.0, help="Accepted for interface parity; NOT supported by OmniVoice")
    parser.add_argument("--segments-json", default=None, help="Optional path to write per-segment timing metadata")
    parser.add_argument("--pauses-json", default=None, help="Optional pause plan: {\"leadInMs\", \"tailMs\", \"pauseAfterMs\": [...]}")
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

    try:
        with open(args.text_file, "r", encoding="utf-8") as f:
            sentences = [line.strip() for line in f.read().split("\n") if line.strip()]
    except OSError as exc:
        protocol(f"ERROR could not read text file: {exc}")
        return 1

    if not sentences:
        protocol("ERROR chapter text is empty")
        return 1

    try:
        import mlx.core as mx
        from transformers import AutoTokenizer
        from mlx_audio.codec.models.higgs_audio.higgs_audio import HiggsAudioTokenizer
        from mlx_audio.tts.models.omnivoice.omnivoice import Model, OmniVoiceConfig
    except Exception as exc:  # noqa: BLE001
        protocol(f"ERROR failed to import mlx_audio (is the bridge venv set up correctly?): {exc}")
        return 1

    model_path = args.model
    try:
        with open(f"{model_path}/config.json") as f:
            config = OmniVoiceConfig.from_dict(json.load(f))
        model = Model(config)
        weights = model.sanitize(dict(mx.load(f"{model_path}/model.safetensors")))
        model.load_weights(list(weights.items()))
        mx.eval(model.parameters())
        audio_tokenizer = HiggsAudioTokenizer.from_pretrained(model_path)
        text_tokenizer = AutoTokenizer.from_pretrained(model_path)
    except Exception as exc:  # noqa: BLE001
        protocol(f"ERROR failed to load model '{model_path}': {exc}")
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

    segments: list[dict] = []
    sample_rate = None
    cumulative_seconds = 0.0
    chunk_count = 0
    lead_written = False

    try:
        for index, sentence in enumerate(sentences):
            estimate = max(args.min_duration, min(args.max_duration, len(sentence) / max(1.0, args.duration_scale) * args.duration_margin))
            results = list(model.generate(
                text=sentence,
                language=args.language,
                duration_s=estimate,
                num_steps=args.num_steps,
                ref_audio=args.ref_audio,
                ref_text=args.ref_text if args.ref_text else None,
                tokenizer=audio_tokenizer,
                text_tokenizer=text_tokenizer,
            ))
            if not results:
                protocol(f"ERROR no audio for segment {index}")
                return 1
            audio = np.array(results[0].audio, dtype=np.float32)
            audio = trim_trailing_silence(audio, results[0].sample_rate)
            if sample_rate is None:
                sample_rate = results[0].sample_rate
                protocol(f"SAMPLE_RATE {sample_rate}")
                if not lead_written and lead_in_ms() > 0:
                    silence = np.zeros(int(sample_rate * lead_in_ms() / 1000), dtype=np.float32)
                    pcm_out.write((silence * 32767.0).astype("<i2").tobytes())
                    cumulative_seconds += lead_in_ms() / 1000.0
                    lead_written = True

            duration = len(audio) / float(sample_rate)
            pause_ms = pause_after(index)
            pause_seconds = pause_ms / 1000.0

            segments.append(
                {
                    "index": index,
                    "text": sentence,
                    "startSeconds": cumulative_seconds,
                    "durationSeconds": duration + pause_seconds,
                }
            )
            cumulative_seconds += duration + pause_seconds
            chunk_count += 1

            pcm_out.write((np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes())
            if pause_ms > 0:
                silence = np.zeros(int(sample_rate * pause_ms / 1000), dtype=np.float32)
                pcm_out.write((silence * 32767.0).astype("<i2").tobytes())
            protocol(f"SEGMENT_DONE {index} {duration + pause_seconds:.3f}")
            if _mlx is not None:
                _mlx.clear_cache()

        if chunk_count == 0 or sample_rate is None:
            protocol("ERROR no audio segments were generated")
            return 1

        if tail_ms() > 0:
            silence = np.zeros(int(sample_rate * tail_ms() / 1000), dtype=np.float32)
            pcm_out.write((silence * 32767.0).astype("<i2").tobytes())
            cumulative_seconds += tail_ms() / 1000.0

        if args.segments_json:
            with open(args.segments_json, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "voice": "default",
                        "language": args.language,
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
