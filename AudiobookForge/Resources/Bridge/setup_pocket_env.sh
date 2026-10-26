#!/bin/bash
# Sets up (or repairs) the Python environment AudiobookForge uses to run
# Pocket TTS (Kyutai): the official `pocket-tts` package on PyTorch (CPU
# wheels). Needs Python 3.10 or newer.
#
# Usage: setup_pocket_env.sh <target-dir>

set -euo pipefail

TARGET_DIR="${1:?Usage: setup_pocket_env.sh <target-dir>}"
mkdir -p "$TARGET_DIR"

echo "STEP Suche nach einer Python-Installation …"

PYTHON_BIN=""
for candidate in \
    "${APP_RUNTIME_PYTHON:-}" \
    "$HOME/Library/Application Support/AudiobookForge/runtime/python/bin/python3" \
    /opt/homebrew/bin/python3.13 \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3.11 \
    /opt/homebrew/opt/python@3.13/bin/python3.13 \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/opt/python@3.11/bin/python3.11 \
    /usr/local/bin/python3.12 \
    /usr/local/bin/python3.11 \
    "$(command -v python3 || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR Pocket TTS braucht Python 3.10 oder neuer. Bitte installieren: brew install python@3.12"
    exit 1
fi

echo "STEP Verwende Python: $PYTHON_BIN ($($PYTHON_BIN --version 2>&1))"

VENV_DIR="$TARGET_DIR/.venv"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "STEP Erstelle virtuelle Umgebung unter $VENV_DIR ..."
    rm -rf "$VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    echo "STEP Virtuelle Umgebung existiert bereits, wird wiederverwendet."
fi

echo "STEP Aktualisiere pip ..."
"$VENV_DIR/bin/pip" install --upgrade pip -q

echo "STEP Installiere Pocket TTS mit PyTorch (CPU, ~900 MB) ..."
"$VENV_DIR/bin/pip" install -q "pocket-tts==4.0.1" huggingface_hub "ptts==0.4.2" "num2words==0.5.14" --extra-index-url https://download.pytorch.org/whl/cpu

"$VENV_DIR/bin/python" -I -c "import pocket_tts, torch; print('STEP pocket-tts bereit, torch', torch.__version__)"
echo "DONE Pocket-TTS-Laufzeit ist einsatzbereit. Sprachmodelle können jetzt geladen werden."
