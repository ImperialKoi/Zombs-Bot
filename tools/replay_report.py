"""Create a local visual report from recorded images and replayed decisions."""
import argparse
import bisect
import json
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session",type=Path)
    parser.add_argument("decisions",type=Path)
    args=parser.parse_args()
    frames=[json.loads(line) for line in (args.session/"frames.jsonl").read_text().splitlines() if line]
    decisions=[json.loads(line) for line in args.decisions.read_text().splitlines() if line]
    times=[d["timestamp"] for d in decisions]
    observations=[json.loads(line) for line in (args.session/"observations.jsonl").read_text().splitlines() if line]
    observation_times=[o["timestamp"] for o in observations]
    rows=[]
    for frame in frames:
        image=(args.session/frame["image"]).resolve()
        if not image.is_relative_to(args.session.resolve()): raise ValueError("Image outside recording")
        di=bisect.bisect_right(times,frame["timestamp"])-1
        oi=bisect.bisect_right(observation_times,frame["timestamp"])-1
        rows.append(dict(image=frame["image"],timestamp=frame["timestamp"],decision=decisions[di] if di>=0 else None,observation=observations[oi] if oi>=0 else None))
    template=Path(__file__).with_name("replay_report.html").read_text()
    data=json.dumps(rows).replace("<","\\u003c")
    output=args.session/"replay.html"
    output.write_text(template.replace("__DATA__",data))
    print(output)


if __name__=="__main__":main()
