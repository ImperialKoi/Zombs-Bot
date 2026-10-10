"""Draft annotations for queued frames: the trained detector finds objects and Segment Anything outlines them.

    .venv/bin/python tools/training/prelabel.py data/recorder-corpus artifacts/solo-pilot-2026-10-07 \\
        --queue data/recorder-corpus/round-2-queue.json

Drafts go to <match>/model-drafts/<frame>.json with reviewed=false. They are starting points, never reviews:
the coverage audit and dataset export read only annotations/<frame>.json, which a reviewer's save writes.
annotate.py opens a draft when a frame has no annotation yet.

Test-split matches are skipped unless --include-test, so held-out labels are drawn without the model's
suggestions. Frames that already have an annotation file, reviewed or not, are never drafted. Detection runs
in Core ML as the app decodes it; outlines run on the CPU. Walls keep the detector's own mask, because a box
around a wall band makes Segment Anything select the whole building.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from dataset import LABELS, load_sessions

DETECTOR_OUTLINES = {"wall"}  # Classes whose draft keeps the detector's mask instead of a SAM outline.
AGREEMENT = 0.3  # A SAM outline overlapping the detector's mask less than this outlined something else.
PADDING = 0.04   # Grow each detector box a little so SAM sees the whole object.


def splits_for(root: Path, plan: Path | None) -> dict[str, str]:
    """matchID → split from a split plan, or from a recorder corpus's split-assignments.json."""
    if plan is None and (root / "split-assignments.json").exists():
        return {m: a["split"] for m, a in json.loads((root / "split-assignments.json").read_text())["assignments"].items()}
    plan = plan or root / "split-plan.json"
    if not plan.exists():
        raise SystemExit(f"No split plan: pass --split-plan (looked for {plan})")
    return {match: split for split, ids in json.loads(plan.read_text())["splits"].items() for match in ids}


def frames_to_draft(sessions: list[dict], queued: list[dict], splits: dict[str, str], include_test: bool = False,
                    overwrite: bool = False) -> tuple[list[tuple[dict, Path]], dict[str, int]]:
    """(frame row, draft path) for each queued frame to draft, and counts of what was skipped and why."""
    rows = {(s["matchID"], r["image"]): (s, r) for s in sessions for r in s["frames"]}
    todo, skipped = [], {"test split": 0, "annotated": 0, "drafted": 0, "unknown": 0}
    for entry in queued:
        found = rows.get((entry["matchID"], entry["image"]))
        if found is None:
            skipped["unknown"] += 1
            continue
        session, row = found
        target = session["directory"] / "model-drafts" / (row["image_path"].stem + ".json")
        if splits.get(entry["matchID"]) == "test" and not include_test:
            skipped["test split"] += 1
        elif row["annotation_path"].exists():
            skipped["annotated"] += 1
        elif target.exists() and not overwrite:
            skipped["drafted"] += 1
        else:
            todo.append((row, target))
    return todo, skipped


def detector_polygons(raw, proto, anchors, boxes, geometry, size):
    """Each detection's own mask (prototype logits at the 0.5 threshold, inside its box) as a polygon, 0-1 coordinates."""
    import cv2
    import numpy as np
    from evaluate import dimensions
    from outline import mask_to_polygon
    scale, pad_x, pad_y, width, height = geometry
    content_w, content_h = round(width * scale), round(height * scale)
    x0, y0 = round(pad_x), round(pad_y)
    polygons = []
    for anchor, box in zip(anchors, boxes):
        logits = cv2.resize(np.tensordot(raw[4 + len(LABELS):, anchor], proto, 1).astype(np.float32), dimensions(size),
                            interpolation=cv2.INTER_LINEAR)[y0:y0 + content_h, x0:x0 + content_w]
        bx0, by0 = int(np.floor(box[0] * content_w)), int(np.floor(box[1] * content_h))
        bx1, by1 = int(np.ceil(box[2] * content_w)), int(np.ceil(box[3] * content_h))
        mask = np.zeros(logits.shape, np.uint8)
        mask[by0:by1, bx0:bx1] = logits[by0:by1, bx0:bx1] >= 0
        polygon = mask_to_polygon(mask, epsilon=0.5)
        polygons.append(None if polygon is None else [[x / content_w, y / content_h] for x, y in polygon])
    return polygons


def overlap(a, b, width: int = 960, height: int = 434) -> float:
    """IoU of two 0-1 polygons rasterized on a small grid."""
    import cv2
    import numpy as np
    masks = []
    for polygon in (a, b):
        mask = np.zeros((height, width), np.uint8)
        cv2.fillPoly(mask, [np.round(np.array(polygon) * [width * 16, height * 16]).astype(np.int32)], 1, shift=4)
        masks.append(mask.astype(bool))
    union = (masks[0] | masks[1]).sum()
    return float((masks[0] & masks[1]).sum() / union) if union else 0.0


def draft_objects(image, predict, outliner, size, threshold: float) -> list[dict]:
    """Detect, outline and label every object in one BGR frame. `size` is the model input's (width, height)."""
    import cv2
    from evaluate import decode, letterbox
    from outline import normalized
    height, width = image.shape[:2]
    canvas, scale, pad_x, pad_y = letterbox(cv2.cvtColor(image, cv2.COLOR_BGR2RGB), size)
    raw, proto = predict(canvas)
    labels, scores, boxes, anchors = decode(raw, threshold, len(LABELS), scale, pad_x, pad_y, width, height)
    coarse = detector_polygons(raw, proto, anchors, boxes, (scale, pad_x, pad_y, width, height), size)
    fine = [None] * len(boxes)
    if outliner is not None and len(boxes):
        outliner.set_image(image)
        padded = [[max(0, (b[0] - PADDING * (b[2] - b[0])) * width), max(0, (b[1] - PADDING * (b[3] - b[1])) * height),
                   min(width, (b[2] + PADDING * (b[2] - b[0])) * width), min(height, (b[3] + PADDING * (b[3] - b[1])) * height)]
                  for b in boxes]
        fine = [normalized(p, width, height) if p else None for p in outliner.outline(padded)]
    objects = []
    for label, score, rough, outlined in zip(labels, scores, coarse, fine):
        name = LABELS[int(label)]
        use_sam = outlined is not None and name not in DETECTOR_OUTLINES and (rough is None or overlap(rough, outlined) >= AGREEMENT)
        polygon = outlined if use_sam else rough
        if polygon is None or len(polygon) < 3:
            continue
        objects.append({"label": name, "polygon": [[round(x, 7), round(y, 7)] for x, y in polygon],
                        "confidence": round(float(score), 3), "source": "sam" if use_sam else "detector"})
    return objects


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("recordings", type=Path, help="recordings root, e.g. data/recorder-corpus")
    parser.add_argument("model", type=Path, help="exported candidate folder with model.json and zombs.mlpackage")
    parser.add_argument("--queue", type=Path, required=True, help="frames to draft")
    parser.add_argument("--split-plan", type=Path, help="default: the root's split-assignments.json or split-plan.json")
    parser.add_argument("--threshold", type=float, default=0.3, help="detection confidence for drafts (the app uses 0.5)")
    parser.add_argument("--include-test", action="store_true", help="also draft test-split frames (not recommended)")
    parser.add_argument("--no-sam", action="store_true", help="keep the detector's coarse masks for every class")
    parser.add_argument("--overwrite", action="store_true", help="replace existing drafts")
    parser.add_argument("--limit", type=int, help="draft at most this many frames")
    args = parser.parse_args()

    import cv2
    from evaluate import core_ml_predictor, input_shape
    manifest = json.loads((args.model / "model.json").read_text())
    if manifest["labels"] != LABELS:
        raise SystemExit("The model's labels differ from dataset.LABELS")
    splits = splits_for(args.recordings, args.split_plan)
    todo, skipped = frames_to_draft(load_sessions(args.recordings), json.loads(args.queue.read_text())["frames"], splits,
                                    args.include_test, args.overwrite)
    todo = todo[:args.limit] if args.limit else todo
    print(f"Drafting {len(todo)} frames; skipped {skipped}", file=sys.stderr, flush=True)
    predict = core_ml_predictor(args.model / manifest["modelFile"])
    outliner = None
    if not args.no_sam:
        from outline import Outliner
        outliner = Outliner()
    info = {"model": str(args.model), "modelSHA256": manifest["modelSHA256"], "trainedOn": manifest.get("trainedOn"),
            "threshold": args.threshold, "outlines": "detector masks" if args.no_sam else "SAM 2.1 tiny (walls: detector masks)"}
    counts, started = {}, time.time()
    for n, (row, target) in enumerate(todo, 1):
        data = row["image_path"].read_bytes()
        image = cv2.imread(str(row["image_path"]))
        objects = draft_objects(image, predict, outliner, input_shape(manifest), args.threshold)
        for obj in objects:
            counts[obj["label"]] = counts.get(obj["label"], 0) + 1
        target.parent.mkdir(exist_ok=True)
        draft = {"reviewed": False, "objects": objects,
                 "draft": {**info, "imageSHA256": hashlib.sha256(data).hexdigest(),
                           "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds")}}
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(draft) + "\n")
        temporary.replace(target)
        if n % 10 == 0 or n == len(todo):
            print(f"  {n}/{len(todo)} frames, {(time.time() - started) / n:.1f} s each", file=sys.stderr, flush=True)
    print(json.dumps({"drafted": len(todo), "skipped": skipped, "objects": counts}))


if __name__ == "__main__":
    main()
