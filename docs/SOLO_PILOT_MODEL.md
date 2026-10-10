# Solo pilot detector — October 5, 2026

**A Solo pilot segmentation model was trained on Kaggle, exported to Core ML, and measured on
the two held-out test matches. It is not a release candidate and cannot pass the release gate.**
The gate needs held-out matches in all three modes, and Solo footage contains no ally markers,
enemy markers, or revive targets. The app loads this model but leaves it unvalidated, so gameplay
input stays disabled. The model has not been installed in the app.

## Data snapshot

Annotation was still in progress, so the pilot trained on a frozen snapshot rather than the live
annotation folders. At 11:24, `dataset.py --reviewed-snapshot` exported every frame with
source-bound review evidence: **56 of the 2,084 queued frames**. No annotation file was pending
or invalid. Whole-match assignments come from the frozen [v2 split plan](../data/solo-pilot-v2/split-plan.json).

| Split | Matches with reviewed frames | Frames | Instances |
| --- | ---: | ---: | ---: |
| Train | 5 of 7 (`ABF049` and `7437EA` not yet reviewed) | 35 | 795 |
| Validation | 2 | 11 | 247 |
| Test | 2 (`E71586`: 1 frame; `582E17`: 9 frames) | 10 | 203 |

Only training and validation frames were uploaded, to the private Kaggle dataset
`imperialkoi/zombs-dataset-solo-pilot-2026-10-05` (38 MB). Test frames never left this Mac.
`exported-frames.jsonl` records the image and annotation hash of every exported frame.

## Training and export

The private kernel `imperialkoi/zombs-train-solo-pilot-2026-10-05` (version 1) trained on a
Tesla T4 with torch 2.11.0 and ultralytics 8.4.173. It ran 100 epochs in 3.3 minutes.

- Recipe: YOLO11n-seg COCO weights (SHA-256 `55ed65c5…`, identical to the official download),
  960 px, batch 4, AdamW at 6.67e-4 chosen by ultralytics, no flips or mosaic, seed 42.
- `--nominal-batch 4` updated the model every batch. The default of 64 would have produced
  about 64 optimizer steps in total from 35 frames.
- Validation selected epoch 75: box mAP50 0.507 and mask mAP50 0.486 by ultralytics' own validator.

This Mac exported the checkpoint with torch 2.7.0 and coremltools 9.0. The FP16 package takes a
960 × 960 image and returns `[1, 47, 18900]` raw boxes and `[1, 32, 240, 240]` prototypes, the
layout `Detector.swift` decodes. Its tree hash, `fec9a594…`, matches the app's Swift `fileTreeHash`.
Artifacts are in `artifacts/solo-pilot-2026-10-05/`: `zombs.mlpackage`, `model.json`,
`training.json`, `validation.json`, `kaggle-run.json`, `environment.txt`, and the downloaded
kernel output and log.

## Held-out results

Test matches `E71586` and `582E17`, 10 frames. Detections are decoded as the app decodes them:
threshold 0.5, class-aware NMS at IoU 0.45, at most 100. A detection is correct at box IoU ≥0.5.

| Class | Instances | Detections | Precision | Recall | AP50 | Mask IoU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `self_player` | 10 | 9 | 0.889 | 0.800 | 0.802 | 0.834 |
| `player` | 1 | 3 | 0.000 | 0.000 | 0.111 | — |
| `ground_item` | 27 | 17 | 0.706 | 0.444 | 0.501 | 0.567 |
| `door` | 12 | 9 | 0.778 | 0.583 | 0.595 | 0.805 |
| `chest` | 4 | 3 | 0.667 | 0.500 | 0.558 | 0.781 |
| `wall` | 14 | 4 | 0.250 | 0.071 | 0.079 | 0.910 |
| `rock` | 39 | 33 | 0.606 | 0.513 | 0.551 | 0.882 |
| `tree` | 96 | 83 | 0.964 | 0.833 | 0.940 | 0.913 |
| `ally_marker`, `enemy_marker`, `revive_target` | 0 | 0 | — | — | — | — |

Mask IoU averages matched detections only. **Release gate: not passed.** The minimum precision and
recall over all eleven classes are both 0, against ≥0.98 and ≥0.85 required in all three modes.
`evaluate.py` exits 2, and the app reports "Model requires held-out evaluation across all three modes".

These figures carry large uncertainty. `player` has one test instance and `chest` four. Nine of the
ten test frames come from one match.

### Errors at the operating point

- **Players.** The one other player was labeled `self_player` (0.65), while the real self
  character was found at 0.85. Three rock regions were detected as `player`. In Solo, a false
  `player` is a potential target; the release precision floor exists to block this.
- **Walls.** Twelve of 14 wall bands were undetected; validation recall was also 0.
- **Ground items.** Fifteen of 27 were missed. False positives include floating damage numbers.
- **Rocks and trees.** Each was confused with the other: six trees were detected as rocks.
- **HUD.** One rock was detected on the minimap. Annotations exclude minimap icons, so runtime
  detections in HUD regions may need masking.

Validation matches, which selected the checkpoint, show the same pattern: tree AP50 0.871,
`self_player` 0.825, `ground_item` 0.656, `rock` 0.524, `player` 0.406, `chest` 0.387 (recall 0.18),
`door` 0.352, and `wall` 0.085 with no correct detections.

## Fidelity checks

- **The app's own detector.** The unmodified `Detector.swift`, built into a standalone harness, ran
  on the 10 test frames. All 159 of its detections paired with the evaluator's 161 (mean box IoU
  0.990, mean confidence difference 0.007). The evaluator's two extra detections were false
  positives just above the threshold. Scoring the app's output directly gives identical recall
  for every class and slightly higher precision for doors (0.875) and rocks (0.625).
- **Input scaling.** On a recorded frame, the evaluator's area resampling matches the app's Core
  Image letterbox to a mean of 0.45 of 255 levels, with identical padding and orientation.
- **Training resize.** Ultralytics trains on bilinear downscales, while the app's input is
  area-averaged. Evaluating with each made no consistent difference at this scale: most AP50 changes
  were within 0.03 in either direction. Recheck after annotation is complete.

## Reproduce

```sh
python3 tools/training/dataset.py data/solo-recordings-v2 data/dataset-solo-pilot-2026-10-05 \
  --modes solo --split-plan data/solo-pilot-v2/split-plan.json --reviewed-snapshot
.venv/bin/python tools/training/kaggle_train.py push \
  data/dataset-solo-pilot-2026-10-05/dataset.yaml artifacts/solo-pilot-2026-10-05 --nominal-batch 4
.venv/bin/python tools/training/kaggle_train.py pull \
  data/dataset-solo-pilot-2026-10-05/dataset.yaml artifacts/solo-pilot-2026-10-05 --wait
.venv/bin/python tools/training/evaluate.py artifacts/solo-pilot-2026-10-05 \
  data/dataset-solo-pilot-2026-10-05/dataset.yaml
```

The exporter refuses a nonempty folder, so a later snapshot needs a new name. GPU training is not
bit-for-bit reproducible; `training.json` records the checkpoint hash this report measured.

## Next steps

Retrain from a new snapshot as annotation progresses, prioritizing walls, other players, and
ground items. Consider masking HUD regions before detection. Duo and Squad footage remains
necessary for ally, enemy, and revive coverage and for any release gate.
