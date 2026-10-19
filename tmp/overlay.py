"""Render a saved annotation overlay for verification.
Usage: .venv/bin/python tmp/overlay.py MATCHDIR STEM
"""
import json, sys
from pathlib import Path
import cv2
import numpy as np

match_dir, stem = sys.argv[1], sys.argv[2]
img = cv2.imread(str(Path(match_dir) / 'images' / f'{stem}.jpg'))
ann = json.load(open(str(Path(match_dir) / 'annotations' / f'{stem}.json')))
h, w = img.shape[:2]
colors = {'self_player': (255, 0, 255), 'player': (0, 0, 255), 'ally_marker': (0, 255, 0),
          'ground_item': (0, 230, 255), 'door': (255, 255, 0), 'chest': (0, 140, 255),
          'wall': (255, 90, 90), 'rock': (230, 170, 60), 'tree': (60, 200, 60)}
vis = img.copy()
counts = {}
for o in ann['objects']:
    pts = (np.array(o['polygon']) * [w, h]).astype(np.int32)
    c = colors.get(o['label'], (200, 200, 200))
    cv2.polylines(vis, [pts], True, c, 3)
    counts[o['label']] = counts.get(o['label'], 0) + 1
vs = cv2.resize(vis, (1600, round(h * 1600 / w)), interpolation=cv2.INTER_AREA)
half = np.split(vs, 2, axis=1)
for k, t in enumerate(half, 1):
    cv2.imwrite(f'/tmp/zr2/{stem}_v{k}.jpg', t, [cv2.IMWRITE_JPEG_QUALITY, 84])
print(counts)
