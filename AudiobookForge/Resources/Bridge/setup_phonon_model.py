#!/usr/bin/env python3
"""Downloads one Phonon 40m language model plus that language's catalog
voices into AudiobookForge's model folder (v4).

The 40m models are gated on Hugging Face: the user accepts the terms on the
model page once and signs in (token from HF_TOKEN or a saved `hf auth
login`). The voices (gradium/phonon-voices, Apache 2.0) are ~0.25 MB each
and always come along with their language, so picking a voice never needs
another download.

Output lines: STEP …, PROGRESS <0-1>, DONE …, ERROR GATED <repo> | ERROR …
"""

import argparse
import json
import os
import shutil
import sys

MODEL_FILES = ["config.json", "tokenizer.json", "model.q8.gguf", "default-voice.safetensors"]
VOICE_REPO = "gradium/phonon-voices"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lang", required=True, choices=["de", "en", "fr", "es", "pt"])
    parser.add_argument("--models-root", required=True)
    args = parser.parse_args()

    from huggingface_hub import hf_hub_download
    from huggingface_hub.utils import GatedRepoError, HfHubHTTPError

    repo = f"gradium/phonon-40m-{args.lang}"
    target = os.path.join(args.models_root, args.lang)
    staging = target + ".partial"
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(os.path.join(staging, "voices"), exist_ok=True)

    try:
        print(f"STEP Lade Modell {repo} …", flush=True)
        for index, name in enumerate(MODEL_FILES):
            path = hf_hub_download(repo, name)
            shutil.copyfile(path, os.path.join(staging, name))
            print(f"PROGRESS {(index + 1) / (len(MODEL_FILES) + 1):.2f}", flush=True)

        print("STEP Lade Stimmen der Sprache …", flush=True)
        catalog_path = hf_hub_download(VOICE_REPO, "voices.jsonl")
        voices = []
        for line in open(catalog_path, encoding="utf-8"):
            entry = json.loads(line)
            if entry.get("language") != args.lang:
                continue
            path = hf_hub_download(VOICE_REPO, entry["filename"])
            shutil.copyfile(path, os.path.join(staging, "voices", f"{entry['name']}.safetensors"))
            voices.append({k: entry.get(k) for k in ("name", "voice_id", "locale", "gender", "age", "description")})
        with open(os.path.join(staging, "voices.json"), "w", encoding="utf-8") as handle:
            json.dump(voices, handle, ensure_ascii=False, indent=1)
        print("PROGRESS 1.00", flush=True)

        shutil.rmtree(target, ignore_errors=True)
        os.replace(staging, target)
        print(f"DONE {len(voices)} Stimmen für {args.lang} installiert.", flush=True)
        return 0
    except GatedRepoError:
        shutil.rmtree(staging, ignore_errors=True)
        print(f"ERROR GATED {repo}", flush=True)
        return 2
    except HfHubHTTPError as error:
        shutil.rmtree(staging, ignore_errors=True)
        status = getattr(getattr(error, "response", None), "status_code", 0)
        if status in (401, 403):
            print(f"ERROR GATED {repo}", flush=True)
            return 2
        print(f"ERROR {error}".replace("\n", " "), flush=True)
        return 1
    except Exception as error:
        shutil.rmtree(staging, ignore_errors=True)
        print(f"ERROR {type(error).__name__}: {error}".replace("\n", " "), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
