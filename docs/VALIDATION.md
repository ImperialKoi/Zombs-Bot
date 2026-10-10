# Validation status

Updated October 9, 2026 on this Apple silicon Mac (8 GB M1).

## Beta checks, October 9

All of these ran offline on recorded matches; none is a live-game result.

- **Tests.** 74 Swift tests pass: 65 core and 9 perception. The new core tests cover:
  - distance bands, hysteresis and hold time; switching to a loaded gun before reloading; skipping guns without ammunition;
  - catalog weapons following the bands;
  - the prompt parser: chests, crates, doors, vehicles and revives are never items;
  - pickup rules: free slot, swap after selecting the replaced slot, upgrade, stack, no downgrade loop; launchers and unknown items ignored;
  - team affiliation from name tags, and unconfirmed or unknown players never fired on.

  The perception tests use native-resolution HUD crops from Solo (3840×1736) and Duo (2880×1376) matches. They cover HUD detection at both resolutions, vitals, the selected slot, rarity, empty slots, the prompt panel, the team roster, and Vision reading "M4 / Rare AR", "Hybrid Potion / Healing", "Hoverboard / Exit Vehicle" and the "90 / 1,042" readout. They also cover pickup-taught icons matching at another rarity, simultaneous changes never labeled by a prompt, rearranged items keeping their identity, and ammunition placing an unknown weapon.
- **Python.** 44 tests pass under `.venv/bin/python`, including the new threshold calibration test.
- **HUD accuracy.** On the 28 hand-read frames (`data/solo-pilot/hud-reviewed.json`), health and shield matched all 56 values within 0.21 points (mean 0.03). The selected slot was found in 28 of 28; five were checked visually.
- **Snow.** In a fight on snow (`ABF049`, 14 frames) the selected slot was found in all 14. Before the readout-total fallback and a tighter border tolerance, 5 of 14 were missed.
- **Detector path.** Feeding the detector from capture-style BGRA buffers matched decoded images: 236 detections, mean IoU 0.998, no flip. On this Mac the detector takes 30 ms p50 and 36 ms p95, including letterboxing and decoding.
- **A recorded fight through the full pipeline** (`ZombsPerceive --decide`, `ABF049`):
  - it engaged the opponent at medium range with the Epic AR in 14 frames;
  - it pressed reload when the readout showed 0/84, waited, and re-engaged at long range;
  - the gaps are frames where 5 FPS recordings break track continuity; live capture runs at 20–30 FPS.

  Earlier in this check a bright tree had passed as a teammate roster bar and switched the Solo match to team rules. Roster rows now require a thin bar at the roster's edge over five consecutive frames.
- **Two whole matches through recognition and decisions** (`ZombsPerceive --decide`, seeded icon library):
  - **Solo `78E1A3`** (1,377 frames). It engaged at close, medium and long range and selected weapons for the range. It picked up guns (SCAR, M4, MG36, MP5, Uzi, KSG, Semi-Auto Sniper) and shields, healed with a Big Shield, and reloaded.
  - **Duo `212F9A`** (1,039 frames). Team mode held for the whole match and the roster read "Chris_Hansen". Every shot went at a player classified as an enemy. On the frames inspected, the teammate was classified correctly and the targets were opponents in a fight.
  - **Fix.** That map has rows of snowman props that the detector reports as players (0.75–0.94); untagged, they counted as enemies. A motionless "player" with two motionless ones close by is now unconfirmed, and no props were targeted afterwards.
  - **Replay artifacts.** "Slot selection timed out" and "pickup not confirmed" are expected here, because the recording does not respond to the keys the assistant would press.
- **Corpus pass.** All 33 recordings (25,325 frames) went through recognition.
  - HUD found in 14,927 frames; the rest are lobby, death or map screens, or recordings with the HUD cropped off.
  - 3,323 of 3,326 prompts parsed.
  - Inventory icons were learned from 114 pickups (79 icons): ARs, SMGs, snipers, shotguns, pistols, launchers, grenades and all five consumables.
  - Vision sometimes returns Cyrillic look-alikes ("Еріс SMG"); prompt words are normalized before matching.
- **Replay.** The synthetic fixtures (now prompt-based) give 4 proposed actions, 1 fire, 1 pickup and 0 guard rejections.

### Detectors on the two held-out Solo test matches

Both models were trained on Kaggle (T4) and evaluated with `evaluate.py` at threshold 0.5.

| Class | Oct 7 (76 training frames) AP50 / precision / recall | Oct 9 (104 training frames) AP50 / precision / recall |
| --- | --- | --- |
| `player` (3 instances) | 0.047 / 0.00 / 0.00 | 0.337 / 0.25 / 0.33 |
| `self_player` | 0.941 / 0.93 / 0.88 | 0.783 / 0.75 / 0.75 |
| `tree` | 0.880 / 0.97 / 0.81 | 0.940 / 0.88 / 0.95 |
| `rock` | 0.731 / 0.85 / 0.63 | 0.650 / 0.81 / 0.60 |
| `wall` | 0.163 / 0.24 / 0.19 | 0.263 / 0.47 / 0.34 |
| `door` | 0.474 / 0.69 / 0.49 | 0.542 / 0.71 / 0.53 |

On validation, `player` AP50 rose from 0.096 to 0.340.

The Oct 9 model is installed as the beta detector, as `artifacts/solo-pilot-2026-10-09-960x768`: the same weights as `artifacts/solo-pilot-2026-10-09`, exported at 960 × 768 so that the whole model runs on the Neural Engine (per-frame detection 12 ms instead of 25–27 ms when replaying recordings). On 511 frames from five matches at all three recorded window sizes it keeps 97.1–99.7% of the square export's detections in every class at the same thresholds; on the test split its AP50 is equal or higher in every class. Its per-class thresholds come from `evaluate.py --calibrate-thresholds` on the square export, except `player`, which is set to 0.55 (see DATA_WORKFLOW §6). With 3 test and 5 validation players these numbers are very uncertain. The app does not need the self-player class; your position is the screen center.

### Still open for the beta

- **Live supervised session.** Native input reaching Chrome, aim mapping on your display, the speed gate (beta ≥15 updates/s; release target 20; p95 ≤100 ms) with asynchronous text recognition running, the selected-slot handshake after key presses, and pickups and swaps in the real game.
- **Duo/Squad.** Name-tag reads on live teammates.
- **Measurements.** Bullet speeds and weapon timings per class.

## Earlier checks (October 3–5)

- Release build and ad-hoc app signature verification passed.
- 52 Swift policy/coordinator/parser/motion tests passed. The motion tests cover separating your own movement from an opponent's ground motion, following a full-speed reversal within 0.15 s, keeping identity through brief misses, leading ground rather than relative motion for bullets that do not inherit your movement, and holding fire until an opponent's course settles. Coverage includes allies and unknown players, walls/doors/chests blocking fire, permitted engagement behind foliage/rocks, constant-velocity interception across aspect ratios and frame ages, long leads accepted by the input guard, unreachable/offscreen/out-of-range targets, stale frames, item caps, temporary healing swaps, recovery failures, combat interrupting a pending pickup, and recorded HUD number formats. Projectile interception is verified with synthetic velocities and speeds; current-game bullet speeds remain uncalibrated.
- Nineteen Python tests passed under `.venv/bin/python`, including match separation, frozen Solo pilot splits, invalid polygons, negative review evidence, changed source-image hashes, reviewed snapshots, runtime-equivalent detection decoding and matching, Kaggle bundles that exclude test frames, and checkpoint provenance. The system `python3` skips the four evaluator tests, which need NumPy.
- A Solo pilot detector was trained on a Kaggle T4 from a 56-frame reviewed snapshot (35 training frames), exported to Core ML on this Mac, and measured on the two held-out test matches. Tree recall was 0.83 and own-character recall 0.80; wall recall was 0.07, and the one other player in the test frames was mislabeled. The release gate did not pass and cannot pass with Solo-only data. The app's own `Detector.swift` loaded the model, reported it unvalidated, and matched the evaluator's detections. See the [pilot model report](SOLO_PILOT_MODEL.md).
- The replay CLI processed nine synthetic observations: four proposed actions, one fire action, one pickup, and zero guard rejections. These are policy tests on supplied observations, not tests of image recognition.
- The native app launched and restarted. ScreenCaptureKit displayed the actual ZombsRoyale Chrome window before the final rebuild.
- The UI kept gameplay input disabled without the recognition artifacts.
- After permission was restored, the final build captured the game and opened the calibration editor. A viewport crop was saved while the overall calibration remained unverified.
- Recording session `2026-10-03T19-05-31Z-8B8FDA` saved 68 valid JPEG frames at 3840 × 1736 and 533 observation/decision pairs. The user confirmed Solo mode. This is a 14.28-second match fragment, not a complete match.
- Replaying those 533 observations produced zero proposed actions and zero guard rejections. The assistant was unfocused and unvalidated during this check.
- Offline Vision OCR correctly read health `100/100`, health `77/100`, shield `44/100`, and ammo `24/417` in sampled frames. A shield reading `5/100` fragmented and must be withheld. See [HUD findings](HUD_FINDINGS.md).
- Four subsequent Solo sessions passed a full file audit: 3,071 unique decoded JPEGs, 26,547 matching observation/decision pairs, and no cross-match duplicate images. A 2,000-frame annotation queue and whole-match Solo pilot split are prepared. Five queued frames now have 53 reviewed scene polygons; 1,995 remain pending. Four death-screen negative candidates were inspected individually and rejected. See [annotation progress](SOLO_ANNOTATION_PROGRESS.md).
- Seven additional Solo recordings were added without moving the original split assignments. The expanded corpus passed the full image/log audit: 8,059 unique frames across 11 sessions and 71,388 observation/decision pairs. Seven additional final-screen negative candidates were individually reviewed and rejected; none were marked empty. The combined queue is 2,084 frames with six polygon-reviewed frames (64 polygons), including the first player/tree examples in a new test-match frame. The latest coverage audit reports no invalid annotations or changed locked files. See [v2 intake](SOLO_INTAKE_V2.md).
- An offline bar-reader spot check compared 56 readings against visible numeric HUD labels. Maximum absolute error was 0.24 points; p95 measurement took 0.368 ms over 616 sampled frames, excluding decoding and the rest of the pipeline. It is not integrated or release-validated. See the [Solo recording report](SOLO_INTAKE.md).
- The local annotation viewer displayed the first and last queued frames and returned to the first unreviewed frame. No scene annotations were saved during this UI check.

The running packaged app is the capture/recorder build verified above. The latest HUD and targeting changes are compiled and tested in `.build/debug`; they will need packaging with the next recognition build. The recorder was left running with its restored macOS permission.

## Still open

- Annotate the collected Solo gameplay and collect/annotate Duo and Squad. Only the 35-frame Solo pilot model has been trained; no release-candidate model exists.
- Calibrate HUD regions, templates, item behavior, and team identification against recordings.
- Measure the complete recognition pipeline against the 20 Hz and 100 ms p95 targets. Preview performance without a model cannot establish this result.
- Verify native inputs in supervised gameplay, including aim coordinates, manual override, emergency stop, focus loss, and the absence of movement, door, chest, or revive actions.
- Run replay and supervised acceptance across all three modes. The complete release criteria have not passed.

## Reproducing automated checks

```sh
bash scripts/swift.sh test
.venv/bin/python -m unittest discover -s tools/training -p 'test_*.py' -v  # system python3 skips the evaluator tests
bash scripts/package.sh
.build/release/ZombsReplay Tests/fixtures/synthetic-observations.jsonl \
  Tests/fixtures/synthetic-items.json /tmp/zombs-replay-decisions.jsonl
```

The synthetic item profiles are deliberately separate from the app's unverified production profiles. Do not copy fixture profiles or synthetic metrics into the app's validation artifacts.

## Recording smoke check

After restoring Screen Recording access, quit and reopen the app, refresh the game window, and start observing. Confirm the game preview updates, open and cancel calibration, then record a short menu session and stop it. Check that its session manifest, JPEG images, frame index, observations, and decisions were written. A menu smoke session is not a completed gameplay match and must not count toward the training match requirement.

## Local rebuilds and macOS permissions

This bundle is ad-hoc signed for local development. Replacing its executable can invalidate macOS privacy permission records. If capture is rejected after a rebuild, quit the app, re-enable its Screen Recording entry in System Settings, and reopen it. A stable developer signing identity is needed for a smoother distribution/update workflow; this project does not install certificates or modify privacy settings automatically.
