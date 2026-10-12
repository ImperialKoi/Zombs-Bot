# Annotation round 2 — October 7, 2026

> **Superseded on 2026-10-12** by the [annotations guide](ANNOTATIONS_GUIDE.md) and the full-pass queue (`data/recorder-corpus/full-pass-queue.json`). The tools described below are unchanged.

Round 2 adds the ZombsRecorder footage, model drafts and box-to-outline, and replaces the dense Solo pilot queue as the working queue. Train the next model on Kaggle once round 2 is done.

## Review checkpoint — October 8, 2026

All nine drafts listed in the historical October 7 handoff below are now individually reviewed and saved. Supplemental Solo anchors are also complete. The original pilot audit now has 135 reviewed frames and 3,506 polygons; its locked inputs remain unchanged. Dense pilot review has stopped in favor of the frozen round-2 queue.

The round-2 audit currently has **9 of 300 frames reviewed**, **291 pending**, and **0 invalid annotations**. This is an in-progress snapshot; reviewers are working in parallel on train, validation, and test. Test frames are annotated from scratch. Each approval follows full-source, native-crop where needed, and final-overlay inspection.

Confirmed label refinements: yellow X and red star boxes are `chest`; brown skull-and-crossbones boxes are `rock`; blue skull-pattern rugs have no collision and are excluded. Earlier saved rug instances have been corrected after individual source and overlay rechecks.

## Where the Solo review stopped

[Solo pilot queue](../data/solo-pilot-v2/annotation-queue.json), 17:00 on October 7:

- **Reviewed:** 102 of 2,084 frames: 76 train, 13 validation, 13 test. All locked inputs are unchanged.
- **Drafted but not yet approved:** nine frames, in `data/solo-pilot-v2/review-evidence/`. Each is a complete draft waiting for its final full-frame check. **Finish these first.**

| Worker folder | Draft frames |
| --- | --- |
| `current-review` | `78E1A3`: `001075`, `001095`, `001105`, `001125`, `001135` |
| `new-training-agent` | `21EE9A`: `008870`, `010798` |
| `test-agent` | `7437EA`: `001070` |
| `validation-agent` | `ABF049`: `001286` |

The remaining 1,982 frames in that queue are consecutive frames 0.2–0.4 s apart: 984 train, 499 validation and 499 test. Each adds little beyond its neighbors. Round 2 samples all recordings instead. The frozen pilot files stay valid for their own coverage audit. A review saved for either queue lands in the same session folder, because the round-2 corpus links those folders, so every review is exported for training either way.

## New footage and the round-2 corpus

[`data/recorder-corpus`](../data/recorder-corpus) holds:
- the 11 Solo matches, as links with their annotations and frozen splits;
- 22 ZombsRecorder matches, about 57.5 minutes and 17,266 frames at 5 FPS. Jeremy D recorded 13 and Daniel Xu 9.

| Mode | Train | Validation | Test |
| --- | ---: | ---: | ---: |
| Duo | 26.0 min (8 recordings) | 4.0 min (1) | 4.7 min (1) |
| Squad | 6.5 min (3) | 3.4 min (2) | 1.4 min (2) |
| Solo | 3.8 min (2) + 7 pilot matches | 3.4 min (2) + 2 pilot | 4.4 min (1) + 2 pilot |

**Split rule.** Splits are whole matches, assigned from metadata before review and never moved (`split-assignments.json`). Recordings that overlap in time are teammates' views of one game and share a split. There are six such pairs, including `F91B95` with `BF3056`.

## The round-2 queue

[`round-2-queue.json`](../data/recorder-corpus/round-2-queue.json) holds 300 frames from `select_frames.py`:

- **Splits:** 210 train, 45 validation and 45 test.
- **Modes:** 141 Duo, 64 Squad and 95 Solo.
- **Coverage:** every recording.
- **Spacing:** every frame is at least 2 s from any reviewed or in-progress frame of its recording, including the nine drafts above.
- **How frames were chosen:**
  - Training frames are the ones the interim model was least sure about, or that showed the classes with the fewest reviewed instances, one per time slice.
  - Validation and test frames are evenly spaced, so they stay representative.
- **Order:** splits are interleaved, so a round stopped partway is still balanced.

## Model drafts

The 255 training and validation frames have drafts in `<match>/model-drafts/<frame>.json`, marked `reviewed: false`.

- **How they were made:** the interim detector `artifacts/solo-pilot-2026-10-07` found the objects. It was trained on Kaggle from the 102 reviewed frames and scores box mAP50 0.50 on validation. SAM 2.1-tiny then outlined each object; walls keep the detector's own mask.
- **Test frames have no drafts.** Label them from scratch, so held-out labels are not anchored to model output.

**A draft is not a review.** Only a reviewed save writes the canonical `annotations/<frame>.json`. The coverage audit and dataset export ignore drafts.

Measured on the 13 reviewed validation frames (which also selected the model's checkpoint, so these numbers are optimistic):

| Class | Reviewed objects | Found by drafts | Outline IoU when found |
| --- | ---: | ---: | ---: |
| `self_player` | 11 | 91% | 0.86 |
| `tree` | 72 | 82% | 0.91 |
| `rock` | 115 | 54% | 0.91 |
| `door` | 22 | 50% | 0.86 |
| `chest` | 36 | 47% | 0.93 |
| `ground_item` | 42 | 45% | 0.65 |
| `player` | 5 | 2 | 0.88 |
| `wall` | 36 | 14% | 0.70 |

**What to expect per frame:**
- About 10 wrong objects to delete, mostly false `player` and `wall` drafts.
- About 12 missing objects to add.

The model never saw `ally_marker`, `enemy_marker` or `revive_target`, so Duo/Squad drafts contain none. Look for them in every team-mode frame. As before, label a marker only where the UI positively identifies it; never turn an ordinary player sprite into an `enemy_marker`.

## Tools

### Browser annotation

```sh
.venv/bin/python tools/training/annotate.py data/recorder-corpus --queue data/recorder-corpus/round-2-queue.json
```

- A frame without an annotation opens its draft in orange, with each object's confidence. Click an object in the list to delete it.
- Press **B** for box-to-outline: drag a box around one object and Segment Anything outlines it in about 0.1 s. Encoding the frame takes about 1 s the first time. Check every outline's edges.
- Saving needs the same reviewer, notes and full-frame confirmation as before. It keeps only `label` and `polygon`, and binds the review to the image's SHA-256.
- Under the system `python3`, the annotator runs without box-to-outline.

### Outlines from the command line (for agents)

```sh
.venv/bin/python tools/training/outline.py FRAME.jpg --box X0 Y0 X1 Y1 [--box ...] [--overlay check.png]
```

- Prints one JSON line per box, with a polygon in the normalized annotation coordinates. Boxes are in pixels, or 0–1 with `--normalized`.
- It is a drop-in replacement for dark-outline tracing.
- Median agreement with reviewed polygons is about 0.9 for trees, rocks and chests. It is weaker for small ground items (~0.6–0.7) and structural walls, where a box selects the whole building; draw walls by hand.
- Inspect each overlay before saving.

An agent can start from `model-drafts/<frame>.json`, correct the objects, and save through `annotate.prepare_review`. That keeps the canonical format and the source-bound review evidence.

### Progress

```sh
python3 tools/training/scene_coverage.py data/recorder-corpus --queue data/recorder-corpus/round-2-queue.json \
  --split-plan data/recorder-corpus/split-plan.json --output data/recorder-corpus/coverage-round-2.json
```

## After round 2: retrain, then pick round 3

```sh
.venv/bin/python tools/training/ingest_recordings.py plan data/recorder-corpus --modes solo duo squad -o data/recorder-corpus/plan-all.json
python3 tools/training/dataset.py data/recorder-corpus data/dataset-round-2-<date> --modes solo duo squad \
  --split-plan data/recorder-corpus/plan-all.json --reviewed-snapshot
.venv/bin/python tools/training/kaggle_train.py push data/dataset-round-2-<date>/dataset.yaml artifacts/round-2-<date> --nominal-batch 4
.venv/bin/python tools/training/kaggle_train.py pull data/dataset-round-2-<date>/dataset.yaml artifacts/round-2-<date> --wait
.venv/bin/python tools/training/select_frames.py data/recorder-corpus --count 300 --model artifacts/round-2-<date> \
  --evidence data/solo-pilot-v2/review-evidence -o data/recorder-corpus/round-3-queue.json
.venv/bin/python tools/training/prelabel.py data/recorder-corpus artifacts/round-2-<date> --queue data/recorder-corpus/round-3-queue.json
```

- **Snapshots are always pilot scope.** A reviewed snapshot is now allowed across all three modes, but it never passes the release gate. A release export still needs every planned match.
- **Training runs only on Kaggle.** Test frames never leave the Mac.

## Videos

`ingest_recordings.py pull` now deletes each downloaded video once its frames are extracted, unless `--keep-video` is passed.

The extracted frames are all annotation and training need. The original videos remain only in the private `zombs-rec-*` Kaggle datasets, which allow denser re-extraction later, for example consecutive frames for motion tracks.
