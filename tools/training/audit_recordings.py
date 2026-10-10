"""Check saved recording files and make a reproducible, read-only corpus inventory."""
import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from PIL import Image
from dataset import load_sessions


def audit(root: Path) -> dict:
    sessions = load_sessions(root)
    hashes = defaultdict(list)
    reports = []
    for session in sessions:
        errors = []
        rows = session["frames"]
        times = [r["timestamp"] for r in rows]
        if any(b <= a for a, b in zip(times, times[1:])):
            errors.append("Frame timestamps are not strictly increasing")
        dimensions = set()
        for row in rows:
            path = row["image_path"]
            try:
                with Image.open(path) as image:
                    image.load()  # Detect corrupt/truncated JPEG data, not only header errors.
                    dimensions.add(image.size)
                    if image.size != (row["width"], row["height"]):
                        errors.append(f"Dimensions disagree: {row['image']}")
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                hashes[digest].append((session["matchID"], row["image"]))
            except (ValueError, OSError) as error:
                errors.append(f"{row['image']}: {error}")
        log_counts = {}
        for name in ["observations", "decisions"]:
            path = session["directory"] / (name + ".jsonl")
            entries = [json.loads(line) for line in path.read_text().splitlines() if line]
            log_counts[name] = len(entries)
        if log_counts["observations"] != log_counts["decisions"]:
            errors.append("Observation and decision counts differ")
        gaps = [b-a for a, b in zip(times, times[1:])]
        reports.append(dict(matchID=session["matchID"], mode=session["mode"], frames=len(rows),
                            durationSeconds=times[-1]-times[0] if len(times)>1 else 0,
                            maximumFrameGapSeconds=max(gaps, default=0), dimensions=sorted(dimensions),
                            reviewedFrames=sum(r["annotation_path"].exists() for r in rows),
                            logs=log_counts, errors=errors))
    cross_match_duplicates = [refs for refs in hashes.values() if len({r[0] for r in refs}) > 1]
    return dict(recordingsRoot=str(root.resolve()), sessions=reports,
                totalFrames=sum(r["frames"] for r in reports),
                uniqueImageHashes=len(hashes), crossMatchDuplicates=cross_match_duplicates,
                passed=all(not r["errors"] for r in reports) and not cross_match_duplicates)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recordings", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = audit(args.recordings)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"passed": result["passed"], "frames": result["totalFrames"],
                      "matches": len(result["sessions"]), "report": str(args.output)}))
    raise SystemExit(0 if result["passed"] else 2)
