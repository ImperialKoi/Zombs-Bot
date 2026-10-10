"""Audit reviewed scene coverage without changing the queue or whole-match splits.

Counts describe annotations, not the absence of objects in unreviewed footage.
Review metadata is an audit trail, not proof that a person/agent looked at an image.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from dataset import LABELS, load_sessions, planned_splits, validate_annotation


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bucket() -> dict:
    return {"queued": 0, "reviewed": 0, "pending": 0, "positiveFrames": 0,
            "negativeFrames": 0, "invalid": 0,
            "classes": {label: {"instances": 0, "frames": 0} for label in LABELS}}


def review_evidence(annotation: dict, image: Path) -> None:
    """Require source-bound review notes, with explicit evidence for negatives."""
    review = annotation.get("review", {})
    if not isinstance(review, dict):
        raise ValueError("Missing review record")
    for field in ("reviewer", "date", "method", "notes"):
        if not isinstance(review.get(field), str) or not review[field].strip():
            raise ValueError(f"Missing review {field}")
    if review.get("sceneObjectsReviewed") is not True:
        raise ValueError("Phase-only or incomplete scene review")
    if review.get("imageSHA256") != sha256(image):
        raise ValueError("Review does not match image bytes")
    negative = not annotation["objects"]
    if review.get("negative") is not negative:
        raise ValueError("Explicit negative assessment does not match objects")
    reason = review.get("negativeReason")
    if negative and (not isinstance(reason, str) or not reason.strip()):
        raise ValueError("Negative frames need an individual visual-review reason")


def audit_coverage(recordings: Path, queue: Path, split_plan: Path,
                   lock: Path | None = None) -> dict:
    sessions = load_sessions(recordings)
    plan = json.loads(split_plan.read_text())
    splits = planned_splits(sessions, plan, set(plan["modes"]))
    assignment = {s["matchID"]: name for name, group in splits.items() for s in group}
    lookup = {(s["matchID"], r["image"]): r for s in sessions for r in s["frames"]}
    requested = json.loads(queue.read_text())["frames"]
    keys = [(r["matchID"], r["image"]) for r in requested]
    if len(keys) != len(set(keys)) or any(k not in lookup for k in keys):
        raise ValueError("Queue has duplicate or missing frames")
    # Lock paths are resolved relative to the project root recorded by the caller's cwd.
    locked = json.loads(lock.read_text()) if lock else {}
    changed = [name for name, digest in locked.items()
               if not Path(name).is_file() or sha256(Path(name)) != digest]
    report = {"scope": "reviewed scene annotations only", "queueSHA256": sha256(queue),
              "splitPlanSHA256": sha256(split_plan),
              "inputLockChecked": lock is not None, "changedLockedFiles": changed,
              "totals": bucket(), "splits": {name: bucket() for name in splits},
              "matches": {s["matchID"]: {"split": assignment[s["matchID"]], **bucket()}
                          for s in sessions}, "issues": [], "pendingFrames": []}
    for key in keys:
        row = lookup[key]
        groups = [report["totals"], report["splits"][assignment[key[0]]], report["matches"][key[0]]]
        for group in groups:
            group["queued"] += 1
        path = row["annotation_path"]
        valid = False
        if path.exists():
            try:
                annotation = json.loads(path.read_text())
                validate_annotation(annotation)
                review_evidence(annotation, row["image_path"])
                valid = True
            except (ValueError, TypeError, AttributeError, KeyError, OSError) as error:
                report["issues"].append({"matchID": key[0], "image": key[1], "error": str(error)})
                for group in groups:
                    group["invalid"] += 1
        if not valid:
            report["pendingFrames"].append({"matchID": key[0], "image": key[1]})
            for group in groups:
                group["pending"] += 1
            continue
        labels = [obj["label"] for obj in annotation["objects"]]
        for group in groups:
            group["reviewed"] += 1
            group["positiveFrames" if labels else "negativeFrames"] += 1
            for label in labels:
                group["classes"][label]["instances"] += 1
            for label in set(labels):
                group["classes"][label]["frames"] += 1
    report["missingReviewedClassesBySplit"] = {
        name: [label for label, counts in stats["classes"].items() if not counts["instances"]]
        for name, stats in report["splits"].items()}
    report["queueComplete"] = bool(keys) and report["totals"]["pending"] == 0 and not changed
    report["allClassesRepresentedInEverySplit"] = not any(report["missingReviewedClassesBySplit"].values())
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recordings", type=Path)
    parser.add_argument("--queue", type=Path, required=True)
    parser.add_argument("--split-plan", type=Path, required=True)
    parser.add_argument("--input-lock", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = audit_coverage(args.recordings, args.queue, args.split_plan, args.input_lock)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"queued": result["totals"]["queued"], "reviewed": result["totals"]["reviewed"],
                      "pending": result["totals"]["pending"], "queueComplete": result["queueComplete"],
                      "changedLockedFiles": result["changedLockedFiles"], "report": str(args.output)}))
    raise SystemExit(0 if result["queueComplete"] else 2)
