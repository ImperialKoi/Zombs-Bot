"""Offline bar-reading experiment for the fixed recorded HUD. Never sends input.

These are candidate measurements, not validated observations. An empty bar cannot
be distinguished from an absent HUD here; match/phase and HUD-presence guards are
required before any future runtime integration.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path
import numpy as np
from PIL import Image
from dataset import load_sessions

WIDTH, HEIGHT = 3840, 1736
LEFT, LENGTH = 58, 622
# Geometry and fill colors measured from the first new Solo match only.
BARS = {"health": ([1664,1666,1668], [122,194,50]),
        "shield": ([1593,1594,1595], [194,83,237])}


def measure_strip(strip, color):
    ends = []
    for line in strip:
        matches = np.max(np.abs(line.astype(np.int16)-np.array(color)), axis=1) <= 24
        found = np.flatnonzero(matches)
        if not len(found):
            ends.append(0)
            continue
        end = int(found[-1])+1
        if found[0] > 3 or np.count_nonzero(~matches[:end]) > 4:
            return None
        ends.append(end)
    if max(ends)-min(ends) > 3:
        return None
    return round(float(np.median(ends))/LENGTH*100, 2)


def measure(image):
    if image.size != (WIDTH,HEIGHT):
        raise ValueError("This experiment requires the recorded 3840 × 1736 viewport")
    # Crop before NumPy conversion; avoid copying a full frame for six scanlines.
    result = {}
    for name,(rows,color) in BARS.items():
        strips = np.stack([np.asarray(image.crop((LEFT,y,LEFT+LENGTH,y+1)).convert("RGB"))[0] for y in rows])
        result[name+"Candidate"] = measure_strip(strips,color)
    return result


def evaluate_reviewed(recordings, reviewed):
    """Compare against saved visual readings without changing the labels."""
    lookup = {(session["matchID"], row["image"]): row["image_path"]
              for session in load_sessions(recordings) for row in session["frames"]}
    samples = json.loads(reviewed.read_text())["samples"]
    errors, results = [], []
    rejected = 0
    for sample in samples:
        with Image.open(lookup[(sample["matchID"], sample["image"])]) as image:
            values = measure(image)
        for name in BARS:
            candidate = values[name+"Candidate"]
            if candidate is None:
                rejected += 1
            else:
                errors.append(abs(candidate-sample[name]))
        results.append(dict(matchID=sample["matchID"], image=sample["image"],
                            expected={name: sample[name] for name in BARS}, predicted=values))
    return dict(frames=len(samples), readings=len(samples)*len(BARS), rejected=rejected,
                maxAbsoluteError=max(errors, default=None),
                meanAbsoluteError=sum(errors)/len(errors) if errors else None,
                samples=results, releaseValidated=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recordings",type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--stride",type=int,default=5)
    parser.add_argument("--reviewed",type=Path,help="Saved manually read HUD values")
    parser.add_argument("--report",type=Path,help="Save timings, configuration, and optional spot check")
    args = parser.parse_args()
    if args.stride < 1: parser.error("stride must be positive")
    output=[]
    for session in load_sessions(args.recordings):
        for row in session["frames"][::args.stride]:
            with Image.open(row["image_path"]) as image:
                image.load()
                start=time.perf_counter(); values=measure(image); elapsed=time.perf_counter()-start
            output.append(dict(matchID=session["matchID"],image=row["image"],timestamp=row["timestamp"],
                               **values,processingMS=elapsed*1000,validated=False))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text("".join(json.dumps(row)+"\n" for row in output))
    timings=sorted(row["processingMS"] for row in output)
    report = dict(frames=len(output), stride=args.stride,
                  measurementP95MS=timings[int(.95*(len(timings)-1))] if timings else None,
                  excludesImageDecode=True, validated=False,
                  sourceSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  geometry=dict(width=WIDTH,height=HEIGHT,left=LEFT,length=LENGTH,bars=BARS))
    if args.reviewed:
        report["reviewedSource"] = str(args.reviewed)
        report["spotCheck"] = evaluate_reviewed(args.recordings,args.reviewed)
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({key:value for key,value in report.items() if key != "spotCheck"}))
