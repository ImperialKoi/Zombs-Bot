"""Evaluate the exported Core ML model on held-out matches. Validation never comes from training loss.

Detections are decoded as Detector.swift decodes them: centered gray letterbox, best class per
anchor, class-aware NMS at IoU 0.45, at most 100 detections. Highest confidence first, a detection
matches the unmatched same-class reference box it overlaps most when IoU >= 0.5. Precision and
recall use the manifest's detector threshold; AP50 includes detections down to 0.001. The release
gate takes the minimum over every class, so a class without test instances scores zero.
"""
import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path
from dataset import LABELS, MODES, tree_hash

SCENARIOS = {"ally_exclusion", "obstacles", "ambiguous_interactions", "healing_interrupt",
             "temporary_swap", "missing_weapon", "stack_remaining", "focus_loss", "stale_frame",
             "resize", "emergency_stop", "manual_movement"}
NMS_IOU, MAX_CANDIDATES, MAX_DETECTIONS, MATCH_IOU, AP_FLOOR = 0.45, 1000, 100, 0.5, 0.001


def iou(box, boxes):
    """IoU of one xyxy box against an (n, 4) array."""
    import numpy as np
    inter = (np.clip(np.minimum(box[2], boxes[:, 2]) - np.maximum(box[0], boxes[:, 0]), 0, None)
             * np.clip(np.minimum(box[3], boxes[:, 3]) - np.maximum(box[1], boxes[:, 1]), 0, None))
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return inter / np.maximum((box[2] - box[0]) * (box[3] - box[1]) + areas - inter, 1e-9)


def input_shape(manifest):
    """(width, height) of the model input; manifests without inputHeight describe a square."""
    return manifest["inputSize"], manifest.get("inputHeight", manifest["inputSize"])


def dimensions(size):
    """A model input size as (width, height); a single int is a square."""
    return (size, size) if isinstance(size, int) else tuple(size)


def letterbox(image, size, interpolation=None):
    """Center an RGB frame on a gray canvas of the input size, as Detector.swift renders the model input.

    `size` is (width, height), or one int for a square input. Area resampling is closest to the app's
    Core Image downscale (mean 0.45 levels on a 3840 x 1736 frame).
    """
    import cv2
    import numpy as np
    input_width, input_height = dimensions(size)
    height, width = image.shape[:2]
    scale = min(input_width / width, input_height / height)
    resized = cv2.resize(image, (round(width * scale), round(height * scale)),
                         interpolation=cv2.INTER_AREA if interpolation is None else interpolation)
    canvas = np.full((input_height, input_width, 3), 114, np.uint8)
    top, left = (input_height - resized.shape[0]) // 2, (input_width - resized.shape[1]) // 2
    canvas[top:top + resized.shape[0], left:left + resized.shape[1]] = resized
    return canvas, scale, (input_width - width * scale) / 2, (input_height - height * scale) / 2


def decode(raw, threshold, classes, scale, pad_x, pad_y, width, height):
    """Raw [4 + classes + 32, anchors] output to (labels, scores, normalized xyxy boxes, anchors)."""
    import numpy as np
    scores = raw[4:4 + classes]
    labels, confidence = scores.argmax(0), scores.max(0)
    cx, cy, w, h = raw[:4]
    boxes = np.stack([np.maximum(0, (cx - w / 2 - pad_x) / (scale * width)),
                      np.maximum(0, (cy - h / 2 - pad_y) / (scale * height)),
                      np.minimum(1, (cx + w / 2 - pad_x) / (scale * width)),
                      np.minimum(1, (cy + h / 2 - pad_y) / (scale * height))], 1)
    valid = (confidence >= threshold) & (boxes[:, 2] > boxes[:, 0]) & (boxes[:, 3] > boxes[:, 1])
    candidates = np.nonzero(valid)[0]
    kept = []
    for i in candidates[np.argsort(-confidence[candidates], kind="stable")][:MAX_CANDIDATES]:
        same = [k for k in kept if labels[k] == labels[i]]
        if same and iou(boxes[i], boxes[same]).max() > NMS_IOU:
            continue
        kept.append(i)
        if len(kept) == MAX_DETECTIONS:
            break
    kept = np.array(kept, int)
    return labels[kept], confidence[kept], boxes[kept], kept


def match(labels, scores, boxes, reference_labels, reference_boxes):
    """Index of the matched reference instance for each detection, or -1."""
    import numpy as np
    assigned = np.full(len(labels), -1)
    taken = np.zeros(len(reference_labels), bool)
    for i in np.argsort(-scores, kind="stable"):
        options = np.nonzero((reference_labels == labels[i]) & ~taken)[0]
        if len(options):
            overlaps = iou(boxes[i], reference_boxes[options])
            if overlaps.max() >= MATCH_IOU:
                assigned[i] = options[overlaps.argmax()]
                taken[assigned[i]] = True
    return assigned


def average_precision(scores, hits, total):
    """COCO-style 101-point interpolated AP; None without reference instances."""
    import numpy as np
    if not total:
        return None
    order = np.argsort(-np.asarray(scores, float), kind="stable")
    hits = np.asarray(hits, bool)[order]
    tp, fp = np.cumsum(hits), np.cumsum(~hits)
    precision = np.maximum.accumulate((tp / np.maximum(tp + fp, 1))[::-1])[::-1]
    index = np.searchsorted(tp / total, np.linspace(0, 1, 101), side="left")
    return float(np.mean([precision[i] if i < len(precision) else 0.0 for i in index]))


def load_reference(label_file):
    """Classes, normalized xyxy boxes and polygons from an exported YOLO segmentation label file."""
    import numpy as np
    rows = [line.split() for line in label_file.read_text().splitlines() if line.strip()]
    polygons = [np.array(row[1:], float).reshape(-1, 2) for row in rows]
    boxes = np.array([[*p.min(0), *p.max(0)] for p in polygons], float).reshape(-1, 4)
    return np.array([int(row[0]) for row in rows], int), boxes, polygons


def mask_iou(raw, proto, anchor, box, polygon, geometry, size, threshold):
    """IoU between a detection's prototype mask, upsampled to the input, and its reference polygon."""
    import cv2
    import numpy as np
    scale, pad_x, pad_y, width, height = geometry
    input_width, input_height = dimensions(size)
    to_input = np.array([width * scale, height * scale]), np.array([pad_x, pad_y])
    logits = cv2.resize(np.tensordot(raw[4 + len(LABELS):, anchor], proto, 1).astype(np.float32),
                        (input_width, input_height), interpolation=cv2.INTER_LINEAR)
    x0, y0 = np.floor(box[:2] * to_input[0] + to_input[1]).astype(int)
    x1, y1 = np.ceil(box[2:] * to_input[0] + to_input[1]).astype(int)
    predicted = np.zeros((input_height, input_width), bool)
    predicted[y0:y1, x0:x1] = logits[y0:y1, x0:x1] >= np.log(threshold / (1 - threshold))
    reference = np.zeros((input_height, input_width), np.uint8)
    cv2.fillPoly(reference, [np.round((polygon * to_input[0] + to_input[1]) * 16).astype(np.int32)], 1, shift=4)
    union = (predicted | reference.astype(bool)).sum()
    return float((predicted & reference.astype(bool)).sum() / union) if union else 0.0


def core_ml_predictor(package: Path):
    """Run the exported package on every compute unit, as the app configures it."""
    import coremltools as ct
    from PIL import Image
    model = ct.models.MLModel(str(package.resolve()), compute_units=ct.ComputeUnit.ALL)
    name = next(i.name for i in model.get_spec().description.input if i.type.WhichOneof("Type") == "imageType")

    def predict(canvas):
        outputs = list(model.predict({name: Image.fromarray(canvas)}).values())
        raw = next(o for o in outputs if o.ndim == 3 and o.shape[1] == 4 + len(LABELS) + 32)
        proto = next(o for o in outputs if o.ndim == 4 and o.shape[1] == 32)
        return raw[0], proto[0]
    return predict


def rates(tally):
    tp, fp, fn = tally["tp"], tally["fp"], tally["fn"]
    return {"instances": tp + fn, "detections": tp + fp, "tp": tp, "fp": fp, "fn": fn,
            "precision": tp / (tp + fp) if tp + fp else None, "recall": tp / (tp + fn) if tp + fn else None}


def evaluate_split(predict, records, size, threshold, mask_threshold):
    """Score (matchID, image, label file) records per class and per match at the runtime threshold."""
    import cv2
    import numpy as np
    classes = range(len(LABELS))
    ranked, totals, frames = {c: [] for c in classes}, Counter(), Counter()
    counts, masks = {}, {c: [] for c in classes}
    missed, spurious = {c: Counter() for c in classes}, {c: Counter() for c in classes}
    for match_id, image_file, label_file in records:
        image = cv2.cvtColor(cv2.imread(str(image_file)), cv2.COLOR_BGR2RGB)
        canvas, scale, pad_x, pad_y = letterbox(image, size)
        geometry = (scale, pad_x, pad_y, image.shape[1], image.shape[0])
        raw, proto = predict(canvas)
        reference, reference_boxes, polygons = load_reference(label_file)
        totals.update(reference.tolist()); frames.update(set(reference.tolist()))
        labels, scores, boxes, _ = decode(raw, AP_FLOOR, len(LABELS), *geometry)
        for label, score, g in zip(labels, scores, match(labels, scores, boxes, reference, reference_boxes)):
            ranked[int(label)].append((float(score), g >= 0))
        labels, scores, boxes, anchors = decode(raw, threshold, len(LABELS), *geometry)
        assigned = match(labels, scores, boxes, reference, reference_boxes)
        for i, g in enumerate(assigned):
            c = int(labels[i])
            if g >= 0:
                counts.setdefault((match_id, c), Counter())["tp"] += 1
                masks[c].append(mask_iou(raw, proto, anchors[i], boxes[i], polygons[g], geometry, size, mask_threshold))
                continue
            counts.setdefault((match_id, c), Counter())["fp"] += 1
            overlaps = iou(boxes[i], reference_boxes)
            other = np.nonzero((overlaps >= MATCH_IOU) & (reference != c))[0]
            spurious[c]["duplicate" if ((overlaps >= MATCH_IOU) & (reference == c)).any()
                        else LABELS[reference[other[overlaps[other].argmax()]]] if len(other) else "background"] += 1
        matched = set(assigned.tolist())
        for g, c in enumerate(reference.tolist()):
            if g in matched:
                continue
            counts.setdefault((match_id, c), Counter())["fn"] += 1
            overlaps = iou(reference_boxes[g], boxes)
            other = np.nonzero((overlaps >= MATCH_IOU) & (labels != c))[0]
            missed[c][LABELS[labels[other[overlaps[other].argmax()]]] if len(other) else "undetected"] += 1
    per_class = {}
    for c, label in enumerate(LABELS):
        scores, hits = zip(*ranked[c]) if ranked[c] else ((), ())
        per_class[label] = {**rates(sum((t for (_, k), t in counts.items() if k == c), Counter())),
                            "frames": frames[c], "ap50": average_precision(scores, hits, totals[c]),
                            "maskIoU": float(np.mean(masks[c])) if masks[c] else None,
                            "missedAs": dict(missed[c]), "falsePositiveAs": dict(spurious[c])}
    matches = sorted({r[0] for r in records})
    per_match = {m: {LABELS[c]: rates(t) for (n, c), t in sorted(counts.items()) if n == m} for m in matches}
    return {"frames": len(records), "matches": matches, "perClass": per_class, "perMatch": per_match}


# Operating points: players favor precision (a false player draws fire), other classes balance both.
THRESHOLD_BETA = {"player": 0.5}
THRESHOLD_RANGE = {"player": (0.35, 0.8)}
DEFAULT_RANGE = (0.3, 0.7)


def calibrate_thresholds(predict, records, size):
    """Per-class detector thresholds that maximize F-beta on validation matches.

    Greedy class-aware NMS keeps the same detections above a threshold whether decoding starts
    there or at the AP floor, so one decode per frame serves every candidate threshold."""
    import cv2
    ranked, totals = {c: [] for c in range(len(LABELS))}, Counter()
    for _, image_file, label_file in records:
        image = cv2.cvtColor(cv2.imread(str(image_file)), cv2.COLOR_BGR2RGB)
        canvas, scale, pad_x, pad_y = letterbox(image, size)
        raw, _ = predict(canvas)
        reference, reference_boxes, _ = load_reference(label_file)
        totals.update(reference.tolist())
        labels, scores, boxes, _ = decode(raw, AP_FLOOR, len(LABELS), scale, pad_x, pad_y, image.shape[1], image.shape[0])
        for label, score, g in zip(labels, scores, match(labels, scores, boxes, reference, reference_boxes)):
            ranked[int(label)].append((float(score), g >= 0))
    thresholds, table = {}, {}
    for c, label in enumerate(LABELS):
        if not totals[c]:
            continue
        beta2 = THRESHOLD_BETA.get(label, 1.0) ** 2
        best, tp, fp = (0.0, None), 0, 0
        for score, hit in sorted(ranked[c], reverse=True):
            tp, fp = tp + hit, fp + (not hit)
            precision, recall = tp / (tp + fp), tp / totals[c]
            f = (1 + beta2) * precision * recall / (beta2 * precision + recall) if precision + recall else 0.0
            if f > best[0]:
                best = (f, score)
        if best[1] is None:
            continue
        lo, hi = THRESHOLD_RANGE.get(label, DEFAULT_RANGE)
        thresholds[label] = round(min(hi, max(lo, best[1])), 3)
        table[label] = {"instances": totals[c], "fBeta": round(best[0], 3), "threshold": thresholds[label]}
    return thresholds, table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path); parser.add_argument("dataset", type=Path)
    parser.add_argument("--acceptance", type=Path, help="Completed supervised acceptance record; no default pass")
    parser.add_argument("--calibrate-thresholds", action="store_true",
                        help="Choose per-class thresholds on the validation matches and store them in model.json")
    args = parser.parse_args()
    manifest = json.loads((args.artifacts / "model.json").read_text())
    model_path = args.artifacts / manifest["modelFile"]
    if tree_hash(model_path) != manifest["modelSHA256"]:
        raise SystemExit("Model checksum mismatch")
    if manifest["labels"] != LABELS:
        raise SystemExit("Model labels differ from the runtime taxonomy")
    root = args.dataset.parent
    split = json.loads((root / "split-report.json").read_text())
    test_matches = split["splits"]["test"]
    seen = {i for ids in manifest.get("trainedOn", {}).values() for i in ids}
    if seen & {m["matchID"] for m in test_matches}:
        raise SystemExit("A test match was used for training or checkpoint selection")
    exported = [json.loads(line) for line in (root / "exported-frames.jsonl").read_text().splitlines() if line]
    predict = core_ml_predictor(model_path)
    if args.calibrate_thresholds:
        records = [(f["matchID"], root / "images" / "val" / (f["file"] + Path(f["image"]).suffix),
                    root / "labels" / "val" / (f["file"] + ".txt")) for f in exported if f["split"] == "val"]
        thresholds, table = calibrate_thresholds(predict, records, input_shape(manifest))
        manifest["classThresholds"] = thresholds
        (args.artifacts / "model.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(table, indent=2))
        return
    results = {}
    for name in ("test", "val"):
        records = [(f["matchID"], root / "images" / name / (f["file"] + Path(f["image"]).suffix),
                    root / "labels" / name / (f["file"] + ".txt")) for f in exported if f["split"] == name]
        results[name] = evaluate_split(predict, records, input_shape(manifest), manifest["detectorThreshold"],
                                       manifest["maskThreshold"])
    per_class = results["test"]["perClass"]
    precision = min(m["precision"] or 0.0 for m in per_class.values())
    recall = min(m["recall"] or 0.0 for m in per_class.values())
    acceptance = json.loads(args.acceptance.read_text()) if args.acceptance else {}
    episodes = acceptance.get("episodes", [])
    forbidden = sum(e.get("forbiddenInteractions", 1) for e in episodes) if episodes else -1
    accepted = (acceptance.get("modelSHA256") == manifest["modelSHA256"]
                and len(episodes) >= 3 and {e.get("mode") for e in episodes} == MODES
                and all(e.get("passed") is True and e.get("recording") for e in episodes)
                and SCENARIOS.issubset(set(acceptance.get("testedScenarios", []))) and forbidden == 0)
    modes = sorted({m["mode"] for m in test_matches})
    report = dict(modelSHA256=manifest["modelSHA256"], scope=split.get("scope", "release"),
                  passed=set(modes) == MODES and precision >= .98 and recall >= .85 and accepted,
                  matches=len(test_matches), modes=modes, precision=precision, recall=recall,
                  forbiddenInteractions=forbidden, supervisedAcceptancePassed=accepted,
                  unmeasuredClasses=[label for label, m in per_class.items() if not m["instances"]],
                  operatingPoint=dict(detectorThreshold=manifest["detectorThreshold"], nmsIoU=NMS_IOU,
                                      maxDetections=MAX_DETECTIONS, matchIoU=MATCH_IOU,
                                      maskThreshold=manifest["maskThreshold"]),
                  datasetSplitReportSHA256=hashlib.sha256((root / "split-report.json").read_bytes()).hexdigest(),
                  frames=results["test"]["frames"], perClass=per_class, perMatch=results["test"]["perMatch"],
                  val={**results["val"], "note": "Selected the training checkpoint; not an untouched estimate"})
    (args.artifacts / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'class':14} {'inst':>5} {'det':>5} {'prec':>6} {'recall':>6} {'AP50':>6} {'maskIoU':>7}")
    show = lambda v: "     -" if v is None else f"{v:6.3f}"
    for label, m in per_class.items():
        print(f"{label:14} {m['instances']:5} {m['detections']:5} {show(m['precision'])} {show(m['recall'])} "
              f"{show(m['ap50'])} {show(m['maskIoU'])}")
    print(json.dumps({k: report[k] for k in ("scope", "passed", "matches", "modes", "precision", "recall",
                                             "unmeasuredClasses", "supervisedAcceptancePassed")}, indent=2))
    if not report["passed"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
