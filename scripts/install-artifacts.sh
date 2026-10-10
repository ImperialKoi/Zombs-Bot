#!/bin/bash
# Installs a trained detector (and optionally a seeded icon library) into the app's data folder.
# Usage: bash scripts/install-artifacts.sh <model-artifacts-dir> [icons.json]
set -euo pipefail
cd "$(dirname "$0")/.."
model="${1:?Usage: install-artifacts.sh <model-artifacts-dir> [icons.json]}"
icons="${2:-}"
target="$HOME/Library/Application Support/ZombsAssistant/artifacts"
mkdir -p "$target"
[[ -f "$model/model.json" && -d "$model/zombs.mlpackage" ]] || { echo "Missing model.json or zombs.mlpackage in $model" >&2; exit 1; }
rm -rf "$target/zombs.mlpackage"
cp -R "$model/zombs.mlpackage" "$target/zombs.mlpackage"
cp "$model/model.json" "$target/model.json"
if [[ -f "$model/validation.json" ]]; then cp "$model/validation.json" "$target/validation.json"; else rm -f "$target/validation.json"; fi
if [[ -n "$icons" ]]; then
  # Keep icons the app already learned from your pickups; add the seed's.
  python3 - "$icons" "$target/icons.json" <<'PY'
import json, sys
from pathlib import Path
seed, dest = Path(sys.argv[1]), Path(sys.argv[2])
entries = json.loads(dest.read_text()) if dest.exists() else []
known = {json.dumps(e["identity"], sort_keys=True) + json.dumps(e["fingerprint"], sort_keys=True) for e in entries}
added = 0
for e in json.loads(seed.read_text()):
    key = json.dumps(e["identity"], sort_keys=True) + json.dumps(e["fingerprint"], sort_keys=True)
    if key not in known:
        entries.append(e); known.add(key); added += 1
dest.write_text(json.dumps(entries))
print(f"Icon library: {len(entries)} icons ({added} added)")
PY
fi
printf 'Installed %s into %s\n' "$model" "$target"
