"""Check a batch of saved annotations and build a review page for the user.

    .venv/bin/python tools/training/annotation_qa.py data/recorder-corpus --queue data/recorder-corpus/full-pass-queue.json \\
        --last 25 --model artifacts/pilot-2026-10-12 -o data/recorder-corpus/reviews/<date>-batch-<n>

Checks every annotated frame in the batch (the last N saved frames of the queue, or --since a date):
- errors: the same object outlined twice (same class) or with two classes; more than one self_player; an
  invalid file. Fix every error before asking for a review; the exit status is 1 while any remain.
- warnings: no self_player (fine only while airborne, spectating or dead); objects the --model detects
  confidently (>= 0.6) that no annotation covers (possible misses: check each one); Duo/Squad frames with
  players but no ally_marker (check for teammate name tags); polygons too small to be real objects.

Writes qa.json (for the annotating agent) and index.html with numbered overlays (for the user).
"""
from __future__ import annotations
import argparse
import html
import json
import sys
from datetime import datetime
from pathlib import Path
from dataset import LABELS, load_sessions, validate_annotation

COLORS = {"self_player": (255, 0, 255), "player": (0, 0, 255), "ally_marker": (0, 255, 0), "enemy_marker": (0, 0, 160),
          "ground_item": (0, 230, 255), "door": (255, 255, 0), "chest": (0, 140, 255), "wall": (255, 90, 90),
          "rock": (230, 170, 60), "tree": (60, 200, 60), "revive_target": (255, 255, 255)}
DUPLICATE = 0.5      # Two polygons overlapping this much outline one object.
CONFIDENT = 0.6      # Model detections at least this confident should be annotated or consciously skipped.
TINY = 0.00002       # Normalized area below which a polygon is almost certainly a stray click.


def area(polygon) -> float:
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(polygon, polygon[1:] + polygon[:1]))) / 2


def check(annotation: dict, mode: str, detections: list[dict] | None = None) -> dict:
    """Errors and warnings for one saved annotation; detections are model objects with label/polygon/confidence."""
    from prelabel import overlap
    errors, warnings = [], []
    try:
        validate_annotation({**annotation, "reviewed": True})
    except ValueError as error:
        errors.append(f"invalid annotation: {error}")
        return {"errors": errors, "warnings": warnings}
    objects = annotation["objects"]
    for i, a in enumerate(objects):
        for j in range(i + 1, len(objects)):
            b = objects[j]
            value = overlap(a["polygon"], b["polygon"])
            if value > DUPLICATE:
                kind = "the same object twice" if a["label"] == b["label"] else "one object with two classes"
                errors.append(f"#{i + 1} {a['label']} and #{j + 1} {b['label']} overlap {value:.2f}: {kind}")
        if area(a["polygon"]) < TINY:
            warnings.append(f"#{i + 1} {a['label']} is tiny (stray click?)")
    labels = [o["label"] for o in objects]
    if labels.count("self_player") > 1:
        errors.append(f"{labels.count('self_player')} self_player objects: there is only one")
    if labels.count("self_player") == 0:
        warnings.append("no self_player: fine only while airborne, spectating or dead")
    if mode in ("duo", "squad") and "player" in labels and "ally_marker" not in labels:
        warnings.append("team mode with players but no ally_marker: check for teammate name tags")
    for d in detections or []:
        if d["confidence"] >= CONFIDENT and all(overlap(d["polygon"], o["polygon"]) < 0.2 for o in objects):
            x = [p[0] for p in d["polygon"]]
            y = [p[1] for p in d["polygon"]]
            warnings.append(f"possible miss: model sees a {d['label']} ({d['confidence']:.2f}) at "
                            f"x {min(x):.2f}-{max(x):.2f}, y {min(y):.2f}-{max(y):.2f} that nothing covers")
    return {"errors": errors, "warnings": warnings}


def overlay(image_path: Path, annotation: dict, detections: list[dict], out: Path, width: int = 1600) -> None:
    """The frame with numbered polygons, and white boxes on possible misses."""
    import cv2
    import numpy as np
    from prelabel import overlap
    image = cv2.imread(str(image_path))
    h, w = image.shape[:2]
    for i, o in enumerate(annotation["objects"], 1):
        points = np.round(np.array(o["polygon"]) * [w, h]).astype(np.int32)
        color = COLORS.get(o["label"], (200, 200, 200))
        cv2.polylines(image, [points], True, color, 3)
        x, y = points.min(0)
        cv2.putText(image, f"{i} {o['label']}", (int(x), max(24, int(y) - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.9, color, 2)
    for d in detections:
        if d["confidence"] >= CONFIDENT and all(overlap(d["polygon"], o["polygon"]) < 0.2 for o in annotation["objects"]):
            points = np.round(np.array(d["polygon"]) * [w, h]).astype(np.int32)
            (x0, y0), (x1, y1) = points.min(0), points.max(0)
            cv2.rectangle(image, (int(x0) - 6, int(y0) - 6), (int(x1) + 6, int(y1) + 6), (255, 255, 255), 3)
            cv2.putText(image, f"? {d['label']} {d['confidence']:.2f}", (int(x0), int(y1) + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 2)
    scale = width / w
    cv2.imwrite(str(out), cv2.resize(image, (width, round(h * scale)), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_JPEG_QUALITY, 86])


def model_detector(model: Path):
    """Detections (label, coarse polygon, confidence) from an exported candidate, without Segment Anything."""
    import cv2
    from evaluate import core_ml_predictor, input_shape
    from prelabel import draft_objects
    manifest = json.loads((model / "model.json").read_text())
    predict = core_ml_predictor(model / manifest["modelFile"])
    return lambda image_path: draft_objects(cv2.imread(str(image_path)), predict, None, input_shape(manifest), 0.4)


def page(rows: list[dict], title: str) -> str:
    cards = []
    for n, row in enumerate(rows, 1):
        issues = "".join(f'<li class="error">{html.escape(e)}</li>' for e in row["errors"])
        issues += "".join(f'<li class="warning">{html.escape(w)}</li>' for w in row["warnings"])
        objects = ", ".join(f"{i} {html.escape(o)}" for i, o in enumerate(row["labels"], 1))
        cards.append(f'''<section><h2>{n}. {html.escape(row["matchID"][-6:])} / {html.escape(row["frame"])} <small>{row["mode"]} · {row["split"]} · {html.escape(row["reviewer"])}</small></h2>
<img src="{html.escape(row["overlay"])}" loading="lazy" alt="annotated frame">
<ul>{issues or '<li class="ok">No automatic findings.</li>'}</ul><details><summary>{len(row["labels"])} objects</summary><p>{objects}</p></details>
<p class="notes">{html.escape(row["notes"])}</p></section>''')
    errors = sum(len(r["errors"]) for r in rows)
    warnings = sum(len(r["warnings"]) for r in rows)
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title><style>
:root{{--bg:#f5f6f8;--card:#fff;--text:#1c1f24;--muted:#5d636e;--line:#e0e3e8;--error:#c62828;--warning:#9a6700}}
@media (prefers-color-scheme:dark){{:root{{--bg:#15171b;--card:#1e2126;--text:#eceef1;--muted:#a1a7b1;--line:#30343b;--error:#ff7b72;--warning:#e3b341}}}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}}
main{{max-width:1640px;margin:0 auto;padding:24px 16px}} h1{{margin:0 0 4px}} .lede{{color:var(--muted);margin:0 0 20px}}
section{{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:0 0 18px}}
h2{{font-size:17px;margin:0 0 10px}} small{{color:var(--muted);font-weight:400}} img{{width:100%;height:auto;border-radius:6px}}
.error{{color:var(--error);font-weight:600}} .warning{{color:var(--warning)}} .ok{{color:var(--muted)}} .notes{{color:var(--muted);font-size:13px}}
</style></head><body><main><h1>{html.escape(title)}</h1>
<p class="lede">{len(rows)} frames · {errors} errors · {warnings} warnings. Numbers on each frame match the object list.
White boxes are objects the model sees that no annotation covers. Reply with the frame and object numbers that look wrong.</p>
{''.join(cards)}</main></body></html>'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("recordings", type=Path)
    parser.add_argument("--queue", type=Path, required=True)
    batch = parser.add_mutually_exclusive_group()
    batch.add_argument("--last", type=int, help="the last N annotated frames of the queue, by save time")
    batch.add_argument("--since", help="frames saved at or after this ISO date/time")
    parser.add_argument("--model", type=Path, help="candidate folder; flags confident detections nothing covers")
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    sessions = {s["matchID"]: s for s in load_sessions(args.recordings)}
    assignments_path = args.recordings / "split-assignments.json"
    splits = ({m: a["split"] for m, a in json.loads(assignments_path.read_text())["assignments"].items()}
              if assignments_path.exists() else {})
    saved = []
    for entry in json.loads(args.queue.read_text())["frames"]:
        session = sessions[entry["matchID"]]
        row = next(r for r in session["frames"] if r["image"] == entry["image"])
        if row["annotation_path"].exists():
            data = json.loads(row["annotation_path"].read_text())
            saved.append((data.get("review", {}).get("date", ""), session, row, data))
    saved.sort(key=lambda item: item[0])
    if args.since:
        saved = [item for item in saved if item[0] >= args.since]
    elif args.last:
        saved = saved[-args.last:]
    if not saved:
        raise SystemExit("No annotated frames in that batch")
    detect = model_detector(args.model) if args.model else (lambda path: [])
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for date, session, row, data in saved:
        detections = detect(row["image_path"])
        result = check(data, session["mode"], detections)
        if data.get("returnedForFixes") and data.get("reviewed") is not True:
            result["errors"].insert(0, "returned for fixes and not yet re-saved: " + "; ".join(data["returnedForFixes"]["issues"]))
        name = f"{session['matchID'][-6:]}-{row['image_path'].stem}.jpg"
        overlay(row["image_path"], data, detections, args.output / name)
        rows.append({"matchID": session["matchID"], "frame": row["image_path"].stem, "mode": session["mode"],
                     "split": splits.get(session["matchID"], "?"), "reviewer": data.get("review", {}).get("reviewer", ""),
                     "saved": date, "labels": [o["label"] for o in data.get("objects", [])],
                     "notes": data.get("review", {}).get("notes", ""), "overlay": name, **result})
    (args.output / "qa.json").write_text(json.dumps(rows, indent=2) + "\n")
    (args.output / "index.html").write_text(page(rows, f"Annotation review · {datetime.now():%Y-%m-%d %H:%M}"))
    errors = sum(len(r["errors"]) for r in rows)
    print(json.dumps({"frames": len(rows), "errors": errors, "warnings": sum(len(r["warnings"]) for r in rows),
                      "page": str(args.output / "index.html")}))
    raise SystemExit(1 if errors else 0)


if __name__ == "__main__":
    main()
