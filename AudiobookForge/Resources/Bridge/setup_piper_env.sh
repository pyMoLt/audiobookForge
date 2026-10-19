#!/bin/bash
# Sets up (or repairs) the Python environment AudiobookForge uses to run
# Piper TTS. Piper itself is a plain native CLI once `piper-tts` is
# installed, so this is much simpler than the Kokoro bridge setup — no
# custom wrapper script needed, just a venv with one pip package.
#
# Usage: setup_piper_env.sh <target-dir>

set -euo pipefail

TARGET_DIR="${1:?Usage: setup_piper_env.sh <target-dir>}"
mkdir -p "$TARGET_DIR"

echo "STEP Suche nach einer Python-Installation …"

PYTHON_BIN=""
for candidate in \
    "${APP_RUNTIME_PYTHON:-}" \
    "$HOME/Library/Application Support/AudiobookForge/runtime/python/bin/python3" \
    "$HOME/Library/Application Support/AudiobookForge/runtime/python/bin/python3.12" \
    "$HOME/Library/Application Support/AudiobookForge/runtime/python/bin/python3.11" \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3.11 \
    /usr/local/bin/python3.12 \
    /usr/local/bin/python3.11 \
    "$(command -v python3 || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR Keine Python-Installation gefunden. Bitte installieren: brew install python@3.12"
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

echo "STEP Installiere piper-tts ..."
"$VENV_DIR/bin/pip" install -q piper-tts

echo "DONE Piper-Umgebung ist einsatzbereit. Stimmen können jetzt in den Einstellungen heruntergeladen werden."
