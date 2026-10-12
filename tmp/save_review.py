"""Save a reviewed annotation for one queued frame through annotate.prepare_review.
Usage: .venv/bin/python tmp/save_review.py MATCHDIR FRAMESTEM '<json-of-objects>' [NOTES]
Reads objects from a JSON list (label/polygon). Writes annotations/<stem>.json atomically.
"""
import json, sys
from pathlib import Path
TOOLS = Path(__file__).resolve().parents[1] / 'tools' / 'training'
sys.path.insert(0, str(TOOLS))
import annotate

match_dir, stem = sys.argv[1], sys.argv[2]
objects = json.loads(sys.argv[3])
reviewer = 'codex-agent'
notes = sys.argv[4] if len(sys.argv) > 4 else 'Frame-specific notes pending.'
image = Path(match_dir) / 'images' / f'{stem}.jpg'
annotation = {'reviewed': True, 'objects': objects,
              'review': {'reviewer': reviewer, 'notes': notes, 'sceneObjectsReviewed': True,
                         'negative': not objects,
                         **({'negativeReason': notes} if not objects else {})}}
result = annotate.prepare_review(annotation, image)
out = Path(match_dir) / 'annotations' / f'{stem}.json'
tmp = out.with_suffix('.tmp')
tmp.write_text(json.dumps(result, indent=2) + '\n')
tmp.replace(out)
print('saved', out, 'objects', len(objects))
