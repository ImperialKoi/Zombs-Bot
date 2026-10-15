# Data, calibration, and acceptance

## 1. Capture real matches

Use the app recorder or import one local video per match. Match mode and boundaries must be accurate. Include menu/death frames, empty ground, doors beside loot, crowded loot, interrupted healing, multiple skins, and teammates crossing firing paths. Keep the game viewport at a consistent aspect ratio; the app stops on window resize.

The Python recording importer needs OpenCV, installed with the ML requirements below:

```sh
python tools/training/import_video.py match.mp4 ./data/recordings --mode squad \
  --crop 0 0 1 1
```

Crop coordinates are normalized `x y width height`. Import recordings you already have locally.

To collect matches from several Macs, use [Zombs Recorder](../ZombsRecorder/README.md). It is a recording-only menu-bar app; friends install it from a kit that has your setup code built in. Pressing **=** in the game starts and stops each match, and the app records the game area as hardware-encoded video. Each finished match is uploaded to your Kaggle account as a private `zombs-rec-*` dataset, and uploads pause while a match is being recorded. On this Mac, `ingest_recordings.py pull` does the rest:

- downloads new matches, or reads this Mac's own recordings;
- verifies their hashes;
- extracts 5 FPS frames in the session format below;
- runs the recording audit;
- freezes each whole match into train, val or test;
- appends frames to an annotation queue.

See its [README](../ZombsRecorder/README.md#ingest-annotate-and-train-on-your-mac) for the commands.

Cloud transfers happen in only three places:

- `kaggle_train.py push` uploads training and validation frames to a private Kaggle dataset.
- Zombs Recorder uploads match videos to private datasets.
- `ingest_recordings.py` downloads and, with `--delete-remote`, deletes those datasets.

None of the other tools download or upload media.

## 2. Review annotations locally

**Annotators: follow the [annotations guide](ANNOTATIONS_GUIDE.md).** It holds the class rules below plus every later confirmation, the workflow and the review cadence.

The annotation server requires only Python's standard library:

```sh
python3 tools/training/annotate.py \
  "$HOME/Library/Application Support/ZombsAssistant/recordings"
```

Open the printed localhost URL. Click polygon vertices, choose a class, press Enter, and save the reviewed frame. With the project `.venv`, frames can open with model drafts and **B** turns a dragged box into a Segment Anything outline. [Annotation round 2](ANNOTATION_ROUND2.md) describes drafts (`prelabel.py`), round selection (`select_frames.py`) and command-line outlines (`outline.py`). Enter your reviewer identifier and frame-specific notes, then confirm that you inspected the entire frame. For an empty frame, explain why no target-class world objects are visible; the reason and source image hash are saved with the review. Mark empty frames reviewed only after that inspection. Label every visible instance; missing labels become false-negative training examples. Clicking an object in the list removes it.

For the prepared Solo corpus, use the curated queue:

```sh
python3 tools/training/annotate.py data/solo-recordings \
  --queue data/solo-pilot/annotation-queue.json
```

The [original Solo intake report](SOLO_INTAKE.md) records the baseline. The [v2 intake](SOLO_INTAKE_V2.md) adds seven whole matches and documents the expanded queue, split plan, and exact completion status. Phase-only reviews and numeric HUD readings are separate from reviewed scene polygons.

Classes:

| Class | Meaning |
| --- | --- |
| `self_player` | Your visible character, excluding shadows |
| `player` | Another character, regardless of team |
| `ally_marker` | A visible UI marker positively identifying an ally |
| `enemy_marker` | A visible UI marker positively identifying an opponent |
| `ground_item` | A reachable or distant ground item; pickups are identified from the interaction prompt |
| `door`, `chest` | Interactions the bot must avoid, including open-door structures |
| `wall`, `rock`, `tree` | Solid projectile-blocking shapes; outline occupied geometry |
| `revive_target` | A downed teammate/interaction region competing for E |

Small light-green bushes belong to `tree` (the current foliage class), and round
blue/pink-centered Mystic Forest stone objects belong to `rock`. The user confirmed
both block bullets. Preserve those polygons even though combat is allowed to fire
toward confirmed enemies behind foliage and rocks.

The user subsequently confirmed that all solid obstacles block bullets and break
after several shots, except actual structural walls, which block bullets and do
not break. Under the current class set, vegetation remains `tree`; destructible
nonvegetation cover uses `rock`, including circus tents, rope fences, silver
pedestals, colored circular pads, benches, furniture and solid window props.
Keep `door` and `chest` for interaction objects. A square magma crate is `chest`
when the nearby HUD identifies it as “Crate (Magma)”; yellow Z boxes are confirmed
by “Gold Chest” prompts. Do not classify an interaction crate as cover just
because it is destructible. Roof artwork is excluded; outline visible occupied
structural wall bands and separate exposed props. Clip opaque HUD and foreground
occlusion out of all instance polygons.

On October 7, the user confirmed that blue wand/star boxes, green ammo-symbol
boxes and wrapped presents are openable like chests and breakable: use `chest`.
The large orange box with a four-petal flower emblem is breakable with no
interaction: use `rock`. Loose ammunition piles remain `ground_item`; do not
confuse their icons with the boxed ammo container.

On October 8, the user confirmed yellow X boxes and red star-emblem boxes open
like chests (`chest`). Brown skull-and-crossbones boxes are breakable obstacles
without interaction (`rock`). Large blue skull-pattern rectangles inside buildings
are floor rugs with no collision; exclude them from target object polygons.

Do not invent enemy markers when the footage does not contain a distinguishing cue. If reliable enemy affiliation cannot be established in a mode, that mode remains unable to fire until the perception design is updated and tested against the recordings. Positive team cues and HUD behavior are data-dependent feasibility requirements.

## 3. Export whole-match splits

```sh
python3 tools/training/dataset.py \
  "$HOME/Library/Application Support/ZombsAssistant/recordings" ./data/dataset-v1
```

The exporter requires at least three annotated matches in each mode and uses deterministic, mode-stratified splits. It refuses nonempty output folders to avoid stale images leaking between splits. `split-report.json` records match membership, and `exported-frames.jsonl` records the image and annotation SHA-256 of every exported frame. Release training additionally requires at least 2,000 reviewed frames.

After scene annotation, export the Solo pilot using its frozen whole-match assignments:

```sh
python3 tools/training/dataset.py data/solo-recordings-v2 data/dataset-solo-v1 \
  --modes solo --split-plan data/solo-pilot-v2/split-plan.json
```

This restricted export is marked `pilot`. It does not relax runtime validation or the all-mode release requirements. Scene annotation remains incomplete; the [progress report](SOLO_ANNOTATION_PROGRESS.md) and generated coverage report record the current counts. Run the [scene coverage audit](SOLO_ANNOTATION_PROGRESS.md#coverage-and-frozen-boundaries) before export; it checks source-bound review evidence and frozen inputs in addition to polygon format.

While annotation continues, `--reviewed-snapshot` freezes an interim pilot instead:

```sh
python3 tools/training/dataset.py data/solo-recordings-v2 data/dataset-solo-pilot-2026-10-05 \
  --modes solo --split-plan data/solo-pilot-v2/split-plan.json --reviewed-snapshot
```

A snapshot exports only frames whose review is bound to the source image, which is how the coverage audit counts reviewed frames, and lists other annotation files as pending. Planned matches without reviewed frames are listed rather than rejected; each split must still contain reviewed frames. Because the exported files and hashes are copies, later annotation saves cannot change a trained snapshot. A snapshot is always pilot scope, also when it covers all three modes, so it can train interim models (such as draft generators) but never passes the release gate.

## 4. Train on Kaggle and export

Training runs on a Kaggle GPU, not on this Mac. This Mac exports the dataset, uploads the training and validation frames, downloads the trained checkpoint, and converts it to Core ML. Use Python 3.11 or 3.12 in a virtual environment for these development tools; the packaged Mac app uses Core ML directly.

```sh
python3.12 -m venv .venv
.venv/bin/pip install -r tools/training/requirements.txt
.venv/bin/kaggle auth login
```

`kaggle auth login` signs in through the browser. Alternatively, generate a token at kaggle.com/settings/api and save it to `~/.kaggle/access_token`. Kernels need a phone-verified Kaggle account for GPU and internet access.

```sh
.venv/bin/python tools/training/kaggle_train.py push data/dataset-v1/dataset.yaml artifacts/candidate-v1
.venv/bin/python tools/training/kaggle_train.py pull data/dataset-v1/dataset.yaml artifacts/candidate-v1 --wait
```

`push` zips the training and validation images and labels, the split report, `train.py`, and `dataset.py` into a **private** Kaggle dataset, then starts a private kernel on a T4 GPU (`--accelerator`). Test frames are never uploaded. The kernel installs the same ultralytics version as this Mac and runs `train.fit()`. `kaggle-run.json` records the dataset, kernel, and settings. `pull` waits for the kernel, downloads its output, and exports Core ML here with `train.py --weights`. The export refuses a checkpoint whose `training.json` does not match this dataset export or the checkpoint's own hash. `train.py` cannot train locally.

Default recipe: YOLO11n-seg from COCO weights, 960px letterboxed input, batch 4, 100 epochs, no flips or mosaic. Ultralytics accumulates gradients to a nominal batch of 64, which starves a small pilot: 35 training frames give less than one optimizer step per epoch, about 64 in 100 epochs. Small pilots should pass `--nominal-batch` equal to `--batch` so every iteration updates the model. The default suits release-scale data, which makes about 17 steps per epoch.

The export writes a fixed-shape Core ML segmentation model with raw outputs (`nms=False`), checks that its input and outputs match the runtime decoder, and writes a checksum manifest. It then rewrites the package with float16 input and outputs (`coreml_io.py`): Ultralytics' export takes an image, which Core ML turns into float32 and the program scales and casts to float16 on the CPU, and it casts both outputs back to float32 there. Without those four operations the whole program runs on the Neural Engine, 4 ms instead of 9 ms per frame on the M1. The app and `evaluate.py` compute the float16 planes themselves with the program's own scale and rounding, so the outputs are the same numbers; `ZombsPerceive <session> --model <old> --compare-model <new> --frames 0:149` checks that detections agree exactly. The app still loads image-input exports. The input is 960 × 768 by default (`--height`; the manifest's `inputHeight`): the whole model then runs on the Neural Engine, about 9–11 ms on the M1, while 960 × 960 has more anchors than the Neural Engine accepts and runs its head on the GPU, about 21–23 ms. Training still letterboxes to 960 × 960; at 960 × 768 the detections match the square export's at the same thresholds (97–99.7% per class), while 960 × 512 is faster but lowers confidences. Release-scope datasets need at least 2,000 reviewed frames. A pilot-scope dataset trains at any size; its manifest records `scope: pilot`, the training frame count, the training and validation match IDs (`trainedOn`), and the dataset's split-report hash. `training.json` records the GPU, library versions, and base-weight and checkpoint hashes.

The requirements pin NumPy ≤2.3.5 and torch 2.7.0 for the local export. Core ML conversion fails under NumPy 2.5, and ultralytics would otherwise install the NumPy downgrade partway through the first export, which then fails. coremltools 9.0 is tested through torch 2.7.0. Local MPS training on the 8 GB M1 swapped heavily, which is one reason training moved to Kaggle.

Record the installed dependency versions with the experiment:

```sh
.venv/bin/pip freeze > artifacts/candidate-v1/environment.txt
```

Runtime decoding expects boxes shaped `[1, 4 + classCount + 32, anchors]` and mask prototypes `[1, 32, height, width]`. Letterbox padding is removed before screen mapping. Invalid/mismatched models stop recognition rather than falling back to generic weights.

## 5. HUD reading, item catalog and icons

The HUD needs no manual regions or templates. `Perception/HUDLayout.swift` finds slot 1 by its light-gray tile and lock icon. That slot always holds your melee weapon: fists or a knife skin. Every other region is an offset in units of the tile size, measured on 3840×1736 and 2880×1376 recordings. The HUD scales with √(width × height) and is anchored to the viewport corners.

`Perception/HUDReader.swift` reads each frame's pixels:

- **Vitals.** Health and shield are the fill length of each bar, sampled below the label text and anchored at the bar's left edge. Low health turns the bar red or salmon, so the reader follows the fill color rather than one green. On 56 hand-read values in `data/solo-pilot/hud-reviewed.json` the maximum error is 0.21 points.
- **Slots.**
  - Occupancy: an opaque tile color plus icon outlines.
  - Rarity: tile hue. Gray covers melee, consumables, throwables and common weapons; green, blue, purple, yellow and red are uncommon to mythic.
  - Selection: a thin border, the tile color lightened about 75% toward white. On snow or pale floors the border is faint. There the selected weapon is the slot whose printed total equals the readout's loaded plus reserve rounds.
- **Prompt and roster.** Prompt-panel presence, located by how much the panel darkens the map behind it. Teammate roster rows, from their thin health bars.

Text is read asynchronously with Vision (`TextReader`): the prompt, the "loaded / reserve" readout, slot counts, reserve counters, roster names and name tags. A result is used only while the pixels it read are still on screen.

`HUDText.prompt` turns prompt lines into an item:

- weapons: "M4 / Rare AR" → `ar:rare`;
- consumables: "Small Shield / Potion" → `small_shield`;
- chests and crates ("Gold Chest / Interact", "Crate (Mystic) / Interact", "Air Drop Chest / Interact") are `.chest` and opened;
- everything else, such as "Door / Open" or "Hoverboard / Exit Vehicle", is `.other` and never acted on.

Recorded OCR misreads are tolerated: a count badge read as "XZ" or "K2O", a key box read as "Eo" or "5", and a subtitle one letter off a known one ("Uncommon SMC", "egendary Sniper"). While a consumable is in your hand the panel now and then shows "Left Click to Consume" over its effect (4 of 483 recorded frames); when it does, that names the item in the selected slot.

`AssistantCore/Catalog.swift` defines weapon classes:

- shotgun, SMG, pistol, AR, LMG, minigun, DMR, sniper; launcher and special stay manual;
- per class: role, automatic fire, shot interval, range and minimum hit chance; rarity is the tier.

Consumables are matched by prompt name. The values are estimates. To tune them, write a copy to `~/Library/Application Support/ZombsAssistant/catalog.json`; the app uses it when every profile is valid.

Slot icons are identified by `IconLibrary`, which compares outline shape for weapons and also color for other items. When exactly one slot changes within 1.5 s of an item prompt, the slot takes the prompt's identity and the icon is learned; pickups you make yourself teach it too. Rearranged items keep their identity. An unidentified selected weapon is placed by the reserve counter its ammunition comes from.

Seed the library from recordings, then install it with a detector:

```sh
bash scripts/swift.sh build -c release --product ZombsPerceive
.build/release/ZombsPerceive data/recorder-corpus/2026-* --learn-icons artifacts/icons-seed.json
bash scripts/install-artifacts.sh artifacts/solo-pilot-2026-10-09-960x768 artifacts/icons-seed.json
```

`ZombsPerceive --decide` also runs the coordinator on recorded frames, as if each frame were live, and tallies what it would have done. `--hud-reviewed` compares vitals with hand readings. `--check-buffer-path` confirms that capture-buffer and decoded-image detections agree.

Each detected opponent has a constant-velocity Kalman filter in ground coordinates
(`AssistantCore/Motion.swift`). Your own movement is the opposite of the median shift of
matched walls, rocks, trees, doors, and chests; without them it is dead-reckoned with
widening uncertainty. A missed opponent keeps its identity for 0.3 s. Combat extrapolates
the on-screen (relative) velocity through the frame age, because you and the target both
keep moving until the shot. The user confirmed that bullets do not inherit shooter
motion, so it then solves for the earliest intersection of the opponent's **ground**
velocity with a projectile at the selected weapon's speed. Vertical coordinates are
converted to viewport-width units before solving.

The bot fires only when the filter's estimation uncertainty gives at least a 50% chance of
the bullet passing within a 0.015-viewport-width body radius, i.e. an expected miss within
the body radius. Unpredictable future direction changes are not counted; otherwise almost
no distant shot would qualify. While uncertain, it aims at the predicted intercept without
firing. The filter's settings are initial values: acceleration noise 0.1 viewport widths²/s³
(players can reverse within about 0.2 s), 0.003-viewport-width detection jitter, and an
initial speed spread of 0.18 viewport widths/s, the full movement speed measured from
scenery shifts in four reviewed frame pairs. In simulation at 20 Hz, a new opponent's speed
settles within 0.1 s and a full reversal is followed within about 0.15 s. With these
settings a settled estimate passes the 50% gate only when frame delay plus bullet flight is
under about 0.13 s. Calibrate them from labeled opponent tracks before relying on the range
at which the bot engages.

Opponent tracks come from consecutive saved frames (about 0.2 s apart). The [encounter
queue](../data/motion-pilot/encounter-queue.json) lists 102 frames around six triaged
encounters, with approximate bounds from contact sheets. Label them as ordinary scene frames,
which also adds examples of `player`, the detector's weakest class:

```sh
python3 tools/training/annotate.py data/solo-recordings-v2 \
  --queue data/motion-pilot/encounter-queue.json --port 8768
```

By the frozen whole-match splits, five sequences are in training matches, one is in test, and
none is in validation, so encounters in the validation and test matches still need to be
found. Once tracks exist, fit the filter settings and train any learned motion model on Kaggle
from the training matches. Enable the learned model only if it predicts held-out opponent
positions more accurately than this filter at the horizons that matter for aiming.

This assumes constant ground velocity during flight; acceleration, camera/zoom changes,
and muzzle offsets still require recorded calibration and supervised acceptance. A zero projectile speed only
compensates frame age; it does not provide bullet-flight prediction. Offscreen,
out-of-range, and unreachable intersections withhold fire instead of aiming at an
obsolete position. The input guard checks the same intercept with a 0.01-viewport-width
tolerance for planner-to-input delay, and separately checks the firing path.

## 6. Evaluate the exported model

```sh
.venv/bin/python tools/training/evaluate.py artifacts/candidate-v1 \
  data/dataset-v1/dataset.yaml
.venv/bin/python tools/training/evaluate.py artifacts/candidate-v1 \
  data/dataset-v1/dataset.yaml --calibrate-thresholds
```

`--calibrate-thresholds` chooses each class's detector threshold on the validation matches and stores it in `model.json` as `classThresholds`:

- most classes maximize F1, clamped to 0.3–0.7;
- `player` maximizes F0.5, clamped to 0.35–0.8, because a false player draws fire.

Check the result against recorded fights before installing. With only five validation players, the October 9 calibration chose 0.66, which dropped a recorded opponent scored 0.61–0.64; 0.55 was installed.

The evaluator runs the exported Core ML artifact on the untouched test split and decodes it as `Detector.swift` does: centered gray letterbox, best class per anchor, the manifest's detector threshold, class-aware NMS at IoU 0.45, and at most 100 detections. Its area resampling matches the app's Core Image downscale to a mean of 0.45 of 255 levels on a recorded frame. Highest confidence first, a detection matches the unmatched same-class reference box it overlaps most when IoU ≥0.5. For each class and each held-out match, `validation.json` records instances, detections, precision, recall, AP50 (detections down to 0.001), mask IoU of matched detections, and what missed instances and false positives overlapped. Validation matches are reported separately because they selected the training checkpoint. The evaluator refuses a test match listed in the manifest's `trainedOn`.

The gate takes the minimum precision and recall over all eleven classes, so a class without test instances scores zero. Detection requires precision ≥0.98 and recall ≥0.85 across test matches in all modes; `passed` also requires supervised acceptance, and the evaluator exits 2 until both pass. A Solo pilot cannot pass: its test matches cover one mode and contain no ally marker, enemy marker, or revive target. The app applies the same mode and metric checks to `validation.json`, so a pilot model can run for diagnostics but never enables input. These metrics do not certify HUD readings, team assignment, or action correctness.

The evaluator's tests need the ML environment: `.venv/bin/python -m unittest discover -s tools/training -p 'test_*.py'`. Under the system `python3`, they are skipped.

Install a candidate with `bash scripts/install-artifacts.sh artifacts/candidate-v1` (add an icon library as a second argument to seed it), then restart observation. Any installed detector runs as a supervised beta once Settings are verified and runtime latency passes; the dashboard reports whether the release gate above is met. Supervised sessions collect the gameplay acceptance evidence a release needs.

## 7. Supervised acceptance

Record at least one complete supervised test episode in each mode, inspect the recordings, and document the following scenarios:

`ally_exclusion`, `obstacles`, `ambiguous_interactions`, `healing_interrupt`, `temporary_swap`, `missing_weapon`, `stack_remaining`, `focus_loss`, `stale_frame`, `resize`, `emergency_stop`, `manual_movement`.

Check that E never targets doors, vehicles or revives (chests and crates are opened on purpose), the bot never emits movement, native inputs actually reach the game, and Option/Escape/focus loss release held inputs. Confirm Retina coordinate mapping and input behavior on the actual Mac. Inspect ammo and item-change acknowledgments, not just overlay predictions.

Create an acceptance JSON record using actual observations. Do not mark a scenario passed without exercising it:

```json
{
  "modelSHA256": "COPY_THE_EVALUATED_MODEL_HASH",
  "testedScenarios": [],
  "episodes": [
    {
      "mode": "solo",
      "recording": "path-to-actual-recording",
      "passed": false,
      "forbiddenInteractions": 0,
      "notes": "Replace with observed results; add Duo and Squad episodes."
    }
  ]
}
```

Then rerun evaluation with `--acceptance path/to/acceptance.json`. `passed` becomes true only when both detection metrics and completed supervised evidence pass. Zero failures in this suite is a release criterion, not proof that visual interpretation can never fail in future scenes.
