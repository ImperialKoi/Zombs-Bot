"""Render draft overlays (from model-drafts/<stem>.json) in numbered tiles.
Usage: .venv/bin/python tmp/draft_tiles.py MATCHDIR FRAMESTEM [scale]
"""
import json, sys
from pathlib import Path
import cv2
import numpy as np

match_dir, stem = sys.argv[1], sys.argv[2]
scale = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5

img = cv2.imread(str(Path(match_dir) / 'images' / f'{stem}.jpg'))
draft = json.load(open(str(Path(match_dir) / 'model-drafts' / f'{stem}.json')))
h, w = img.shape[:2]
colors = {'self_player': (255, 0, 255), 'player': (0, 0, 255), 'ally_marker': (0, 255, 0),
          'ground_item': (0, 230, 255), 'door': (255, 255, 0), 'chest': (0, 140, 255),
          'wall': (255, 90, 90), 'rock': (230, 170, 60), 'tree': (60, 200, 60)}
vis = img.copy()
for i, o in enumerate(draft['objects'], 1):
    pts = (np.array(o['polygon']) * [w, h]).astype(np.int32)
    c = colors.get(o['label'], (200, 200, 200))
    cv2.polylines(vis, [pts], True, c, 3)
    x, y = pts.min(0)
    cv2.putText(vis, str(i), (int(x), int(y) + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 2)
    cv2.putText(vis, str(i), (int(x), int(y) + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 1)
small_w = int(w * scale / 2)
vs = cv2.resize(vis, (small_w, round(h * small_w / w)), interpolation=cv2.INTER_AREA)
tiles = np.split(vs, 2, axis=1)
for k, t in enumerate(tiles, 1):
    cv2.imwrite(f'/tmp/zr2/{stem}_d{k}.jpg', t, [cv2.IMWRITE_JPEG_QUALITY, 84])
print(f'{len(draft["objects"])} draft objects')
