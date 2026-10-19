"""Native-resolution crops of selected draft objects, numbered with label.
Usage: .venv/bin/python tmp/crops.py MATCHDIR STEM i j k ...
"""
import json, sys
from pathlib import Path
import cv2
import numpy as np

match_dir, stem = sys.argv[1], sys.argv[2]
idxs = [int(a) for a in sys.argv[3:]]
img = cv2.imread(str(Path(match_dir) / 'images' / f'{stem}.jpg'))
draft = json.load(open(str(Path(match_dir) / 'model-drafts' / f'{stem}.json')))
h, w = img.shape[:2]
for i in idxs:
    o = draft['objects'][i-1]
    pts = (np.array(o['polygon']) * [w, h]).astype(np.int32)
    cv2.polylines(img, [pts], True, (0, 0, 255), 2)
    x, y = pts.min(0)
    cv2.putText(img, f'{i}:{o["label"]}', (int(x), max(int(y), 20)), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0,0,0), 3)
    cv2.putText(img, f'{i}:{o["label"]}', (int(x), max(int(y), 20)), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255,255,255), 2)
    xs, ys = pts[:, 0], pts[:, 1]
    cx, cy = int(xs.mean()), int(ys.mean())
    pad = 260
    r = max(int(np.hypot(xs - cx, ys - cy).max() * 1.15 + pad), 320)
    x0, x1 = max(cx - r, 0), min(cx + r, w)
    y0, y1 = max(cy - r, 0), min(cy + r, h)
    crop = img[y0:y1, x0:x1]
    cv2.imwrite(f'/tmp/zr2/{stem}_o{i}.jpg', crop, [cv2.IMWRITE_JPEG_QUALITY, 88])
    print(f'{i} {o["label"]} centroid {pts[:,0].mean()/w:.3f},{pts[:,1].mean()/h:.3f} area_px {cv2.contourArea(pts):.0f}')
