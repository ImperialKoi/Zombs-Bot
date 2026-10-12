"""Dataset utilities; the recording/annotation path uses only the standard library."""
from __future__ import annotations
import argparse
import hashlib
import json
import random
from pathlib import Path

LABELS = ["self_player", "player", "ally_marker", "enemy_marker", "ground_item",
          "door", "chest", "wall", "rock", "tree", "revive_target"]
MODES = {"solo", "duo", "squad"}


def load_sessions(root: Path) -> list[dict]:
    sessions = []
    for manifest in sorted(root.glob("*/session.json")):
        meta = json.loads(manifest.read_text())
        if meta.get("mode") not in MODES:
            raise ValueError(f"Invalid mode in {manifest}")
        rows = [json.loads(line) for line in (manifest.parent / "frames.jsonl").read_text().splitlines() if line]
        for row in rows:
            image = (manifest.parent / row["image"]).resolve()
            if not image.is_relative_to(manifest.parent.resolve()) or not image.is_file():
                raise ValueError(f"Invalid image path in {manifest}: {row['image']}")
            row["image_path"] = image
            row["annotation_path"] = manifest.parent / "annotations" / (image.stem + ".json")
        sessions.append({**meta, "directory": manifest.parent, "frames": rows})
    return sessions


def validate_annotation(data: dict) -> None:
    if not isinstance(data, dict) or data.get("reviewed") is not True:
        raise ValueError("An annotation must be explicitly reviewed, including empty negative frames")
    if not isinstance(data.get("objects"), list):
        raise ValueError("objects must be a list")
    for obj in data["objects"]:
        if obj.get("label") not in LABELS:
            raise ValueError("Unknown class")
        polygon = obj.get("polygon", [])
        if len(polygon) < 3 or len(polygon) > 2000:
            raise ValueError("Polygons need 3–2000 points")
        if any(not isinstance(p, list) or len(p) != 2 or any(type(v) not in (int, float) or not 0 <= v <= 1 for v in p) for p in polygon):
            raise ValueError("Coordinates must be finite and normalized to [0, 1]")
        area = abs(sum(a[0]*b[1] - b[0]*a[1] for a, b in zip(polygon, polygon[1:]+polygon[:1]))) / 2
        if area < 1e-7:
            raise ValueError("Polygon has no area")


def split_sessions(sessions: list[dict], seed: int = 42, modes=None) -> dict[str, list[dict]]:
    """Hold out complete matches, stratified by mode; never split adjacent frames."""
    splits = {"train": [], "val": [], "test": []}
    rng = random.Random(seed)
    modes = MODES if modes is None else set(modes)
    if not modes or not modes.issubset(MODES):
        raise ValueError("Choose known, nonempty modes")
    if len({s["matchID"] for s in sessions}) != len(sessions):
        raise ValueError("Duplicate match identifiers")
    for mode in sorted(modes):
        group = sorted([s for s in sessions if s["mode"] == mode], key=lambda s: s["matchID"])
        if len(group) < 3:
            raise ValueError(f"Need at least three separately recorded {mode} matches for train/val/test")
        rng.shuffle(group)
        held_out = max(1, round(len(group) * 0.15))
        if 2 * held_out >= len(group):
            held_out = 1
        splits["test"].extend(group[:held_out])
        splits["val"].extend(group[held_out:2*held_out])
        splits["train"].extend(group[2*held_out:])
    return splits


def planned_splits(sessions: list[dict], plan: dict, modes: set[str],
                   require_all: bool = True, every_mode_everywhere: bool = True) -> dict[str, list[dict]]:
    """Apply frozen assignments. require_all=False lets an interim pilot omit unreviewed matches;
    every_mode_everywhere=False lets it train on a mode that validation and test do not have yet."""
    if set(plan.get("modes", [])) != modes or set(plan.get("splits", {})) != {"train", "val", "test"}:
        raise ValueError("Split plan modes or split names do not match")
    ids = [i for group in plan["splits"].values() for i in group]
    lookup = {s["matchID"]: s for s in sessions}
    if len(ids) != len(set(ids)) or len(lookup) != len(sessions):
        raise ValueError("A match cannot appear in multiple splits")
    if set(lookup) - set(ids) or (require_all and set(ids) != set(lookup)):
        raise ValueError("Every planned match must have reviewed frames; no unplanned matches may be exported")
    result = {name: [lookup[i] for i in ids if i in lookup] for name, ids in plan["splits"].items()}
    if every_mode_everywhere and any({s["mode"] for s in group} != modes for group in result.values()):
        raise ValueError("Each split must cover every requested mode")
    if {s["mode"] for s in result["train"]} != modes or not all(result.values()):
        raise ValueError("Training must cover every requested mode, and every split needs reviewed frames")
    return result


def export_dataset(recordings: Path, output: Path, modes=None, split_plan: Path | None = None,
                   reviewed_snapshot: bool = False) -> dict:
    """A reviewed snapshot freezes an interim pilot while annotation continues: only frames whose
    review is bound to the source image are exported, other annotation files stay pending, and
    planned matches without reviewed frames are allowed. Each split still needs reviewed frames.
    A snapshot is always pilot scope, also across all three modes: only a full export is a release."""
    modes = MODES if modes is None else set(modes)
    if not modes or not modes.issubset(MODES):
        raise ValueError("Choose known, nonempty modes")
    if reviewed_snapshot and split_plan is None:
        raise ValueError("Reviewed snapshots need a frozen split plan; release exports need every planned match")
    from scene_coverage import review_evidence  # scene_coverage imports this module
    sessions = load_sessions(recordings)
    usable, pending = [], []
    for session in sessions:
        if session["mode"] not in modes:
            continue
        frames = []
        for row in session["frames"]:
            if not row["annotation_path"].exists():
                continue
            # Read once: a concurrent save cannot change the bytes between review check and export.
            raw = row["annotation_path"].read_bytes()
            try:
                annotation = json.loads(raw)
                validate_annotation(annotation)
                if reviewed_snapshot:
                    review_evidence(annotation, row["image_path"])
            except (ValueError, TypeError, AttributeError, KeyError) as error:
                if not reviewed_snapshot:
                    raise
                pending.append({"matchID": session["matchID"], "image": row["image"], "error": str(error)})
                continue
            frames.append((row, annotation, hashlib.sha256(raw).hexdigest()))
        if frames:
            usable.append({**session, "annotated": frames})
    plan = json.loads(split_plan.read_text()) if split_plan else None
    splits = (planned_splits(usable, plan, modes, require_all=not reviewed_snapshot, every_mode_everywhere=not reviewed_snapshot)
              if plan else split_sessions(usable, modes=modes))
    if output.exists() and any(output.iterdir()):
        raise ValueError("Choose an empty output directory to avoid stale split leakage")
    report = {"labels": LABELS, "modes": sorted(modes), "scope": "release" if modes == MODES and not reviewed_snapshot else "pilot",
              "reviewedSnapshot": reviewed_snapshot, "splits": {}, "frames": 0,
              "classInstances": {label: 0 for label in LABELS}}
    if plan:
        report["splitPlanSHA256"] = hashlib.sha256(split_plan.read_bytes()).hexdigest()
    if reviewed_snapshot:
        exported = {s["matchID"] for s in usable}
        report["unreviewedPlannedMatches"] = {name: [i for i in ids if i not in exported] for name, ids in plan["splits"].items()}
        report["modesMissingFromSplits"] = {name: sorted(modes - {s["mode"] for s in group}) for name, group in splits.items()
                                            if modes - {s["mode"] for s in group}}
        report["pendingAnnotationFiles"] = pending
    manifest = []
    for name, group in splits.items():
        image_dir, label_dir = output / "images" / name, output / "labels" / name
        image_dir.mkdir(parents=True, exist_ok=True)
        label_dir.mkdir(parents=True, exist_ok=True)
        report["splits"][name] = [{"matchID": s["matchID"], "mode": s["mode"], "frames": len(s["annotated"])} for s in group]
        for session in group:
            for row, annotation, digest in session["annotated"]:
                name_hash = hashlib.sha256(f"{session['matchID']}/{row['image']}".encode()).hexdigest()[:24]
                image = row["image_path"].read_bytes()
                (image_dir / (name_hash + row["image_path"].suffix)).write_bytes(image)
                lines = []
                for obj in annotation["objects"]:
                    report["classInstances"][obj["label"]] += 1
                    points = " ".join(f"{v:.7f}" for point in obj["polygon"] for v in point)
                    lines.append(f"{LABELS.index(obj['label'])} {points}")
                (label_dir / (name_hash + ".txt")).write_text("\n".join(lines) + ("\n" if lines else ""))
                manifest.append({"split": name, "matchID": session["matchID"], "mode": session["mode"],
                                 "image": row["image"], "file": name_hash, "objects": len(lines),
                                 "imageSHA256": hashlib.sha256(image).hexdigest(), "annotationSHA256": digest})
                report["frames"] += 1
    # JSON strings are legal YAML scalars; no PyYAML dependency needed for data preparation.
    yaml = f"path: {json.dumps(str(output.resolve()))}\ntrain: images/train\nval: images/val\ntest: images/test\nnames:\n"
    yaml += "".join(f"  {i}: {json.dumps(label)}\n" for i, label in enumerate(LABELS))
    (output / "dataset.yaml").write_text(yaml)
    manifest_text = "".join(json.dumps(entry) + "\n" for entry in manifest)
    (output / "exported-frames.jsonl").write_text(manifest_text)
    report["exportedFramesSHA256"] = hashlib.sha256(manifest_text.encode()).hexdigest()
    (output / "split-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def tree_hash(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")) if path.is_dir() else [path]:
        if not file.is_file():
            continue
        name = file.relative_to(path).as_posix() if path.is_dir() else file.name
        digest.update(name.encode()); digest.update(b"\0"); digest.update(file.read_bytes())
    return digest.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Export reviewed polygons, splitting by complete match and mode")
    parser.add_argument("recordings", type=Path); parser.add_argument("output", type=Path)
    parser.add_argument("--modes", nargs="+", choices=sorted(MODES), default=sorted(MODES),
                        help="Restrict an offline pilot to available modes; live acceptance still requires all modes")
    parser.add_argument("--split-plan", type=Path, help="Freeze whole-match assignments before annotation/training")
    parser.add_argument("--reviewed-snapshot", action="store_true",
                        help="Interim pilot: export only source-bound reviewed frames while annotation continues")
    args = parser.parse_args()
    report = export_dataset(args.recordings, args.output, args.modes, args.split_plan, args.reviewed_snapshot)
    print(json.dumps({k: v for k, v in report.items() if k != "pendingAnnotationFiles"}, indent=2))
