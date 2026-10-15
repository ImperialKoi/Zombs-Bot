#!/usr/bin/env python3
"""Compare two ZombsPerceive --jsonl replays frame by frame, ignoring the timing fields.

Replays with --decide and synchronous text are deterministic, so a change meant to keep behavior must give 0 differing
frames. Note that the JSONL rounds positions and confidences; ZombsPerceive --compare-model compares detections exactly.
Usage: compare_replays.py baseline.jsonl candidate.jsonl [--show N]
"""
import json, sys

TIMING = {"hudMS", "detectMS", "bulletMS"}

def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                for k in TIMING:
                    r.pop(k, None)
                rows.append(r)
    return rows

def diff(a, b, path=""):
    if type(a) != type(b):
        return [f"{path}: {a!r} != {b!r}"]
    if isinstance(a, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{path}.{k}: missing in {'baseline' if k not in a else 'candidate'}")
            else:
                out += diff(a[k], b[k], f"{path}.{k}")
        return out
    if isinstance(a, list):
        if len(a) != len(b):
            return [f"{path}: length {len(a)} != {len(b)}"]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += diff(x, y, f"{path}[{i}]")
        return out
    return [] if a == b else [f"{path}: {a!r} != {b!r}"]

def main():
    args = sys.argv[1:]
    show = 10
    if "--show" in args:
        i = args.index("--show"); show = int(args[i + 1]); del args[i:i + 2]
    a, b = load(args[0]), load(args[1])
    if len(a) != len(b):
        print(f"frame count differs: {len(a)} vs {len(b)}")
    bad = 0
    fields = {}
    for x, y in zip(a, b):
        d = diff(x, y)
        if d:
            bad += 1
            for line in d:
                key = line.split(":")[0].split("[")[0]
                fields[key] = fields.get(key, 0) + 1
            if bad <= show:
                print(f"{x.get('match')} {x.get('image')}:")
                for line in d[:8]:
                    print("   ", line)
    print(f"{bad} of {min(len(a), len(b))} frames differ")
    if fields:
        print("differing fields:", dict(sorted(fields.items(), key=lambda kv: -kv[1])[:20]))
    sys.exit(1 if bad or len(a) != len(b) else 0)

main()
