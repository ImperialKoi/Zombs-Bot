"""Import one match from a local video into the same format as the Mac recorder."""
import argparse
import json
import uuid
from pathlib import Path
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path); parser.add_argument("recordings", type=Path)
    parser.add_argument("--mode", choices=["solo", "duo", "squad"], required=True)
    parser.add_argument("--fps", type=float, default=5)
    parser.add_argument("--crop", type=float, nargs=4, metavar=("X", "Y", "WIDTH", "HEIGHT"), default=[0,0,1,1])
    args = parser.parse_args()
    if not 0 < args.fps <= 30: raise SystemExit("FPS must be between 0 and 30")
    x,y,w,h = args.crop
    if min(x,y) < 0 or min(w,h) <= 0 or x+w > 1 or y+h > 1: raise SystemExit("Crop must be a normalized viewport rectangle")
    import cv2
    cap = cv2.VideoCapture(str(args.video))
    if not cap.isOpened(): raise SystemExit("Cannot open local video")
    source_fps = cap.get(cv2.CAP_PROP_FPS)
    if source_fps <= 0: raise SystemExit("Cannot determine video frame rate")
    match_id = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S") + "-" + str(uuid.uuid4())[:6]
    output = args.recordings / match_id; (output / "images").mkdir(parents=True)
    (output / "session.json").write_text(json.dumps(dict(matchID=match_id, mode=args.mode, source="local-video", coordinateSystem="viewport-normalized-top-left"), indent=2))
    frame = 0; written = 0; next_time = 0
    try:
        with (output / "frames.jsonl").open("w") as rows:
            while True:
                ok, image = cap.read()
                if not ok: break
                timestamp = frame / source_fps; frame += 1
                if timestamp < next_time: continue
                ih,iw = image.shape[:2]
                image = image[int(y*ih):int((y+h)*ih),int(x*iw):int((x+w)*iw)]
                name = f"images/{written:06d}.jpg"
                if not cv2.imwrite(str(output/name),image,[cv2.IMWRITE_JPEG_QUALITY,95]): raise OSError("Image write failed")
                rows.write(json.dumps(dict(image=name,timestamp=timestamp,mode=args.mode,matchID=match_id,width=image.shape[1],height=image.shape[0]))+"\n")
                written += 1; next_time += 1/args.fps
    finally: cap.release()
    print(f"Imported {written} frames into {output}")


if __name__ == "__main__": main()
