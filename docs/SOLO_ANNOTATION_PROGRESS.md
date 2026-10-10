# Solo annotation progress — October 8, 2026

> **Next: [annotation round 2](ANNOTATION_ROUND2.md).** The nine listed drafts are now reviewed. Work from the 300-frame round-2 queue, which covers the new Duo/Squad footage and has model drafts and box-to-outline, instead of the dense remainder of this queue.

**The combined queue is incomplete: 135 of 2,084 frames reviewed;
1,949 pending.** This dated audit snapshot contains 3,506 instance polygons,
0 accepted negatives and 0 invalid annotations. The generated
[coverage report](../data/solo-pilot-v2/coverage-report.json) and its pending list are
the source of truth as parallel review continues. Queue selection, draft polygons,
phase reviews and rejected negative candidates do not count as approved scene reviews.

| Match suffix | Split | Queued | Reviewed | Pending |
| --- | --- | ---: | ---: | ---: |
| `78E1A3` | train | 900 | 38 | 862 |
| `B719C4` | val | 500 | 2 | 498 |
| `56F69F` | train | 100 | 5 | 95 |
| `E71586` | test | 500 | 6 | 494 |
| `090BC4` | train | 12 | 12 | 0 |
| `ABF049` | train | 12 | 12 | 0 |
| `7437EA` | train | 12 | 12 | 0 |
| `4DBB48` | val | 12 | 12 | 0 |
| `582E17` | test | 12 | 12 | 0 |
| `8B2504` | train | 12 | 12 | 0 |
| `21EE9A` | train | 12 | 12 | 0 |

| Class | Instances | Reviewed frames |
| --- | ---: | ---: |
| `self_player` | 116 | 116 |
| `player` | 75 | 47 |
| `ally_marker` | 0 | 0 |
| `enemy_marker` | 0 | 0 |
| `ground_item` | 482 | 108 |
| `door` | 217 | 65 |
| `chest` | 155 | 64 |
| `wall` | 390 | 77 |
| `rock` | 1056 | 133 |
| `tree` | 1015 | 117 |
| `revive_target` | 0 | 0 |

Each additional canonical approval follows individual full-frame inspection and
polygon-overlay inspection, with native-resolution crops for ambiguous boundaries.
Review metadata binds the annotation to the source JPEG by SHA-256. Evidence and
pending drafts are in [v2 review evidence](../data/solo-pilot-v2/review-evidence/).
A pending draft retains `reviewed: false` and `sceneObjectsReviewed: false` until its final
inspection; only canonical reviewed annotations under the recording's
`annotations/` directory contribute to coverage.

The user authorized parallel review and confirmed that obstacles block bullets
and break after several shots; actual structural walls block bullets and do not
break. [Class conventions](DATA_WORKFLOW.md#2-review-annotations-locally) preserve
vegetation as `tree`, other destructible cover as `rock`, and interactions as
`door`/`chest`. Visible interaction prompts confirmed square magma crates and
yellow Z boxes as `chest`. Roof artwork, glider/parachute effects, shadows, glows
and opaque HUD are excluded. HUD/foreground-split visible pieces of one object
remain one instance, with zero-width polygon bridges where necessary.

All 34 baseline/expanded locked inputs match the v2 lock. There is no reviewed
ally marker, enemy marker or revive target. No training/export or gameplay input
was enabled by this review work. User-confirmed blue wand/star boxes, green ammo-symbol boxes and wrapped presents
are breakable openable `chest` instances. The orange four-petal flower-emblem box
is breakable cover without interaction (`rock`). The affected saved annotations
and pending drafts use those confirmed labels.
October 8 confirmations: yellow X and red star-emblem boxes are `chest`; brown
skull-and-crossbones boxes are `rock`; blue skull-pattern rectangles are floor rugs
without collision and excluded. Affected saved rug instances are being corrected
with individual source/overlay rechecks.

The Python verification run passed 19 tests; 10 tests requiring optional ML/Pillow
dependencies were skipped in the system Python environment. The coverage audit
returned status 2 solely because the queue remains incomplete, with no changed
locked files or invalid canonical annotations in this snapshot.

The Pillow-enabled runtime also passed the three coverage and eight dataset tests.
A broader run exposed five ingest-pipeline failures/errors before frame extraction:
the subprocess `preexec_fn` that calls `os.nice(10)` failed in this execution
environment. Four ML evaluation tests remained skipped. Those ingest tests do not
validate the already-intaken annotation polygons; no ingest implementation was
changed during this review.

## Original October 4 review batch

The completed frames are `001196`, `001206`, `001216`, `001235`, and `001245` in
training match `2026-10-04T00-07-25Z-78E1A3`. They contain 53 instance polygons:

| Class | Instances | Frames |
| --- | ---: | ---: |
| self_player | 5 | 5 |
| ground_item | 16 | 5 |
| chest | 3 | 3 |
| rock | 29 | 5 |
| All other classes | 0 | 0 |

These neighboring frames cover chest/loot interaction ambiguity, chest occlusion,
the subsequent five-weapon loot cluster, clipped rocks, and objects partially
covered by the HUD. They are a small correlated batch, not adequate class coverage.
At that initial checkpoint, validation and test had zero completed scene annotations.

Each frame was individually inspected at 1920 × 868, with source-resolution center
crops and visual polygon-overlay checks. Camera-shifted candidate polygons were
corrected where previously occluded geometry became visible. Each saved annotation
contains a reviewer, source-image SHA-256, method, date, and notes. Original JPEGs
remain at 3840 × 1736. Coordinates are normalized against the original viewport.

The equipped weapon is included in the player's silhouette; ground weapon glow
rings, shadows, pickup messages, ejected casings, and inventory/minimap icons are
excluded. The two visible parts of the occluded chest in `001216` are one instance,
joined with a zero-width edge in the polygon representation.

Review overlays and source crops are in
[`data/solo-pilot/review-evidence/`](../data/solo-pilot/review-evidence/).
Drafts in `annotation-drafts/` are outside the export path and are not evidence of
completed review. The canonical reviewed files are the match's `annotations/` JSONs.

## Negative review

The final death-screen frame from **each of the four matches** was inspected
individually. All four were rejected as negatives: trees, rocks, players, dropped
items, or structures remain visible beneath the results overlay.

[`negative-review.jsonl`](../data/solo-pilot/negative-review.jsonl) records the image
hashes and individual rejection reasons. These are negative-candidate assessments,
not complete polygon reviews of those frames. **Accepted negative frames: 0.**
No phase label, absent annotation file, or empty object array is counted as a
reviewed negative merely because it exists.

The annotator now requires a reviewer, frame-specific notes, and an explicit
full-frame review confirmation. Empty annotations additionally retain a negative
reason. The server binds the review to the source image hash; the index verifies
the annotation and review record rather than counting files. These records support
an audit; they cannot prove that an annotator actually looked at the image.

## Coverage and frozen boundaries

[`coverage-report.json`](../data/solo-pilot/coverage-report.json) reports reviewed
instances and frame counts by class, split, and match, plus the complete pending
list. Zero counts indicate missing **reviewed annotations**, not proven absence
from the underlying footage. The existing contact sheets already show other
players and building/vegetation scenes; those still require polygons.

No ally marker, opponent-identifying UI marker, or revive target has been validated.
Do not turn an opponent's ordinary sprite into an `enemy_marker` label. Solo footage
cannot establish teammate/revive coverage; those need separate team-mode data.

The original queue, split plan, session manifests, and frame indexes were hashed
before annotation. All ten hashes still match
[`annotation-input-lock.json`](../data/solo-pilot/annotation-input-lock.json).
No match was resegmented, reassigned, duplicated, or merged.

Run from the project root:

```sh
python3 tools/training/scene_coverage.py data/solo-recordings \
  --queue data/solo-pilot/annotation-queue.json \
  --split-plan data/solo-pilot/split-plan.json \
  --input-lock data/solo-pilot/annotation-input-lock.json \
  --output data/solo-pilot/coverage-report.json
```

Exit status 2 means the queue is incomplete or a locked input changed. The coverage
audit requires source-bound scene review metadata; older polygon files without
that evidence remain pending for re-review. The dataset exporter itself retains
its existing format checks, so use the coverage audit before export.

## Original recording request (now supplied; no more requested yet)

Record **three additional complete Solo matches**, budgeting **15–25 minutes total**.
Match length varies; do not cut a match short to meet a duration target.

| Recording focus | Desired observations |
| --- | --- |
| Loot and interactions | Weapons/consumables beside doors and chests, crowded loot, a full inventory, a dropped weapon retrieved after a swap |
| Combat and occlusion | Close opponents, different skins, fighting around walls/rocks/trees, partially hidden and edge-clipped players |
| Healing and phase changes | Low health, starting and finishing a heal, a heal interrupted by damage, death and return to menu |

These are coverage targets, not requirements to force every case into one match.
Capture 10–15 seconds before joining and after returning to the menu, while keeping
one match per recording and the current viewport size. Review the resulting menu
frames individually: an empty-looking menu is not automatically a negative.

Once supplied, audit and add each recording intact. A separate additive split-plan
version can assign one new match to train, one to validation, and one to test while
preserving every existing assignment. Do not insert frames from one match into
multiple splits. Do not modify the frozen baseline files to hide the added scope.

For eventual all-mode coverage, the existing project requirement is at least three
complete Duo and three complete Squad matches, with positive teammate cues and
downed/revive interactions. They are a later collection step, not substitutes for
the missing Solo annotations.

## Verification

Ten Python tests pass, covering frozen match splits, polygon validation, coverage
counts, unreviewed/unsupported negative rejection, and stale image hashes. The
annotator JavaScript passes syntax checking. A live viewer check confirmed that
an empty frame cannot be saved without review identity, notes, and confirmation.
No detector was trained or exported and no gameplay input was enabled.
