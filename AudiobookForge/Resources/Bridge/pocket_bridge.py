#!/usr/bin/env python3
"""AudiobookForge's Pocket TTS (Kyutai) synthesis bridge (v4).

Speaks a speech plan (planned segments + pauses from the app's
PausePlanner) segment by segment with the official `pocket-tts` runtime
(PyTorch, CPU, one thread — the app runs several processes in parallel).
Voices: a published voice state ("juergen", …, downloaded once into the
app's model cache) or a cloned voice from a reference recording (its state
is computed once and cached next to the clone).

Streams raw 16-bit mono PCM (s16le) on stdout, progress on stderr — same
protocol as the Phonon and Supertonic bridges.
"""

import argparse
import json
import os
import re
import sys

ORDINAL_DATIVE = {"am", "im", "zum", "vom", "beim", "den", "dem", "des", "ab", "bis"}


def speakable(text: str, lang: str) -> str:
    """Pocket reads digits poorly: symbols/abbreviations go through the
    ptts normalizer (de/en/fr/es/pt), numbers are spelled out with
    num2words (all five app languages). Only the spoken copy changes —
    the read-along text keeps the original."""
    try:
        import ptts

        if lang in ("de", "en", "fr", "es", "pt"):
            text = ptts.normalize(text, lang=lang)
    except Exception:
        pass
    try:
        from num2words import num2words
    except Exception:
        return text

    def words(value, **kw):
        try:
            return num2words(value, lang=lang, **kw)
        except Exception:
            return num2words(value, lang=lang)

    comma_decimal = lang != "en"
    # Thousands separators: 1.000 / 1 000 (comma in English).
    group = r"[.\u202f\u00a0 ]" if comma_decimal else r"[,\u202f\u00a0]"
    text = re.sub(rf"(?<=\d){group}(?=\d{{3}}(?!\d))", "", text)
    # Decimals.
    decimal = r"(\d+),(\d+)" if comma_decimal else r"(\d+)\.(\d+)"
    text = re.sub(decimal, lambda m: words(float(f"{m.group(1)}.{m.group(2)}")), text)
    # German ordinals before a capitalized word: "am 3. Mai" -> "am dritten Mai".
    if lang == "de":
        def ordinal(m):
            spoken = words(int(m.group(2)), to="ordinal")
            prefix = m.group(1) or ""
            if prefix.strip().lower() in ORDINAL_DATIVE:
                spoken += "n"
            return f"{prefix}{spoken}"
        text = re.sub(r"(\b\w+\s)?\b(\d{1,2})\.(?=\s+[A-ZÄÖÜ])", ordinal, text)
    # Years read as years, everything else as cardinals.
    def number(m):
        value = int(m.group(0))
        if 1100 <= value <= 1999 and len(m.group(0)) == 4:
            return words(value, to="year")
        return words(value)
    return re.sub(r"\d+", number, text)


def main() -> int:
    pcm_out = os.fdopen(os.dup(1), "wb", buffering=0)
    sys.stdout = sys.stderr

    def log(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--variant", required=True, help="pocket-tts language config, e.g. german or german_24l")
    parser.add_argument("--voice", default="", help="published voice name")
    parser.add_argument("--voice-audio", default="", help="reference recording of a cloned voice")
    parser.add_argument("--voice-cache", default="", help="where the cloned voice state is cached")
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--lang", default="de", help="two-letter language for number reading")
    parser.add_argument("--temperature", type=float, default=0.3, help="sampling temperature (expression)")
    parser.add_argument("--segments-json", required=True)
    args = parser.parse_args()

    try:
        import numpy as np
        import torch
        from pocket_tts import TTSModel

        torch.set_num_threads(max(1, args.threads))
        plan = json.load(open(args.plan, encoding="utf-8"))
        segments = plan["segments"]
        pauses = plan.get("pauses_ms", [])

        model = TTSModel.load_model(language=args.variant)
        model.temp = args.temperature
        if args.voice_audio:
            if args.voice_cache and os.path.exists(args.voice_cache):
                state = model.get_state_for_audio_prompt(args.voice_cache)
            else:
                from pocket_tts.models.model_state import export_model_state

                state = model.get_state_for_audio_prompt(args.voice_audio, truncate=True)
                if args.voice_cache:
                    export_model_state(state, args.voice_cache)
        else:
            from huggingface_hub import hf_hub_download

            name = args.voice or "alba"
            path = hf_hub_download("kyutai/pocket-tts", f"languages/{args.variant}/embeddings/{name}.safetensors")
            state = model.get_state_for_audio_prompt(path)

        rate = int(model.sample_rate)
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
            if text.strip():
                audio = model.generate_audio(state, speakable(text, args.lang)).reshape(-1).float().numpy()
            else:
                audio = np.zeros(0, dtype=np.float32)
            pcm_out.write((np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes())
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
    except Exception as error:
        log(f"ERROR {type(error).__name__}: {error}".replace("\n", " "))
        return 1


if __name__ == "__main__":
    sys.exit(main())
