#!/bin/bash
# Sets up (or repairs) the Python environment AudiobookForge uses to run
# Kokoro TTS via mlx-audio. Invoked by the app's Diagnostics tab; safe to
# re-run (idempotent) and prints progress to stdout for the app to stream.
#
# Usage: setup_bridge_env.sh <target-dir>
# <target-dir> will contain a `.venv` with mlx-audio, misaki[en] and
# soundfile installed on top of a Python 3.11/3.12 interpreter (Python 3.13
# currently fails to build the `blis`/`spacy` dependency chain that misaki
# pulls in on Apple Silicon).

set -euo pipefail

TARGET_DIR="${1:?Usage: setup_bridge_env.sh <target-dir>}"
mkdir -p "$TARGET_DIR"

echo "STEP Suche nach einer kompatiblen Python-Version (3.11 oder 3.12)..."

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
    "$(command -v python3.12 || true)" \
    "$(command -v python3.11 || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR Keine Python 3.11/3.12-Installation gefunden. Bitte installieren: brew install python@3.12"
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

echo "STEP Installiere mlx-audio (Kokoro-TTS-Engine) ..."
"$VENV_DIR/bin/pip" install -q mlx-audio

echo "STEP Installiere misaki[en] (Text-Vorverarbeitung fuer Kokoro) ..."
"$VENV_DIR/bin/pip" install -q "misaki[en]"

echo "STEP Installiere soundfile (Audio-Export) ..."
"$VENV_DIR/bin/pip" install -q soundfile

echo "STEP Lade Kokoro-Modellgewichte einmalig herunter (kann beim ersten Mal einige Minuten dauern) ..."
TEST_TEXT_FILE=$(mktemp)
echo "Setup check." > "$TEST_TEXT_FILE"
TEST_OUTPUT="$TARGET_DIR/.setup_check.wav"
"$VENV_DIR/bin/python" "$(dirname "$0")/kokoro_bridge.py" \
    --text-file "$TEST_TEXT_FILE" \
    --output "$TEST_OUTPUT" \
    --voice af_heart \
    --speed 1.0
rm -f "$TEST_TEXT_FILE" "$TEST_OUTPUT" "$TARGET_DIR/.setup_check.segments.json"

echo "DONE Bridge-Umgebung ist einsatzbereit."
