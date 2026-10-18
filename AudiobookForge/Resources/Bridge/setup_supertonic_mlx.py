#!/usr/bin/env python3
"""Install pinned Supertonic 3 MLX weights and its MIT-licensed runtime."""

import argparse
import io
import json
import os
import tarfile
import urllib.request
import uuid
from pathlib import Path

from huggingface_hub import snapshot_download


MODEL_REPO = "mlx-community/supertonic-3"
MODEL_REVISION = "464f0375660e487e9f2be826ee779e16504cf992"
RUNTIME_REVISION = "70c7e3a24f34c2246acc11fb0cf1a7c26bcc7f06"
RUNTIME_URL = f"https://github.com/ailuntx/supertonic-mlx/archive/{RUNTIME_REVISION}.tar.gz"


def install_runtime(target: Path):
    if (target / "supertonic_mlx" / "__init__.py").exists():
        print(f"RUNTIME_READY {target}", flush=True)
        return
    if target.exists():
        raise RuntimeError(f"Unvollständiger Supertonic-Laufzeitordner: {target}")
    print(f"DOWNLOAD runtime {RUNTIME_REVISION}", flush=True)
    archive = urllib.request.urlopen(RUNTIME_URL, timeout=60).read()
    staging = target.parent / f".supertonic-runtime-{uuid.uuid4().hex}"
    staging.mkdir(parents=True)
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
            for member in tar.getmembers():
                parts = Path(member.name).parts
                if len(parts) < 2 or not member.isfile():
                    continue
                relative = Path(*parts[1:])
                if relative.parts[0] != "supertonic_mlx" and relative.name != "LICENSE":
                    continue
                destination = staging / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                if source:
                    destination.write_bytes(source.read())
        (staging / "source.json").write_text(json.dumps({"repository": "ailuntx/supertonic-mlx", "revision": RUNTIME_REVISION}, indent=2))
        os.rename(staging, target)
    except BaseException:
        import shutil
        shutil.rmtree(staging, ignore_errors=True)
        raise
    print(f"RUNTIME_DONE {target}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--runtime-dir", type=Path, required=True)
    args = parser.parse_args()
    args.model_dir.parent.mkdir(parents=True, exist_ok=True)
    args.runtime_dir.parent.mkdir(parents=True, exist_ok=True)
    print(f"DOWNLOAD model {MODEL_REPO}@{MODEL_REVISION}", flush=True)
    snapshot_download(repo_id=MODEL_REPO, revision=MODEL_REVISION, local_dir=args.model_dir)
    install_runtime(args.runtime_dir)
    print("DONE Supertonic 3 MLX bereit", flush=True)


if __name__ == "__main__":
    main()
