"""Render numbered overlays of saved annotations or full frames in readable tiles.
Usage: .venv/bin/python tmp/tiles.py MATCHDIR FRAMESTEM [--ann] [scale]
Writes /tmp/zr2/<stem>_t<k>.jpg tiles (half width each) with object numbers.
"""
import json, sys
from pathlib import Path
import cv2
import numpy as np

match_dir, stem = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
use_ann = '--ann' in args
args = [a for a in args if a != '--ann']
scale = float(args[0]) if args else 1.0

img_path = Path(match_dir) / 'images' / f'{stem}.jpg'
ann_path = Path(match_dir) / 'annotations' / f'{stem}.json'
img = cv2.imread(str(img_path))
h, w = img.shape[:2]
colors = {'self_player': (255, 0, 255), 'player': (0, 0, 255), 'ally_marker': (0, 255, 0),
          'enemy_marker': (0, 0, 160), 'ground_item': (0, 230, 255), 'door': (255, 255, 0),
          'chest': (0, 140, 255), 'wall': (255, 90, 90), 'rock': (230, 170, 60),
          'tree': (60, 200, 60), 'revive_target': (255, 255, 255)}
vis = img.copy()
n = 0
if use_ann and ann_path.exists():
    d = json.load(open(ann_path))
    for i, o in enumerate(d['objects'], 1):
        pts = (np.array(o['polygon']) * [w, h]).astype(np.int32)
        c = colors.get(o['label'], (200, 200, 200))
        cv2.polylines(vis, [pts], True, c, 3)
        x, y = pts.min(0)
        cv2.putText(vis, f"{i} {o['label']}", (int(x), max(28, int(y) - 6)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 2)
        cv2.putText(vis, f"{i} {o['label']}", (int(x), max(28, int(y) - 6)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 1)
        n += 1
small_w = int(w * scale / 2)
vis_s = cv2.resize(vis, (small_w, round(h * small_w / w)), interpolation=cv2.INTER_AREA)
tiles = np.split(vis_s, 2, axis=1)
for k, t in enumerate(tiles, 1):
    out = f'/tmp/zr2/{stem}_t{k}.jpg'
    if t.shape[1] * t.shape[0] > 3_400_000:
        t2 = cv2.resize(t, (1400, round(t.shape[0] * 1400 / t.shape[1])), interpolation=cv2.INTER_AREA)
        cv2.imwrite(out, t2, [cv2.IMWRITE_JPEG_QUALITY, 80])
    else:
        cv2.imwrite(out, t, [cv2.IMWRITE_JPEG_QUALITY, 84])
print(f'{n} objects, {len(tiles)} tiles')
