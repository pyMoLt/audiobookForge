#!/usr/bin/env python3
"""Install a matching German Kokoro checkpoint and voice pack for mlx-audio.

The checkpoint/voice pairing follows the published Kikiri and Thorsten model
cards. Weight-key conversion uses the Kokoro-compatible naming convention
documented by the MIT-licensed litcast project (CorruptCarl/litcast).
"""

import argparse
import json
import os
import shutil
import uuid
from pathlib import Path

from huggingface_hub import HfApi, hf_hub_download
from safetensors.torch import save_file
import torch


SOURCES = {
    "martin": ("kikiri-tts/kikiri-german-martin", "kikiri_german_martin_ep10.pth", "voices/martin.pt"),
    "victoria": ("kikiri-tts/kikiri-german-victoria", "kikiri_german_victoria_ep10.pth", "voices/victoria.pt"),
    "thorsten": ("Thorsten-Voice/Kokoro", "model.pth", "voices/thorsten.pt"),
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice", choices=sorted(SOURCES), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    target = args.output.expanduser()
    if all((target / name).exists() for name in ("model.safetensors", "config.json", f"voices/{args.voice}.safetensors")):
        print(f"READY {target}", flush=True)
        return 0
    if target.exists():
        raise RuntimeError(f"Zielordner enthält eine unvollständige Installation: {target}")

    repo, model_name, voice_name = SOURCES[args.voice]
    revision = HfApi().model_info(repo).sha
    print(f"DOWNLOAD {repo}@{revision}", flush=True)
    model_path = hf_hub_download(repo_id=repo, filename=model_name, revision=revision)
    voice_path = hf_hub_download(repo_id=repo, filename=voice_name, revision=revision)
    config_repo = repo if args.voice == "thorsten" else "hexgrad/Kokoro-82M"
    config_path = hf_hub_download(repo_id=config_repo, filename="config.json")

    print("CONVERT checkpoint", flush=True)
    checkpoint = torch.load(model_path, map_location="cpu", weights_only=False)
    weights = {}
    for section, section_dict in checkpoint.items():
        for key, tensor in section_dict.items():
            key = key.removeprefix("module.")
            key = key.replace(".parametrizations.weight.original0", ".weight_g")
            key = key.replace(".parametrizations.weight.original1", ".weight_v")
            weights[f"{section}.{key}"] = tensor.contiguous().float()

    staging = target.parent / f".kokoro-{args.voice}-{uuid.uuid4().hex}"
    (staging / "voices").mkdir(parents=True)
    try:
        save_file(weights, staging / "model.safetensors")
        config = json.loads(Path(config_path).read_text())
        config["model_type"] = "kokoro"
        (staging / "config.json").write_text(json.dumps(config, indent=2))

        voice = torch.load(voice_path, map_location="cpu", weights_only=True)
        voice_weights = {"voice": voice} if isinstance(voice, torch.Tensor) else voice
        save_file(voice_weights, staging / "voices" / f"{args.voice}.safetensors")
        (staging / "source.json").write_text(json.dumps({"repo": repo, "revision": revision, "voice": args.voice}, indent=2))
        os.rename(staging, target)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    print(f"DONE {target}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
