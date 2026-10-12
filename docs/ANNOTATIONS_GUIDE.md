# Annotations guide

How to annotate ZombsRoyale frames for the detector. This is written for the annotating agent and for anyone checking its work. It replaces the class notes scattered across other docs; where they disagree, this guide wins.

## The job

Every queued frame gets one annotation that **outlines every visible instance of the 11 classes**. Anything left out teaches the model that the object isn't there, so a missing tree is as harmful as a wrong one.

| What | Where |
| --- | --- |
| Frames to do, in order | [`data/recorder-corpus/full-pass-queue.json`](../data/recorder-corpus/full-pass-queue.json) |
| Frame images | `data/recorder-corpus/<match>/images/<frame>.jpg` |
| Model drafts (suggestions only) | `data/recorder-corpus/<match>/model-drafts/<frame>.json` |
| **Your saved annotation** | `data/recorder-corpus/<match>/annotations/<frame>.json` |
| Review feedback for you | `data/recorder-corpus/review-feedback/` |
| Your review pages for the user | `data/recorder-corpus/reviews/` |

The queue covers every recording at one frame per 2 s: 2,234 frames across 33 recordings (Solo, Duo and Squad), interleaved so stopping anywhere still leaves a balanced set.

It starts with:
1. 6 frames returned for fixes;
2. 2 Codex drafts awaiting a final check;
3. the unfinished round-2 frames.

## Classes

| Class | Label | Don't label |
| --- | --- | --- |
| `self_player` | The recording player's character: the one the camera follows, at or near the viewport centre. Include the held weapon. **Exactly one** whenever it is on the ground. | Its shadow, glow, name or health UI. None while in the plane, gliding, spectating or dead. |
| `player` | **Every other character, whatever its team:** enemies, teammates, bots, unknowns. Include body and held weapon. | Never skip a character because its team is unclear; team is a separate question (markers below). |
| `ally_marker` | Duo/Squad only: the UI that positively identifies a teammate. The usual case is the **teammate's name tag above their character** (blue/teal text, e.g. `Chris_Hansen`). Outline the tag tightly, as its own polygon; the body stays `player`. | Never in Solo. Not the roster panel in the corner (that is HUD). |
| `enemy_marker` | A UI cue that positively identifies an opponent, if the game shows one. | Never infer it from behaviour or from the absence of a tag. None has been observed yet. |
| `revive_target` | Duo/Squad: a downed teammate that can be revived (knocked-down character, revive circle or prompt). | |
| `ground_item` | Each item lying on the ground: weapons, loose ammo, medkits, bandages, potions, throwables. One polygon per item. Medkits on the ground are items, not chests. | Glow rings, sparkles, shadows, pickup text, items held by a character or shown in the inventory. |
| `door` | Building doors, open or closed. | The wall around them (a door and a wall never cover the same area). |
| `chest` | Openable containers. Outline lid and body as **one** polygon. | Containers that only break and don't open (those are `rock`). |
| `wall` | The visible structural wall bands of buildings. Walls don't break. | Roof artwork, floors, rugs. |
| `rock` | Solid non-vegetation cover that breaks. | |
| `tree` | All vegetation that blocks bullets. | |

**Openable containers you have confirmed as `chest`:**
- chests and gift/present boxes;
- yellow Z boxes ("Gold Chest");
- magma crates identified as "Crate (Magma)";
- blue wand/star boxes;
- green ammo-symbol boxes;
- wrapped presents;
- yellow X boxes;
- red star-emblem boxes.

**Cover you have confirmed as `rock`:**
- stones, including the round blue/pink-centred Mystic Forest stones;
- crates and barrels that don't open;
- benches, tables and other furniture;
- tents, rope fences, silver pedestals, coloured circular pads, solid window props, boats;
- the large orange four-petal-emblem box;
- brown skull-and-crossbones boxes.

**Vegetation you have confirmed as `tree`:** trees, bushes (including small light-green bushes, blueberry bushes and snowy red/purple bushes), hedges, thorn plants and purple Mystic flowers.

**Excluded, by your confirmation:** large blue skull-pattern rectangles inside buildings are floor rugs.

### Never label

- **HUD:** minimap, kill feed, inventory slots, health/shield bars, teammate roster, buttons, timers, counters, emote wheel.
- **On-screen text:** "DOUBLE KILL", "Eliminated Player", "+300 Medium Ammo", "Gas is Moving Now", floating damage numbers such as "784", interaction prompts such as "Left Click to Consume" and "M4 Uncommon AR [E]".
- **Effects:**
  - bullets, rockets and their trails, muzzle flashes, explosions, smoke, gas, glow rings, shadows, ejected shells;
  - the transport plane, gliders and parachutes, before players land.
- **Scenery:** roof artwork, ground textures, roads, water, floor patterns.
- **Browser chrome:** tabs, address bar and **bookmarks bar**. All 12 of Jeremy D's recordings have his bookmarks bar across the top. Never draw anything in that strip.

**Text over an object hides the text, not the object.** Remove the banner or number, but still outline the dropped weapons, bushes and players underneath, clipping where the text actually covers them.

## Polygon rules

1. **Trace the visible outline tightly,** following the dark border of the sprite. Characters include their held weapon.
2. **One object, one polygon, one class.** Never outline an object twice. When you replace a model draft's polygon with your own, delete the draft's.
3. **Clip opaque HUD out.** If the HUD splits an object into visible pieces, keep them as one instance joined by a zero-width bridge. `outline.py` and the drafts already do this.
4. **Objects cut off by the frame edge:** outline the visible part.
5. **No stray clicks.** Small real objects are fine; slivers of nothing are not.

## Ask the user when unsure

- **Disguise skins** (present boxes and similar):
  - it's a character if it moves between neighbouring frames, holds a weapon, or carries a name tag;
  - it's a `chest` if it's static and opens.
- **Crates:**
  - `chest` if a neighbouring frame shows an open prompt;
  - `rock` if it only breaks;
  - make identical-looking crates in one frame the same class.
- **A new kind of object you haven't seen ruled on:** ask.

Batch questions with a crop of each object; don't stop for each one. **Open questions as of 2026-10-12:**
- snowmen (cover or decoration?);
- giant red mushrooms in Mystic Forest (`tree`?);
- snowy wooden crates (chest or cover?);
- the purple round object holding a gun next to a rifle in `8B2504/002693`.

## Working one frame

1. **Open the frame.**
   - In the browser: `.venv/bin/python tools/training/annotate.py data/recorder-corpus --queue data/recorder-corpus/full-pass-queue.json`.
   - Or as files: the image, plus `model-drafts/<frame>.json` if it exists.
2. **Treat the draft as suggestions.** Drafts find about half the objects with good outlines. Expect wrong classes (false `player` on rocks and stumps, `door` on the plane) and missed objects.
3. **Delete** every wrong draft object.
4. **Fix** classes.
5. **Add** what's missing. For a precise outline from a box:
   ```sh
   .venv/bin/python tools/training/outline.py FRAME.jpg --box X0 Y0 X1 Y1 [--box …] --overlay check.png
   ```
   Pixel boxes go in; normalized polygons come out. Look at `check.png`. In the browser, press **B** and drag a box.
6. **Check the frame:**
   - find the `self_player` at the centre;
   - in team modes, look for every name tag;
   - look under every text banner;
   - check every frame edge.
7. **Save** through the browser, or in code with `annotate.prepare_review(annotation, image_path)` and an atomic write to `annotations/<frame>.json`.
   - The reviewer must be `codex-agent`.
   - Notes must describe this frame, including what you excluded and why.
   - `sceneObjectsReviewed: true` must only be set after the full-frame check.
   - Saving keeps only `label` and `polygon` and binds the review to the image's SHA-256.

**Test-split frames have no drafts on purpose:** they measure the model, so their labels must not lean on its suggestions. Box-to-outline is fine there (it's geometry, not classification).

**Returned frames:** a file with `returnedForFixes` and `reviewed: false` was sent back. Apply every listed fix (the overlays are in `review-feedback/`), check the whole frame again, and re-save. Saving drops the `returnedForFixes` note.

## Every 25 frames: check, then ask the user

```sh
.venv/bin/python tools/training/annotation_qa.py data/recorder-corpus --queue data/recorder-corpus/full-pass-queue.json \
  --last 25 --model artifacts/pilot-2026-10-12 -o data/recorder-corpus/reviews/<date>-batch-<n>
```

- **Errors** must be fixed before anyone else sees the batch: duplicate or conflicting polygons, two `self_player`s, returned frames not re-saved. The command exits 1 while any remain.
- **Every warning** must be looked at:
  - possible misses: the model sees something nothing covers;
  - no `self_player`;
  - a team-mode frame without an `ally_marker`;
  - tiny polygons.

  Fix it, or say in the frame's notes why it's correct.

Then **ask the user to review** `reviews/<date>-batch-<n>/index.html`. Send:
- the frame count;
- what you fixed after QA;
- your batched questions with crops.

Wait for the answer. Apply the corrections to every affected frame (including earlier ones with the same issue) before continuing, and add any new rule the user gives to this guide.

## Keeping drafts ahead

Drafts cost about 3 s per frame on this Mac, so make them in batches of about 100 a little ahead of where you are. Existing drafts and annotated frames are skipped.

```sh
nice -n 10 .venv/bin/python tools/training/prelabel.py data/recorder-corpus artifacts/pilot-2026-10-12 \
  --queue data/recorder-corpus/full-pass-queue.json --limit 100
```

## Progress

```sh
python3 tools/training/scene_coverage.py data/recorder-corpus --queue data/recorder-corpus/full-pass-queue.json \
  --split-plan data/recorder-corpus/split-plan.json --output data/recorder-corpus/coverage-full-pass.json
```

Retraining happens on Kaggle from reviewed snapshots; see [DATA_WORKFLOW](DATA_WORKFLOW.md) §3–4 and [ANNOTATION_ROUND2](ANNOTATION_ROUND2.md#after-round-2-retrain-then-pick-round-3).

## Lessons from the 2026-10-12 review

The batch of six frames was returned for these mistakes. Don't repeat them:

- **Loot under UI text was deleted along with the text.** About six dropped weapons were lost under "DOUBLE KILL", and a bush was lost under "Gas is Moving Now".
- **A visible character was skipped because its team was unclear.** It is still a `player`.
- **A teammate's name tag wasn't labelled `ally_marker`.**
- **`self_player` was missing** at the viewport centre.
- **A damage number and a rocket in flight were saved as `ground_item`.**
- **The same object was saved twice with different classes,** e.g. an enemy as `player` and as `rock`. Draft polygons were left in when corrected ones were added.
- **One chest was split into lid (`rock`) and body (`chest`).**
- **Wall and door polygons covered the same area.**
