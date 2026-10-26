#!/usr/bin/env python3
"""AudiobookForge's Phonon (Gradium) synthesis bridge (v4).

Reads a speech plan (planned segments + pauses, computed by the app's
PausePlanner) and speaks it segment by segment with the `ptts` runtime
(Rust core, CPU, q8 weights, one thread — the app runs several of these
processes in parallel, which measured fastest on Apple silicon).

Streams raw 16-bit mono PCM (s16le) on stdout so the Swift side can pipe it
straight into ffmpeg; progress markers go to stderr. Every planned segment
becomes exactly one timed segment with its text (read-along).
"""

import argparse
import json
import os
import sys

import numpy as np


def steps_model(model: str, steps: int) -> str:
    """The runtime reads the refinement steps (lsd_decode_steps) only from
    config.json. For another value, build a temporary model folder: links
    to every file, plus a changed config. Removed when the bridge exits."""
    config_path = os.path.join(model, "config.json")
    if steps <= 0 or not os.path.isfile(config_path):
        return model
    config = json.load(open(config_path, encoding="utf-8"))
    if config.get("lsd_decode_steps") == steps:
        return model
    import atexit
    import shutil
    import tempfile

    folder = tempfile.mkdtemp(prefix="phonon-steps-")
    atexit.register(shutil.rmtree, folder, True)
    for name in os.listdir(model):
        if name != "config.json":
            os.symlink(os.path.join(os.path.abspath(model), name), os.path.join(folder, name))
    config["lsd_decode_steps"] = steps
    with open(os.path.join(folder, "config.json"), "w", encoding="utf-8") as handle:
        json.dump(config, handle)
    return folder


def main() -> int:
    # Keep stdout a pure binary PCM stream: save the real fd 1 first, then
    # send every Python-level print() to stderr.
    pcm_out = os.fdopen(os.dup(1), "wb", buffering=0)
    sys.stdout = sys.stderr

    def log(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True, help="JSON: segments, pauses_ms, lead_in_ms, tail_ms")
    parser.add_argument("--model", required=True, help="model folder (config.json, tokenizer.json, weights, voices/)")
    parser.add_argument("--voice", default="", help="voice name in the model folder, or a .safetensors path")
    parser.add_argument("--lang", default="de")
    parser.add_argument("--quant", default="q8")
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--duration-delta", type=float, default=0.0, help="<0 faster, >0 slower")
    parser.add_argument("--temperature", type=float, default=0.3, help="sampling temperature (expression)")
    parser.add_argument("--segments-json", required=True)
    parser.add_argument("--lsd-steps", type=int, default=0, help="refinement steps; 0 = the model's config")
    args = parser.parse_args()

    try:
        import ptts

        if args.threads > 0:
            ptts.set_num_threads(args.threads)
        plan = json.load(open(args.plan, encoding="utf-8"))
        segments = plan["segments"]
        pauses = plan.get("pauses_ms", [])

        kwargs = {"lang": args.lang, "device": "cpu", "temperature": args.temperature}
        if args.quant and args.quant != "f32":
            kwargs["quant"] = args.quant
        if abs(args.duration_delta) > 1e-6:
            kwargs["conditions"] = {"duration_delta": args.duration_delta}
        tts = ptts.TTS(steps_model(args.model, args.lsd_steps), **kwargs)
        voice = None
        if args.voice:
            if args.voice.endswith(".safetensors"):
                name = os.path.splitext(os.path.basename(args.voice))[0]
                tts.add_voice(name, args.voice)
                voice = name
            else:
                # Voice files of accented names ("Noémie") are stored in
                # whatever Unicode form the file system chose: match by
                # NFC + casefold instead of the exact bytes.
                import unicodedata

                def norm(text: str) -> str:
                    return unicodedata.normalize("NFC", text).casefold()

                known = {norm(name): name for name in tts.voices}
                voice = known.get(norm(args.voice), args.voice)
        rate = int(tts.sample_rate)
        log("MODEL_LOADED")
        log(f"SAMPLE_RATE {rate}")
        log(f"SEGMENTS_TOTAL {len(segments)}")

        def silence(ms: int) -> bytes:
            return b"\x00\x00" * int(rate * ms / 1000)

        cursor = 0.0
        timed = []
        lead_in = int(plan.get("lead_in_ms", 0))
        if lead_in > 0:
            pcm_out.write(silence(lead_in))
            cursor += lead_in / 1000
        for index, text in enumerate(segments):
            kw = {}
            if voice:
                kw["voice"] = voice
            audio = tts.synth(text, **kw) if text.strip() else np.zeros(0, dtype=np.float32)
            pcm = (np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
            pcm_out.write(pcm)
            duration = len(audio) / rate
            pause = int(pauses[index]) if index < len(pauses) else 0
            if pause > 0:
                pcm_out.write(silence(pause))
                duration += pause / 1000
            timed.append({"index": index, "startSeconds": cursor, "durationSeconds": duration, "text": text})
            cursor += duration
            log(f"SEGMENT_DONE {index} {duration:.3f}")
        tail = int(plan.get("tail_ms", 0))
        if tail > 0:
            pcm_out.write(silence(tail))
            cursor += tail / 1000
        pcm_out.flush()
        with open(args.segments_json, "w", encoding="utf-8") as handle:
            json.dump({"segments": timed}, handle, ensure_ascii=False)
        log(f"DONE {cursor:.3f} {len(segments)}")
        return 0
    except BrokenPipeError:
        return 1
    except Exception as error:  # surfaced to the app as one line
        log(f"ERROR {type(error).__name__}: {error}".replace("\n", " "))
        return 1


if __name__ == "__main__":
    sys.exit(main())
