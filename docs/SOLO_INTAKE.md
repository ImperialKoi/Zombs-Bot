# Solo recording preparation — October 4, 2026

**Update:** [Seven additional recordings were audited and added](SOLO_INTAKE_V2.md). This report retains the original four-match baseline.

The recording audit, pilot split, annotation queue, and offline HUD bar experiment are complete. Scene annotation has started; the queue and model training remain incomplete. Gameplay input remains gated on recognition and acceptance checks.

## Recording audit

Four new Solo sessions were found, including one short match. They contain **3,071 unique frames over 10 minutes 57 seconds**, with 26,547 observation/decision pairs. Every JPEG decoded successfully at 3840 × 1736, timestamps increase within each session, log counts agree, and there are no duplicate image hashes across matches. The longest saved-image gap is 0.618 seconds. The recorder saves images at up to 5 FPS; this audit does not measure 60 FPS capture or 20 Hz perception.

Working copies are in `data/solo-recordings/`. Original recordings in Application Support are unchanged. The earlier 14-second smoke recording is excluded from this corpus.

| Match ID | Duration | Frames | Pilot split | Frames queued |
| --- | ---: | ---: | --- | ---: |
| `2026-10-04T00-07-25Z-78E1A3` | 4m 53s | 1,377 | Train | 900 |
| `2026-10-04T00-13-55Z-B719C4` | 2m 47s | 778 | Validation | 500 |
| `2026-10-04T00-17-19Z-56F69F` | 37s | 172 | Train | 100 |
| `2026-10-04T00-18-24Z-E71586` | 2m 40s | 744 | Test | 500 |

The [integrity report](../data/recording-audit/integrity.json) records per-session checks. Contact sheets in the same directory were visually inspected for match progression, environmental variety, HUD states, and death screens.

## Prepared annotation work

- [Frozen split plan](../data/solo-pilot/split-plan.json): whole matches remain separate. Two matches train, one validates, and one tests the Solo scene model.
- [Annotation queue](../data/solo-pilot/annotation-queue.json): 2,000 unique frames, comprising 1,000 training, 500 validation, and 500 test frames. Sampling spans each recording and includes the reviewed phase anchors.
- [Phase review](../data/solo-pilot/phase-review.jsonl): 48 manually inspected phase labels. These are **phase-only reviews**, not complete scene annotations.
- **Scene frames annotated: 5 of 2,000 (53 polygons); 1,995 pending.** See the [annotation progress and recording request](SOLO_ANNOTATION_PROGRESS.md). Four death-screen negative candidates were individually inspected and rejected; no negative frames have been accepted. No scene model has been trained. Queued frames do not satisfy the training requirement until their visible objects are labeled and reviewed.

The local annotation viewer was verified at the first and last queued images and returned to the first unreviewed frame. Its queue navigation and image display work. To restart it from the project root:

```sh
python3 tools/training/annotate.py data/solo-recordings \
  --queue data/solo-pilot/annotation-queue.json --port 8765
```

Open `http://127.0.0.1:8765`. Label every visible instance before saving a reviewed frame. Bus, death, and empty-looking scenes can still contain objects requiring labels.

## HUD bar experiment

The offline prototype measures the colored health and shield bars using geometry calibrated on the first training match. It only accepts this recording's 3840 × 1736 viewport.

| Check | Result |
| --- | --- |
| Frames processed for timing | 616, every fifth saved image |
| Bar measurement p95 | 0.368 ms, excluding JPEG decoding |
| Manually reviewed HUD samples | 28 frames / 56 numeric readings |
| Rejected readings in that spot check | 0 |
| Maximum absolute error | 0.24 points on the 0–100 scale |
| Mean absolute error | 0.077 points |

The [saved benchmark](../data/solo-pilot/bar-benchmark.json) includes source hash, geometry, timings, predictions, and comparison with [manual numeric readings](../data/solo-pilot/hud-reviewed.json). The additional samples deliberately include low values selected from candidate output. This is a small, selected spot check, not an unbiased estimate of gameplay accuracy. It includes examples from every pilot split; those HUD examples are not an untouched final release test set.

**This reader is not integrated into the app or validated for live use.** An absent HUD can resemble a zero bar. HUD-presence and match-phase checks are required. Values below 54 health, HUD absence, resize/scale changes, and varied UI states need further tests. Timing excludes capture, decoding, model inference, inventory recognition, and input dispatch.

Reproduce with a Python environment containing Pillow and NumPy:

```sh
python tools/training/hud_bars.py data/solo-recordings \
  data/solo-pilot/bar-candidates.jsonl --stride 5 \
  --reviewed data/solo-pilot/hud-reviewed.json \
  --report data/solo-pilot/bar-benchmark.json
```

## Remaining work, in order

1. **Annotate and review scene objects.** Complete the queued Solo polygons, check class coverage, and add footage for missing cases. Keep match boundaries fixed. Negative frames must also be genuinely reviewed.
2. **Train and evaluate a Solo detector.** Set up the ML environment, fine-tune the segmentation model, export Core ML, and measure each class on held-out matches. A Solo pilot cannot pass the current all-mode release gate.
3. **Complete runtime recognition.** Integrate a fast, guarded HUD reader; recognize inventory, ammo, selected slot, item identity/count, interaction prompts, healing progress, and match phase. Test absent/obscured HUDs, low health, scale changes, and stale readings.
4. **Calibrate actual item behavior.** Verify weapon/rarity profiles, firing/reload/switch timing, projectile speeds, consumable gains/caps/durations, and stack handling from current-game evidence.
5. **Collect Duo and Squad data.** Record at least three separate matches per mode, annotate them, and establish reliable ally/enemy identification. Unknown affiliation must continue to prevent firing.
6. **Validate the complete visual pipeline in replay.** Run saved images through recognition and action coordination. Cover ambiguous pickups, obstacles, allies, target loss, healing interruption, full inventory, failed pickups, and temporary weapon recovery. The existing replay CLI consumes supplied observations; it does not yet rerun image recognition.
7. **Verify native input and performance under supervision.** Confirm aim mapping, game receipt of inputs, no movement/door/chest/revive actions, Option override, Escape, focus loss, resize, stale frames, and capture failure. Measure sustained 60 FPS capture, at least 20 perception updates/s, and under 100 ms p95 frame-to-action latency.
8. **Package and validate the release.** Bundle the trained model, reviewed profiles/templates, and evidence; rerun acceptance in all modes and build the final `.app`. The running recorder bundle predates the latest tested HUD source fixes. Use a stable signing identity for updates if available; local ad-hoc rebuilds may require restoring macOS capture permission.

## Verification status

Ten Python dataset/coverage tests passed on October 4, including frozen match splits, invalid polygon rejection, explicit negative review, and source-image hash checks. The existing Swift suite last passed 41 tests. No Swift source changed during this recording-preparation step. No gameplay-success or full-pipeline latency result is claimed.
