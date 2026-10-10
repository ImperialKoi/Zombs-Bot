"""Local polygon annotation UI for the app's recorded frames. No upload service.

A frame without an annotation opens its model draft (<match>/model-drafts/, from prelabel.py) as a starting point;
only a reviewed save writes annotations/. With the project .venv, dragging a box outlines the object with
Segment Anything (outline.py); under a plain Python the tool simply runs without it.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import secrets
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from dataset import LABELS, load_sessions, validate_annotation
from scene_coverage import review_evidence


def prepare_review(annotation: dict, image: Path) -> dict:
    """Bind an explicit UI review to the exact source image, including negatives."""
    # Drafts carry confidence and outline source per object; a saved annotation keeps only label and polygon.
    if isinstance(annotation.get("objects"), list):
        annotation = {**annotation, "objects": [{"label": o.get("label"), "polygon": o.get("polygon")} if isinstance(o, dict) else o
                                                for o in annotation["objects"]]}
    validate_annotation(annotation)
    review = annotation.get("review", {})
    if not isinstance(review, dict):
        raise ValueError("Missing review record")
    review = {**review, "date": datetime.now(timezone.utc).isoformat(),
              "imageSHA256": hashlib.sha256(image.read_bytes()).hexdigest(),
              "method": "Individual visual review in local polygon annotator"}
    result = {"reviewed": True, "objects": annotation["objects"], "review": review}
    review_evidence(result, image)
    return result


def is_reviewed(frame: dict) -> bool:
    try:
        data = json.loads(frame["annotation_path"].read_text())
        validate_annotation(data)
        review_evidence(data, frame["image_path"])
        return True
    except (OSError, ValueError, TypeError, AttributeError, KeyError):
        return False


def draft_path(frame: dict) -> Path:
    """<match>/model-drafts/<frame>.json, next to the match's annotations/ folder."""
    return frame["annotation_path"].parent.parent / "model-drafts" / frame["annotation_path"].name


def load_for_review(frame: dict) -> dict:
    """The saved annotation, else the model draft (marked as such), else an empty frame."""
    if frame["annotation_path"].exists():
        data = json.loads(frame["annotation_path"].read_text())
    elif draft_path(frame).exists():
        draft = json.loads(draft_path(frame).read_text())
        data = {"objects": draft.get("objects", []), "draft": draft.get("draft", {})}
    else:
        data = {"objects": []}
    data["reviewed"] = is_reviewed(frame)
    return data


class Outlines:
    """Box-to-outline with Segment Anything, loaded on first use; one request at a time."""
    available = importlib.util.find_spec("ultralytics") is not None

    def __init__(self):
        self.lock, self.outliner, self.current = threading.Lock(), None, None

    def outline(self, frame: dict, box: list[float]) -> list[list[float]] | None:
        import cv2
        from outline import Outliner, normalized
        with self.lock:
            if self.outliner is None:
                self.outliner = Outliner()
            image = None
            if self.current != frame["image_path"]:
                image = cv2.imread(str(frame["image_path"]))
                self.outliner.set_image(image)
                self.current = frame["image_path"]
            width, height = self.outliner.size
            polygon = self.outliner.outline([[box[0] * width, box[1] * height, box[2] * width, box[3] * height]])[0]
            return normalized(polygon, width, height) if polygon else None


def serve(root: Path, port: int, queue: Path | None = None) -> None:
    frames = [row for session in load_sessions(root) for row in session["frames"]]
    if queue:
        lookup = {(row["matchID"], row["image"]): row for row in frames}
        requested = json.loads(queue.read_text())["frames"]
        keys = [(row["matchID"], row["image"]) for row in requested]
        if len(keys) != len(set(keys)) or any(key not in lookup for key in keys):
            raise ValueError("Annotation queue contains duplicate or missing frames")
        frames = [lookup[key] for key in keys]
    if not frames:
        raise ValueError("No recorded frames. Record a match in ZombsAssistant first.")
    token = secrets.token_urlsafe(32)
    page = (Path(__file__).with_name("annotator.html")).read_text().replace("__TOKEN__", token)
    outlines = Outlines()

    class Handler(BaseHTTPRequestHandler):
        def send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            try:
                if path == "/":
                    self.send(200, page.encode(), "text/html; charset=utf-8")
                elif path == "/api/index":
                    self.send(200, json.dumps({"labels": LABELS, "outline": Outlines.available, "frames": [
                        {"id": i, "matchID": f["matchID"], "mode": f["mode"], "reviewed": is_reviewed(f),
                         "draft": not f["annotation_path"].exists() and draft_path(f).exists()} for i, f in enumerate(frames)]}).encode(), "application/json")
                elif path.startswith("/image/"):
                    index = int(path.removeprefix("/image/"))
                    if not 0 <= index < len(frames): raise ValueError("Invalid frame")
                    self.send(200, frames[index]["image_path"].read_bytes(), "image/jpeg")
                elif path.startswith("/annotation/"):
                    index = int(path.removeprefix("/annotation/"))
                    if not 0 <= index < len(frames): raise ValueError("Invalid frame")
                    self.send(200, json.dumps(load_for_review(frames[index])).encode(), "application/json")
                else:
                    self.send(404, b"Not found", "text/plain")
            except (ValueError, OSError) as error:
                self.send(400, str(error).encode(), "text/plain")

        def do_POST(self) -> None:
            if self.headers.get("X-Annotation-Token") != token:
                self.send(403, b"Invalid request token", "text/plain"); return
            try:
                path = urlparse(self.path).path
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 2_000_000: raise ValueError("Invalid annotation size")
                if path.startswith("/outline/"):
                    index = int(path.removeprefix("/outline/"))
                    if not 0 <= index < len(frames): raise ValueError("Invalid frame")
                    if not Outlines.available: raise ValueError("Box outlines need the project .venv (ultralytics)")
                    box = json.loads(self.rfile.read(length))["box"]
                    if len(box) != 4 or not all(isinstance(v, (int, float)) and 0 <= v <= 1 for v in box) or box[2] <= box[0] or box[3] <= box[1]:
                        raise ValueError("Invalid box")
                    polygon = outlines.outline(frames[index], box)
                    self.send(200, json.dumps({"polygon": polygon}).encode(), "application/json"); return
                if not path.startswith("/annotation/"): raise ValueError("Invalid endpoint")
                index = int(path.removeprefix("/annotation/"))
                if not 0 <= index < len(frames): raise ValueError("Invalid frame")
                annotation = prepare_review(json.loads(self.rfile.read(length)), frames[index]["image_path"])
                file = frames[index]["annotation_path"]; file.parent.mkdir(exist_ok=True)
                temporary = file.with_suffix(".tmp")
                temporary.write_text(json.dumps(annotation, indent=2) + "\n"); temporary.replace(file)
                self.send(200, b'{"saved":true}', "application/json")
            except (ValueError, OSError) as error:
                self.send(400, str(error).encode(), "text/plain")

    print(f"Review {len(frames)} frames at http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recordings", type=Path); parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--queue", type=Path, help="Optional curated frame list")
    args = parser.parse_args(); serve(args.recordings, args.port, args.queue)
