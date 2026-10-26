#!/usr/bin/env python3
"""Downloads one Pocket TTS language model (Kyutai) into the app's model
cache (HF_HUB_CACHE, set by the app) plus its native voice (v4).

The weights with voice cloning are gated on Hugging Face (terms accepted
once per account); without access the runtime falls back to the public
weights without cloning.

Output lines: STEP …, DONE …, ERROR GATED <repo> | ERROR …
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", required=True, help="e.g. german, german_24l")
    parser.add_argument("--voices", default="", help="comma-separated published voices to fetch")
    args = parser.parse_args()
    try:
        from huggingface_hub import hf_hub_download
        from pocket_tts import TTSModel

        print(f"STEP Lade Pocket-TTS-Modell {args.variant} …", flush=True)
        model = TTSModel.load_model(language=args.variant)
        print(f"STEP Modell geladen ({model.sample_rate} Hz).", flush=True)
        for name in [v for v in args.voices.split(",") if v]:
            print(f"STEP Lade Stimme {name} …", flush=True)
            hf_hub_download("kyutai/pocket-tts", f"languages/{args.variant}/embeddings/{name}.safetensors")
        print(f"DONE Pocket TTS {args.variant} installiert.", flush=True)
        return 0
    except Exception as error:
        text = f"{type(error).__name__}: {error}".replace("\n", " ")
        if "401" in text or "403" in text or "Gated" in text or "gated" in text:
            print("ERROR GATED kyutai/pocket-tts", flush=True)
            return 2
        print(f"ERROR {text}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
