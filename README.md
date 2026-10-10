# Zombs Assistant

A native Mac application for observing ZombsRoyale, recording training data, and running guarded combat, loot, and healing decisions. You control movement.

## Current status

**Beta, October 9, 2026: the assistant aims, fires, switches guns by range, picks up guns and heals in real matches, under your supervision.** Every part has been checked offline on recorded matches (see [validation](docs/VALIDATION.md)); a supervised live session is the next step. The detector is still a pilot trained on 138 reviewed Solo frames: on held-out matches it finds players with AP50 0.34, so expect some missed players and an occasional false one. Codex continues annotating ([round 2](docs/ANNOTATION_ROUND2.md)); retrain on Kaggle as reviews land.

What the beta does:

- **Reads the HUD automatically.** No manual regions or templates: it finds the inventory by your locked melee slot and derives the rest. Health and shield come from the bars (within 0.21 points of 56 hand-read values), plus the selected slot, each slot's rarity, ammunition and the interaction prompt.
- **Picks up guns from the prompt.** The panel under your character names what E will do ("M4 / Rare AR", "Hybrid Potion / Healing"). It fills free slots, upgrades a gun by rarity or class, and keeps one close, one medium and one long-range gun. It never presses E for chests, crates, doors, vehicles or revives, and launchers and special weapons stay manual.
- **Switches guns by distance.** Shotgun up close, assault rifle at mid range, sniper beyond, with SMG, DMR, LMG and pistol as fallbacks. A margin around each cutoff and a minimum hold time prevent flapping. If the magazine empties mid-fight, it switches to another loaded gun before reloading. The cutoffs are adjustable in Settings.
- **Aims and fires.** A motion filter leads moving opponents, semi-automatic weapons fire at their cadence, and it reloads when the readout shows an empty magazine. An opponent in the open always gets a gun: if none suits the range, it holds the one that reaches farthest on the opponent until it is in range.
- **Heals during safe gaps.** It uses whichever heal restores the most points per second, and stops for visible threats or damage. While it heals, a **STOP MOVING** label appears above your character.
- **Respects teams.** In Duo and Squad, a player whose name tag matches your team roster is a teammate; only players without a matching tag become enemies, and unknown players are never fired on. In Solo every other player is an enemy and no name tags are read; if a teammate roster stays visible for two seconds, the dashboard warns that Solo is selected.

Items are identified from a catalog of weapon classes and rarities (`AssistantCore/Catalog.swift`) and inventory icons learned from pickups: when a slot changes right after a prompt, that icon is labeled with the prompt's item. Icons were pre-learned from all 33 recordings, and the library keeps learning from your pickups.

Still estimated or unverified:

- Weapon timings and ranges are class estimates. Bullet speeds are unmeasured, so leads cover frame delay but not bullet flight; long shots at moving targets will trail.
- Native input reaching the game, aim mapping on your display, and the speed gate have not been checked in a live match.
- The release gate (held-out precision ≥0.98 and recall ≥0.85 in all three modes) is still computed and shown, and is not met.

## Build and open

Requires an Apple silicon Mac, macOS 14+, and Swift 6 Command Line Tools or Xcode. The runtime application has no Python dependency.

```sh
bash scripts/swift.sh test
python3 -m unittest discover -s tools/training -p 'test_*.py' -v
bash scripts/package.sh
open dist/ZombsAssistant.app
```

`scripts/swift.sh` keeps build caches in this workspace and supplies the Swift Testing framework paths for Command Line Tools installations. Packaging produces an ad-hoc signed local app; it is not a notarized public distribution.

The app stores recordings and configuration in:

```text
~/Library/Application Support/ZombsAssistant/
  calibration.json        game-area inset, mode, key bindings, weapon ranges
  catalog.json            optional: tuned copy of the built-in item catalog
  recordings/<match>/
  artifacts/
    model.json            detector manifest with per-class thresholds
    zombs.mlpackage/
    validation.json       optional held-out evaluation (release gate)
    icons.json            learned inventory icons
```

Install a trained detector and the seeded icon library with:

```sh
bash scripts/install-artifacts.sh artifacts/solo-pilot-2026-10-09-960x768 artifacts/icons-seed.json
```

## First session

1. **Start observing.** Open ZombsRoyale in Chrome. Launch the app, click **Refresh windows**, and grant Screen Recording access when macOS asks (relaunch if needed). Select the game window and click **Start observing**.
2. **Check Settings.**
   - The capture starts 87 points below the top of the Chrome window, which excludes tabs and the address bar in your setup; adjust it if you show a bookmarks bar.
   - Choose the game mode and check that the key bindings match the game (interact E, reload R, slots 1–6).
   - Tick **I verified…** and save.
3. **Enter a match.** The **HUD** readiness item turns green once your inventory is visible. The inventory strip shows what each slot holds, and the outlines on the preview should sit on the slots.
4. **Enable input.** Click **Enable supervised input**. The banner turns blue (**Supervised input ready**) and a label appears over the game. In the game, press **=** to start: you hear a tick, and the banner and the label turn green (**Assistant on**). Press **=** again to stop. Move with your keyboard; the assistant handles the mouse. Hold **Option** to take over, press **Escape** to stop.

**Record a match** still saves frames, observations and decisions for review and training.

## Input behavior

Input can be enabled once a detector is installed, Settings are verified, and the pipeline sustains at least 15 updates/s with p95 latency ≤100 ms over at least 100 frames. The release target remains 20 updates/s. The detector's 960 × 768 input runs entirely on the Neural Engine, so it does not compete with the game for the GPU. Replaying recorded 3840 × 1736 frames on an 8 GB M1, a frame takes about 12 ms (median; 27 ms with the earlier 960 × 960 export), and the pipeline keeps up with most 60 Hz captures. The assistant acts only during a live match: when your inventory is visible, the game window is focused, and frames are fresh.

**Enable supervised input** turns input mode on. **=** in the game then starts and stops sending input, with a sound each time. A click-through label over the game shows the state and what the assistant is doing; it is not part of the capture. Input is sent only while Chrome is the active app; in any other app it pauses and resumes when you return. Holding Option yields control. Escape stops input until you press **=** again, and the dashboard says why input stopped. If ZombsRecorder is running, **=** also starts or stops its recording. Manual item keys, mouse buttons, and scrolling yield until released plus 750 ms. Movement passes through unchanged. Focus loss requires manual rearming. Resizing stops capture until it is restarted.

The bot never has a movement action. It presses the interact key once, only when the prompt names a recognized gun or consumable and the pickup improves your loadout. It confirms the result from the inventory and does not press again for that item for three seconds if nothing changed. With a free slot, the game fills it. With a full inventory, the slot to replace is selected first, because the game swaps out the selected item. Throwables, launchers and revives are manual.

Item/slot changes are acknowledged from later frames. Healing starts when it restores at least five points, after a two-second gap with no threat and no confirmed player in view, even one behind a wall. Once started, a heal is carried through: selecting the item, using it, and further doses while they still help. Only an opponent in the open, damage, or your own slot change ends it early, and the assistant then switches straight to the gun for that range. One-frame false detections and a briefly unreadable HUD do not interrupt it. While the assistant heals, a click-through **STOP MOVING** label appears above your character. Healing is confirmed from both item consumption and health/shield changes. Weapon recovery after a temporary heal swap uses the dropped weapon's prompt; remaining consumable stacks are retained.

Combat predicts each opponent's motion with a Kalman filter over the ground. Your own
movement is measured from how static scenery shifts on screen, so it is separated from
the opponent's. Bullets do not carry your movement (user-confirmed), so the lead for the
bullet's flight uses the opponent's ground velocity, and the frame delay uses its
on-screen velocity. The bot fires only when the estimate gives at least a 50% chance of
the bullet passing within the opponent's body radius; until then it keeps the crosshair
on the predicted intercept. It can fire toward enemies behind bushes, trees, and rocks,
although those objects still block bullets. Walls, doors, chests, allies, and unknown
characters still block firing. Bullet speeds are not measured yet; a zero speed enables
only frame-age compensation. Each weapon class has its own minimum hit chance (0.2–0.3),
so snipers can engage at long range.

A confirmed opponent the detector misses for a few frames stays a target for 0.25 s at its
predicted position, so a fight does not stop on every missed frame. Firing does not wait for
an ammunition reading: the readout changes with every shot, so mid-fight it is often between
reads, and only a read empty magazine stops fire. A wall, door or chest detected on your own
position is your character misread and is ignored. When a player is visible but not engaged,
the status says why: still being confirmed, behind cover, or awaiting a name-tag read.

Team modes require positive enemy evidence. Teammates show their roster name above their head; the assistant reads the roster every few seconds and the tag above each player twice a second. A matching tag makes a teammate. Two reads with no matching tag make an enemy. Until then the player is unknown: unknown players block the firing line, suppress healing, and are never fired on.

## Replay without game input

```sh
.build/debug/ZombsReplay /path/to/session/observations.jsonl \
  --catalog /path/to/session/replayed-decisions.jsonl
python3 tools/replay_report.py /path/to/session \
  /path/to/session/replayed-decisions.jsonl
```

Open the resulting `replay.html` locally to inspect images, targets, proposed aim, and decisions. The CLI exits with status 2 if its independent input guard rejects a proposed action. Replay uses recorded observations; it does not rerun image recognition.

To rerun recognition on recorded frames and see what the assistant would do, use `ZombsPerceive`:

```sh
bash scripts/swift.sh build -c release --product ZombsPerceive
.build/release/ZombsPerceive data/recorder-corpus/<match> --model artifacts/solo-pilot-2026-10-09-960x768 \
  --icons artifacts/icons-seed.json --decide --jsonl /tmp/frames.jsonl
```

It treats every frame as live and focused, and prints the actions it would have taken (fire, slot switches, pickups, reloads, heals), the decision reasons, HUD statistics and timing. `/tmp/frames.jsonl` holds each frame's readings.

## Code layout

- `AssistantCore`: normalized geometry, typed observations and intents, the item catalog, prompt parsing, team affiliation, policy checks, and the action coordinator. No OS APIs.
- `Perception`: HUD layout and pixel reader, asynchronous text recognition, icon library and inventory tracking, the Core ML detector, and scene/motion tracking. Shared by the app and the offline tool.
- `ZombsAssistant`: capture, the processing pipeline, UI, recording, and native input.
- `ZombsPerceive`: runs the app's recognition, and optionally its decisions (`--decide`), on recorded frames; reports HUD readings, prompts, inventory, detections and timing; seeds the icon library (`--learn-icons`).
- `ZombsReplay`: deterministic replay of recorded observations through the coordinator and independent action guard.
- `tools/training`: recording import, annotation UI, dataset preparation, Kaggle training/export, evaluation, and per-class threshold calibration (`evaluate.py --calibrate-thresholds`). `ingest_recordings.py` pulls Zombs Recorder matches into an annotation corpus.
- `ZombsRecorder`: a separate SwiftPM package. It is a recording-only menu-bar app for you and friends: pressing **=** in the game records each match as hardware-encoded video, which is uploaded to a private Kaggle dataset. `make-friend-kit.sh` packages it with a setup guide for a friend's Mac. See [ZombsRecorder/README.md](ZombsRecorder/README.md).

## Research references

The design was informed by the [current game](https://zombsroyale.io/), [HackerHansen's archived experiment](https://github.com/HackerHansen/Zombsroyale.io-Aimbot-v2), and the [Surviver_dot_IO computer-vision project](https://github.com/KevinUTAT/surviver_dot_IO). The latter targets a different game. None of those projects' executable files or source code are included here.
