"""Outline objects from boxes with Segment Anything (SAM 2.1 tiny), for drafts and box-to-outline annotation.

    .venv/bin/python tools/training/outline.py FRAME.jpg --box X0 Y0 X1 Y1 [--box ...] [--overlay check.png]

Box coordinates are pixels of FRAME (or 0-1 with --normalized). Prints one JSON line per box:
{"box": [...], "polygon": [[x, y], ...]} with the polygon normalized to [0, 1], as annotations store it.
An outline is a starting point: inspect it against the frame before it goes into a reviewed annotation.

Needs the project .venv (ultralytics, torch). The 75 MB weights download to artifacts/weights/ on first use.
SAM fits most classes well (median IoU against reviewed polygons about 0.9 for trees, rocks and chests) but
not structural walls (a box around a wall band selects the whole building), so drafts keep the detector's
own wall masks.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEIGHTS = ROOT / "artifacts" / "weights" / "sam2.1_t.pt"
WORKING_WIDTH = 1920  # SAM resizes to 1024 anyway; outlining a half-size copy halves memory.


def mask_to_polygon(mask, epsilon: float = 1.0, keep: float = 0.02) -> list[list[float]] | None:
    """Largest region of a boolean mask as one polygon, in the mask's pixel coordinates.

    Smaller regions of at least `keep` of the largest area are joined to it with zero-width bridges, the
    convention reviewed annotations use for objects split by the HUD or foreground."""
    import cv2
    import numpy as np
    contours, _ = cv2.findContours(np.ascontiguousarray(mask, np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)
    if not contours or cv2.contourArea(contours[0]) < 4:
        return None
    largest = cv2.contourArea(contours[0])
    pieces = [c for c in contours if cv2.contourArea(c) >= max(4, keep * largest)]
    tolerance = epsilon
    while True:
        rings = [cv2.approxPolyDP(c, tolerance, True).reshape(-1, 2).tolist() for c in pieces]
        polygon = rings[0]
        for ring in rings[1:]:
            if len(ring) < 3:
                continue
            i, j = min(((i, j) for i in range(len(polygon)) for j in range(len(ring))),
                       key=lambda ij: (polygon[ij[0]][0] - ring[ij[1]][0]) ** 2 + (polygon[ij[0]][1] - ring[ij[1]][1]) ** 2)
            ring = ring[j:] + ring[:j]
            polygon = polygon[:i + 1] + ring + [ring[0], polygon[i]] + polygon[i + 1:]
        if len(polygon) <= 1500 or tolerance > 32:  # annotations allow at most 2000 points
            break
        tolerance *= 2
    return [[float(x), float(y)] for x, y in polygon] if len(polygon) >= 3 else None


def working_copy(image):
    """A copy at most WORKING_WIDTH wide, and the factor from its pixels back to the original's."""
    import cv2
    height, width = image.shape[:2]
    if width <= WORKING_WIDTH:
        return image, 1.0
    factor = WORKING_WIDTH / width
    return cv2.resize(image, (WORKING_WIDTH, round(height * factor)), interpolation=cv2.INTER_AREA), 1 / factor


class Outliner:
    """Encodes one frame once, then outlines any number of boxes in it (milliseconds each)."""

    def __init__(self, weights: Path = WEIGHTS, device: str = "cpu"):
        self.weights, self.device = Path(weights), device
        self.predictor = None
        self.size = None

    def _load(self):
        if self.predictor is None:
            from ultralytics.models.sam import SAM2Predictor
            from ultralytics.utils.downloads import attempt_download_asset
            if not self.weights.exists():
                self.weights.parent.mkdir(parents=True, exist_ok=True)
                downloaded = Path(attempt_download_asset(self.weights.name))
                downloaded.replace(self.weights)
            self.predictor = SAM2Predictor(overrides=dict(task="segment", mode="predict", imgsz=1024, model=str(self.weights),
                                                          device=self.device, save=False, verbose=False))

    def set_image(self, image) -> None:
        """Encode a BGR frame (as cv2 reads it). Boxes passed to outline() use this frame's pixel coordinates."""
        self._load()
        self.image, self.factor = working_copy(image)
        self.size = image.shape[1], image.shape[0]
        self.predictor.reset_image()
        self.predictor.set_image(self.image)

    def outline(self, boxes: list[list[float]]) -> list[list[list[float]] | None]:
        """One polygon per box (pixel coordinates of the frame given to set_image), or None where SAM found nothing."""
        if not boxes:
            return []
        scaled = [[v / self.factor for v in box] for box in boxes]
        result = self.predictor(bboxes=scaled)[0]
        masks = [] if result.masks is None else result.masks.data.cpu().numpy() > 0.5
        polygons = []
        for index in range(len(boxes)):
            polygon = mask_to_polygon(masks[index]) if index < len(masks) else None
            polygons.append(None if polygon is None else [[x * self.factor, y * self.factor] for x, y in polygon])
        return polygons


def normalized(polygon, width: int, height: int) -> list[list[float]]:
    return [[round(min(max(x / width, 0.0), 1.0), 7), round(min(max(y / height, 0.0), 1.0), 7)] for x, y in polygon]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path)
    parser.add_argument("--box", nargs=4, type=float, action="append", required=True, metavar=("X0", "Y0", "X1", "Y1"))
    parser.add_argument("--normalized", action="store_true", help="box coordinates are 0-1 instead of pixels")
    parser.add_argument("--overlay", type=Path, help="write a PNG with the outlines drawn on the frame")
    args = parser.parse_args()
    import cv2
    import numpy as np
    image = cv2.imread(str(args.image))
    if image is None:
        raise SystemExit(f"Cannot read {args.image}")
    height, width = image.shape[:2]
    boxes = [[b[0] * width, b[1] * height, b[2] * width, b[3] * height] if args.normalized else b for b in args.box]
    outliner = Outliner()
    outliner.set_image(image)
    polygons = outliner.outline(boxes)
    for box, polygon in zip(boxes, polygons):
        print(json.dumps({"box": [round(v, 1) for v in box], "polygon": normalized(polygon, width, height) if polygon else None}))
    if args.overlay:
        for box, polygon in zip(boxes, polygons):
            cv2.rectangle(image, (int(box[0]), int(box[1])), (int(box[2]), int(box[3])), (0, 200, 255), 2)
            if polygon:
                cv2.polylines(image, [np.round(np.array(polygon)).astype(np.int32)], True, (80, 230, 120), 2)
        cv2.imwrite(str(args.overlay), image)


if __name__ == "__main__":
    main()
