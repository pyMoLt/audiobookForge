#!/bin/bash
# Renders the bundled voice samples with the real engines (v4) and copies
# them into the app resources.
#
# 1. Debug app running, engines installed:  abfcmd buildSamples=<dir> [engines=phonon,pocketTTS]
# 2. When <dir>/build.log ends with DONE:     scripts/build_voice_samples.sh <dir>
#
# Budget: all samples together ≤ 8 MB (checked by VoiceSampleBudgetTests).
set -euo pipefail
SRC="${1:?Usage: build_voice_samples.sh <dir with voice_samples.json and sample_*.m4a>}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/AudiobookForge/Resources/VoiceSamples"
mkdir -p "$DEST"
rm -f "$DEST"/sample_*.m4a
cp "$SRC"/sample_*.m4a "$DEST"/
cp "$SRC"/voice_samples.json "$DEST"/
echo "$(ls "$DEST"/sample_*.m4a | wc -l | tr -d ' ') Hörproben, $(du -sh "$DEST" | cut -f1) → $DEST"
