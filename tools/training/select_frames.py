"""Pick the next round of frames to annotate: spread out, balanced across splits, and informative.

    .venv/bin/python tools/training/select_frames.py data/recorder-corpus --count 300 \\
        --model artifacts/solo-pilot-2026-10-07 -o data/recorder-corpus/round-2-queue.json

How frames are chosen:
- No frame within --min-gap seconds of another chosen, reviewed or in-progress frame of the same recording
  (neighboring frames are near-duplicates and teach the model little).
- Each split gets its share of --count. Within a split, recordings get frames in proportion to the square root
  of their length, fewer when they already have reviewed frames, more for Duo/Squad (--team-weight: only team
  modes contain teammate markers and revives), and at least --min-per-match.
- Training frames: each recording is cut into equal time slices, and in each slice the frame the --model is least
  sure about, or that shows the classes with the fewest reviewed instances, is chosen. Validation and test frames
  are evenly spaced instead, so they stay representative of what the app will see.
- The queue interleaves splits and recordings, so a round stopped partway is still balanced.

The output is an annotate.py / scene_coverage.py queue. Selection only reads frames; it never changes annotations.
"""
from __future__ import annotations
import argparse
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from dataset import LABELS, load_sessions
from prelabel import splits_for

TEAM_MODES = {"duo", "squad"}


def taken_frames(sessions: list[dict], extra_roots: list[Path]) -> dict[str, list[float]]:
    """Timestamps per match that are already annotated, or drafted by a reviewer under review-evidence folders."""
    taken = defaultdict(list)
    by_suffix = {s["matchID"][-6:]: s for s in sessions}
    for session in sessions:
        for row in session["frames"]:
            if row["annotation_path"].exists():
                taken[session["matchID"]].append(row["timestamp"])
    for root in extra_roots:
        for draft in root.rglob("*-draft.json"):
            m = re.match(r"([0-9A-F]{6})-(\d{6})-draft\.json$", draft.name)
            session = by_suffix.get(m.group(1)) if m else None
            if session:
                row = next((r for r in session["frames"] if Path(r["image"]).stem == m.group(2)), None)
                if row:
                    taken[session["matchID"]].append(row["timestamp"])
    return taken


def reviewed_counts(sessions: list[dict]) -> tuple[Counter, Counter]:
    """Reviewed frames per match and instances per class (from annotation files marked reviewed)."""
    frames, instances = Counter(), Counter()
    for session in sessions:
        for row in session["frames"]:
            if row["annotation_path"].exists():
                try:
                    data = json.loads(row["annotation_path"].read_text())
                except ValueError:
                    continue
                if data.get("reviewed") is True:
                    frames[session["matchID"]] += 1
                    instances.update(o["label"] for o in data.get("objects", []))
    return frames, instances


def candidates(session: dict, taken: list[float], min_gap: float, spacing: float) -> list[dict]:
    """Frames at least `spacing` apart and at least `min_gap` from every taken frame."""
    pool, last = [], -math.inf
    for row in session["frames"]:
        t = row["timestamp"]
        if t - last >= spacing and all(abs(t - u) >= min_gap for u in taken):
            pool.append(row)
            last = t
    return pool


def allocate(total: int, weights: dict[str, float], available: dict[str, int], floor: int) -> dict[str, int]:
    """Split `total` across matches by weight (largest remainders), with a floor, never above what is available."""
    quota = {m: min(floor, available[m]) for m in weights}
    remaining = total - sum(quota.values())
    while remaining > 0:
        open_ = {m: w for m, w in weights.items() if quota[m] < available[m]}
        if not open_:
            break
        scale = remaining / sum(open_.values())
        shares = {m: w * scale for m, w in open_.items()}
        step = {m: min(int(s), available[m] - quota[m]) for m, s in shares.items()}
        if sum(step.values()) == 0:  # Hand out single frames by largest remainder.
            for m in sorted(open_, key=lambda m: shares[m] - int(shares[m]), reverse=True)[:remaining]:
                step[m] = 1
        for m, n in step.items():
            quota[m] += n
        remaining = total - sum(quota.values())
    return quota


def spread(pool: list[dict], count: int, min_gap: float) -> list[dict]:
    """`count` frames evenly spaced in time, nearest available candidate to each target."""
    if count <= 0 or not pool:
        return []
    start, end = pool[0]["timestamp"], pool[-1]["timestamp"]
    chosen = []
    for i in range(count):
        target = start + (end - start) * (i + 0.5) / count
        options = [r for r in pool if all(abs(r["timestamp"] - c["timestamp"]) >= min_gap for c in chosen)]
        if not options:
            break
        chosen.append(min(options, key=lambda r: abs(r["timestamp"] - target)))
    return sorted(chosen, key=lambda r: r["timestamp"])


def informative(pool: list[dict], count: int, min_gap: float, score) -> list[dict]:
    """The highest-scoring candidate in each of `count` equal time slices, then the best of the rest."""
    if count <= 0 or not pool:
        return []
    start, end = pool[0]["timestamp"], pool[-1]["timestamp"] + 1e-9
    slices = defaultdict(list)
    for row in pool:
        slices[min(count - 1, int((row["timestamp"] - start) / (end - start) * count))].append(row)
    chosen = []
    ranked = sorted(pool, key=score, reverse=True)
    for bucket in range(count):
        options = [r for r in sorted(slices[bucket], key=score, reverse=True)
                   if all(abs(r["timestamp"] - c["timestamp"]) >= min_gap for c in chosen)]
        if options:
            chosen.append(options[0])
    for row in ranked:
        if len(chosen) >= count:
            break
        if all(abs(row["timestamp"] - c["timestamp"]) >= min_gap for c in chosen):
            chosen.append(row)
    return sorted(chosen, key=lambda r: r["timestamp"])


def model_scorer(model: Path, instances: Counter):
    """Score = how unsure the model is (detections between 0.25 and 0.6) + how rare its confident classes are."""
    import cv2
    from evaluate import core_ml_predictor, decode, letterbox
    manifest = json.loads((model / "model.json").read_text())
    predict = core_ml_predictor(model / manifest["modelFile"])
    rarity = {label: 1 / math.sqrt(1 + instances[label] / 25) for label in LABELS}
    cache = {}

    def score(row: dict) -> float:
        key = str(row["image_path"])
        if key not in cache:
            image = cv2.cvtColor(cv2.imread(key), cv2.COLOR_BGR2RGB)
            canvas, scale, pad_x, pad_y = letterbox(image, manifest["inputSize"])
            raw, _ = predict(canvas)
            labels, scores, _, _ = decode(raw, 0.25, len(LABELS), scale, pad_x, pad_y, image.shape[1], image.shape[0])
            unsure = sum(1 for s in scores if s < 0.6)
            rare = sum(rarity[LABELS[int(l)]] for l, s in zip(labels, scores) if s >= 0.25)
            cache[key] = min(unsure, 15) / 15 + min(rare, 10) / 10
        return cache[key]
    return score


def interleave(groups: dict[str, list[dict]], quotas: dict[str, int]) -> list[dict]:
    """Merge per-split lists so that every prefix keeps the splits near their quota shares."""
    order, used = [], Counter()
    while any(used[s] < len(groups[s]) for s in groups):
        split = min((s for s in groups if used[s] < len(groups[s])), key=lambda s: (used[s] + 1) / max(1, quotas[s]))
        order.append(groups[split][used[split]])
        used[split] += 1
    return order


def by_match_round_robin(frames: list[dict]) -> list[dict]:
    queues = defaultdict(list)
    for f in frames:
        queues[f["matchID"]].append(f)
    ordered = []
    while any(queues.values()):
        for match in sorted(queues):
            if queues[match]:
                ordered.append(queues[match].pop(0))
    return ordered


def select(root: Path, count: int, *, plan: Path | None = None, shares: dict[str, float] | None = None, min_gap: float = 2.0,
           min_per_match: int = 3, team_weight: float = 1.5, score=None, evidence: list[Path] = (), modes: set[str] | None = None) -> dict:
    shares = shares or {"train": 0.7, "val": 0.15, "test": 0.15}
    sessions = [s for s in load_sessions(root) if modes is None or s["mode"] in modes]
    splits = splits_for(root, plan)
    taken = taken_frames(sessions, list(evidence))
    reviewed, instances = reviewed_counts(sessions)
    spacing = max(0.5, min_gap / 2)
    pools = {s["matchID"]: candidates(s, taken[s["matchID"]], min_gap, spacing) for s in sessions}
    by_split, quotas, chosen = defaultdict(list), {}, {}
    for s in sessions:
        by_split[splits.get(s["matchID"], "unplanned")].append(s)
    for split, share in shares.items():
        members = by_split.get(split, [])
        if not members:
            continue
        quotas[split] = round(count * share)
        weights = {}
        for s in members:
            minutes = max(0.1, (s["frames"][-1]["timestamp"] - s["frames"][0]["timestamp"]) / 60) if s["frames"] else 0.1
            weights[s["matchID"]] = (math.sqrt(minutes) / (1 + reviewed[s["matchID"]] / 10)
                                     * (team_weight if s["mode"] in TEAM_MODES else 1.0))
        per_match = allocate(quotas[split], weights, {m: len(pools[m]) for m in weights}, min_per_match)
        for s in members:
            pool, n = pools[s["matchID"]], per_match[s["matchID"]]
            picks = informative(pool, n, min_gap, score) if split == "train" and score else spread(pool, n, min_gap)
            chosen[s["matchID"]] = [(split, row, "informative" if split == "train" and score else "evenly spaced") for row in picks]
    groups = defaultdict(list)
    for match, picks in chosen.items():
        start = next(s for s in sessions if s["matchID"] == match)["frames"][0]["timestamp"]
        for split, row, reason in picks:
            groups[split].append({"matchID": match, "image": row["image"], "timeSeconds": round(row["timestamp"] - start, 3),
                                  "split": split, "reason": reason})
    frames = interleave({k: by_match_round_robin(v) for k, v in groups.items()}, quotas)
    return {"scope": f"Annotation round: {len(frames)} frames chosen by select_frames.py; polygons pending",
            "selection": {"count": count, "shares": shares, "minGapSeconds": min_gap, "minPerMatch": min_per_match,
                          "teamWeight": team_weight, "reviewedInstances": dict(instances)},
            "frames": frames}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("recordings", type=Path)
    parser.add_argument("--count", type=int, default=300)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--model", type=Path, help="candidate folder; ranks training frames by uncertainty and class rarity")
    parser.add_argument("--split-plan", type=Path, help="default: the root's split-assignments.json or split-plan.json")
    parser.add_argument("--shares", default="train=0.7,val=0.15,test=0.15")
    parser.add_argument("--min-gap", type=float, default=2.0, help="seconds between chosen/reviewed frames of one recording")
    parser.add_argument("--min-per-match", type=int, default=3)
    parser.add_argument("--team-weight", type=float, default=1.5)
    parser.add_argument("--modes", nargs="+", choices=["solo", "duo", "squad"])
    parser.add_argument("--evidence", type=Path, action="append", default=[],
                        help="folder of in-progress reviewer drafts (<suffix>-<frame>-draft.json) to keep clear of")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"{args.output} exists; queues are frozen once annotation starts, so choose a new name")
    shares = {k: float(v) for k, v in (part.split("=") for part in args.shares.split(","))}
    score = None
    if args.model:
        _, instances = reviewed_counts(load_sessions(args.recordings))
        score = model_scorer(args.model, instances)
        print("Scoring training candidates with the model…", file=sys.stderr, flush=True)
    queue = select(args.recordings, args.count, plan=args.split_plan, shares=shares, min_gap=args.min_gap,
                   min_per_match=args.min_per_match, team_weight=args.team_weight, score=score, evidence=args.evidence,
                   modes=set(args.modes) if args.modes else None)
    args.output.write_text(json.dumps(queue, indent=2) + "\n")
    tally = Counter((f["split"]) for f in queue["frames"])
    print(json.dumps({"queue": str(args.output), "frames": len(queue["frames"]), "splits": tally,
                      "matches": len({f["matchID"] for f in queue["frames"]})}))


if __name__ == "__main__":
    main()
