#!/bin/bash
# live_llm_check.sh — gesperrtes Gate (Umsetzungsplan v3, Abschnitt 7.6).
#
# Live-Validierung der KI-Gliederung gegen ein echtes Modell:
#   1. 3 Kapitel eines synthetischen Testbuchs, Übergangskontext an/aus,
#      Vergleich der Übergänge an Chunk-Grenzen.
#   2. Überschriften-Qualität (eine Überschrift je Hauptabschnitt).
#   3. Dauer/Tokens je Aufruf.
#
# DARF NUR nach ausdrücklicher Freigabe des Nutzers ausgeführt werden
# (Aufruf mit ABF_LIVE_LLM_CHECK=1). Ohne diese Variable druckt das Skript
# nur seine Nutzung und bricht ab — es startet selbst KEINEN Server und
# lädt kein Modell (der Nutzer betreibt oMLX separat).

set -euo pipefail

if [[ "${ABF_LIVE_LLM_CHECK:-}" != "1" ]]; then
    cat <<'EOF'
[live_llm_check] GESPERRT — läuft nicht ohne Freigabe.

Dieses Skript sendet echte Anfragen an den konfigurierten LLM-Endpoint.
Aufruf nur nach Freigabe des Nutzers:

    ABF_LIVE_LLM_CHECK=1 scripts/live_llm_check.sh [--base-url URL] [--model NAME] [--out DIR]

Voraussetzungen:
  - oMLX/LM-Studio läuft bereits (Default: http://127.0.0.1:8072/v1)
  - Ein reasoning-fähiges Modell ist geladen (z. B. Qwen3.6-35B-UD-MLX)
  - Ausgabe landet in --out (Default: build/live_llm_check/)
EOF
    exit 1
fi

BASE_URL="http://127.0.0.1:8072/v1"
MODEL=""
OUT_DIR="build/live_llm_check"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url) BASE_URL="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$MODEL" ]]; then
    echo "[live_llm_check] Kein Modell angegeben — frage /models ab …"
    MODEL=$(curl -sf "$BASE_URL/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
    echo "[live_llm_check] Modell: $MODEL"
fi

mkdir -p "$OUT_DIR"
echo "[live_llm_check] Endpoint: $BASE_URL  Modell: $MODEL  Ausgabe: $OUT_DIR"

# Drei kurze Kapitel eines synthetischen Testbuchs. Kapitel 2 ist absichtlich
# größer als ein typisches Chunk-Budget, damit ein Übergang an einer
# Chunk-Grenze entsteht — der zu prüfende Fall.
python3 - "$BASE_URL" "$MODEL" "$OUT_DIR" <<'PYEOF'
import json, sys, time, urllib.request

base_url, model, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]

system_prompt_head = "You are a precise summarization assistant preparing narration text for an audiobook."

chapter1 = ("Kapitel 1: Grundlagen. " + "Die Diagnostik beginnt mit der Anamnese. " * 40).strip()
chapter2 = ("Kapitel 2: Therapie. Zunächst steht die medikamentöse Option im Vordergrund. " * 90).strip()
chapter3 = ("Kapitel 3: Prognose. " + "Die Prognose ist bei früher Therapie gut. " * 30).strip()

def call(user_prompt, tag):
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt_head + " Start with a heading '## ' and write dense narration text."},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.4,
        "max_tokens": 2048,
    }
    started = time.time()
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=600) as response:
        result = json.load(response)
    elapsed = time.time() - started
    choice = result["choices"][0]
    content = choice["message"].get("content", "")
    with open(f"{out_dir}/{tag}.md", "w") as fh:
        fh.write(content)
    usage = result.get("usage", {})
    print(f"  [{tag}] {elapsed:.1f}s, {usage.get('completion_tokens')} Tokens, finish={choice.get('finish_reason')}")
    return content

# Fall 1/2: Übergang mit und ohne Kontextbrücke an derselben Stückgrenze.
mid = len(chapter2) // 2
part_a, part_b = chapter2[:mid].strip(), chapter2[mid:].strip()
context = part_a[-600:]

print("[live_llm_check] Fall 1: Übergang OHNE Kontext")
call(f"Text to condense:\n{part_b}", "1_no_context")
print("[live_llm_check] Fall 2: Übergang MIT Kontext")
call(f"Text to condense:\n{part_b}\n\n[Context — already covered, do not summarize again]\n{context}", "2_with_context")

# Fall 3: Überschriften-Qualität über ein ganzes „Buch“ (3 Aufrufe).
print("[live_llm_check] Fall 3: Überschriften je Kapitel")
for name, text in [("ch1", chapter1), ("ch2", chapter2), ("ch3", chapter3)]:
    call(f"Text to condense:\n{text}", f"3_{name}")

print("[live_llm_check] Fertig. Manuell prüfen: Übergänge in 1/2, Überschriften in 3_*, Dauer oben.")
PYEOF
