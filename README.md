# Zombs Assistant

A native Mac application for observing ZombsRoyale, recording training data, and running guarded combat, loot, and healing decisions. You control movement.

## Current status

**Beta, October 14, 2026: the assistant aims ahead of moving opponents, fires, switches guns by range, keeps firing for a moment at opponents that walk out of view, fires back at rounds from out of view, carries the sniper or a bow when it's quiet (the close-range gun indoors), reads which gun is on the floor and picks it up when it ranks better, opens chests as soon as you reach them, heals in the best order, heals you and your teammates with Healing Grenades and the Healing Gun, and pulls opponents into grenades, shots or your shotgun with Reverse Impulse combos in real matches, under your supervision.** Every part has been checked offline on recorded matches (see [validation](docs/VALIDATION.md)); a supervised live session is the next step. The detector is still a pilot trained on 138 reviewed Solo frames: on held-out matches it finds players with AP50 0.34, so expect some missed players and an occasional false one. Codex continues annotating ([round 2](docs/ANNOTATION_ROUND2.md)); retrain on Kaggle as reviews land.

What the beta does:

- **Reads the HUD automatically.** No manual regions or templates: it finds the inventory by your locked melee slot and derives the rest. Health and shield come from the bars (within 0.21 points of 56 hand-read values), plus the selected slot, each slot's rarity, ammunition and the interaction prompt.
- **Reads which gun is on the floor and picks it up only when it is better, also while you walk.** The panel under your character names what E will do ("M4 / Rare AR", "Hybrid Potion / Healing"); text recognition reads the gun's name and rarity there, and the name is looked up in [the weapons reference](docs/WEAPONS.md) ranking. Look-alike characters the recognizer mixes up ("MPS" for MP5, "Uzl" for Uzi) and stray marks beside the name still find the gun, but a short name one letter off is never guessed. It works toward your loadout:
  - **Slots:** a sniper, an AR and an SMG, then one slot for a utility item (a Reverse Impulse, grenades, a Grappling Hook) or heals, and one for heals.
  - **Guns:** the class the loadout wants beats any other gun for that range, so even a Common Uzi replaces a Legendary Pump Shotgun. A shotgun still fills an empty close-range slot. Within a class the rarer gun wins outright: a Legendary AK replaces an Epic M4, and a Legendary is used before an Epic of its class in a fight. Between guns of one rarity the ranking decides: an M4 replaces an AK, but not the other way round, and near-equal guns are not swapped. Tier C guns (KSG Shotgun, Hunting Rifle, Glock, P2000) are never picked up, and one you carry is the first to go when a slot is needed, unless it is your only gun.
  - **Utility:** one item, a Reverse Impulse first, and more of it stack. It goes into a free slot that no missing gun needs; heals keep their slots.
  - **Heals:** early in the match (the first 3 minutes) potions are stocked up, even into a slot kept for a missing gun; guns later take back slots from heals beyond the two kept.
  - **When the loadout needs a slot:** a second gun for a range or a tier C gun, then a second utility item, goes first.
  - **Launchers and bows** are never picked up for you, though the ones you carry finish combos.

  The status line names both items ("Pick up Epic M4 in place of Rare AK", "Not picking up Rare AK: not better than Rare M4").
- **Opens chests and crates as soon as you reach them.** Gold, ammo and present chests and crates open with one E press; an Air Drop Chest is held for up to 8 s while you stand at it. It never presses E for doors, vehicles or revives.
- **Heals first below full health or shield; otherwise loots first.**
  - Below full health or shield: a potion on the panel comes first, then a chest (one press, often with more potions), then drinking, then other loot.
  - At full: opening a chest or taking an item comes first, as one key press with no settling pause, because the loot stays behind once you walk on.
  - A drink already under way is never cut short, and a swap into a full inventory, which changes the selected slot, waits for a heal under way.
  - Below 50 health, or below 100 health and shield together (**Low health**), a potion that would help may also take a slot kept for a missing gun, or replace a potion that cannot help now (shields when your shield is full).
- **Switches guns by distance.** Shotgun up close, assault rifle at mid range, sniper beyond, with SMG, DMR, LMG and pistol as fallbacks. A margin around each cutoff and a minimum hold time prevent flapping; an opponent missed for under a second keeps its range band, and distances allow for the sniper zooming the view out. If the magazine empties mid-fight, it switches to another loaded gun before reloading. The cutoffs are adjustable in Settings.
- **Carries the sniper or a bow when it's quiet, and the close-range gun indoors.** With no threat, player in view, round flying at you or opponent just out of view for 1.5 s, and no fight for 4 s, it takes the long-range gun: a sniper, else an XBow or Crossbow, else a DMR or an AR. Most fights start at a distance, and a sniper's or bow's view is zoomed out, so you see more. In close quarters, such as inside a house, it takes the close-range gun (shotgun or SMG) instead. Close quarters means walls or doors within 0.12 view widths on at least 4 of 8 sides, and it lasts 1.5 s after you step out. Bows now also fight at long range, below snipers, though they are still never picked up for you. A slot you pick yourself is left alone for 30 s. Only a change made right after a key, mouse button or scroll of yours counts: the game may change the selection itself, say when a slot's last potion is drunk.
- **Keeps firing at an opponent that walks out of view.** For 1.5 s (**Fire out of view** in Settings), it fires where the opponent's last course takes it, with a mid- or long-range gun or a bow (never a shotgun or SMG). The aim leads it the way it leads opponents in view. The opponent is remembered as you move, and as the sniper's zoom changes the view. It is no longer fired at once it is seen again, or once it would be in plain view and is not there. One lost in the middle of the view (under a roof, or missed by the detector) is not chased, and nothing is fired through a wall, door, teammate or unknown player in view.
- **Tracks bullets and fires back.** Rounds in flight are found on every frame by their look, and each round's color tells its gun: cream on gray for SMGs and pistols, blue with an orange tip for ARs, brown with a green band for snipers, red for shotguns. A round counts once it has been seen in three frames, flying along its own axis at a round's speed. A round flying at you from out of view locates its shooter somewhere back along its path, no farther than its ammunition flies. Rounds from new angles, as you or they move, narrow down where the shooter is and where it is heading. Shooting back:
  - **A sniper's round** is fired back at for 1.5 s (**Fire back** in Settings), with the gun that reaches that far.
  - **An AR's, SMG's or shotgun's round** is fired back at only within 10 s of a fight (**Recent fight**: an opponent engaged in view, a hit taken, or rounds from an opponent in view). Otherwise the status says it is not firing back.
  - **In Duo and Squad**, only once a round has hit you, because your teammates' rounds look the same and the detector does not always see the teammate who fired.

  Your own rounds, and rounds fired by any player in view, never locate a shooter. A round flying at you also delays the next heal by 2 s. The search for rounds runs on its own core while the detector runs on the Neural Engine: about 1 ms per frame at 3,840 pixels wide.
- **Aims ahead of moving opponents.** Bullets were measured on a 30 fps recording at about 1.1 view widths a second, so a shot at mid range flies about a quarter of a second; it aims where the opponent will be when the bullet arrives, plus the time your click takes to reach the game (**Aim lead** in Settings, 60 ms by default). Automatic guns fire whenever that point is in range; single-shot guns wait for a fair chance. The game shoots along the line from your character through the cursor, so the crosshair stays within a circle around you (35% of the view's height; **Crosshair circle** in Settings): an opponent farther out gets the same angle from inside the circle, measured in screen pixels, and no click lands on the window's edges or Chrome's toolbar, where it would resize or drag the window. Nor does a click land on the HUD: where the crosshair would rest on the inventory, a button (settings, sound, fullscreen, the map), the minimap, your vitals or the item panel, it steps back toward you along the same line. It reloads when the readout shows an empty magazine. An opponent in the open always gets a gun: if none suits the range, it holds the one that reaches farthest until it is in range.
- **Heals during safe gaps, in the best order.** It plans all the doses: small shields first while your shield is under 50 (they cannot fill past 50), then hybrids or a big shield, and it does not spend an item that would restore only a few points. A second hybrid waits until the first one's 10 s of healing is over, because the game does not stack their effects. Potions stack: a big shield or med kit to 2 (one on the ground), small shields and hybrids to 4 (two on the ground). The slot's digits are rarely readable, so the assistant counts pickups and drinks itself, including a stack it sees arrive in an empty slot (one ground stack, or the panel's "x4" badge if it was read). A key you press yourself makes the counts uncertain again. It adds to a stack only when it knows there is room. With a full inventory, a stack of uncertain size is left alone, because the game would swap the item in hand for the potion if it does not fit; only an item the loadout has no place for is selected first. With a full inventory and a potion on the ground worth drinking now (a Big Shield at half shield, say), it lends a slot for the drink: your utility item first, else the gun you would miss least. It drinks that potion before the ones you carry, then picks the lent item up again. Storm ticks do not interrupt a heal; a visible opponent or a hit does. While it heals, a **STOP MOVING** label appears above your character.
- **Heals you and your teammates with a Healing Grenade or the Healing Gun.** Both restore health only, and both are used on someone below 50 health (**Low health** in Settings), never with an opponent in the open: that always gets a gun first.
  - **Healing Grenade:** thrown at your feet when you are low, or at the feet of a low teammate it can reach. A teammate beside you who is low too gets it halfway between you, so the circle takes you both. Measured on a recorded Duo match, it lies on the ground for about a second, then a circle 0.118 view widths in radius heals everyone of your team inside it, about 20 health a second (+5 four times a second) for 4.5 s, so up to about 90 health. One throw is enough, so it goes as soon as no opponent is in the open, without the two-second gap a potion waits for. Nobody standing in a circle of yours gets another heal while it lasts, and potions do not top up health the circle is about to restore (shields still come next). A green **STAY IN THE CIRCLE** label above your character counts down while it heals you, and says **BACK INTO THE CIRCLE** when you walk out.
  - **Healing Gun:** its rounds heal whoever they hit, 12 health each. It fires a round at a time at a low teammate in its range, leading them as they move, and only with nothing on the way: no wall, tree or rock, and no other player, who would take the round (perhaps an opponent). Its rounds bounce off walls, so when you are low, in a safe gap, it fires square at the nearest flat wall face between 0.045 and 0.15 view widths away, along the screen's axes as buildings stand, and the round comes straight back to you. That needs you to stand still: **STOP MOVING** shows meanwhile, and nothing is fired while you walk. It stops within one round of full health, and gives up for 10 s on rounds that raise nobody's health for 1.6 s. It is never used to fight or to finish a combo, and like launchers and bows it is never picked up for you; its panel reads "Healing Weapon / Epic Unique".
  - **Your teammates' health** comes from the roster above your name: each teammate's row has a thin shield bar over a health bar, green while they are up and red while they are knocked down. A teammate on screen is matched to their row by the name tag above their head. A knocked-down teammate needs a revive, not a heal, and counts as down until their bar has been green for a second. On recorded Duo and Squad matches the bars read on 99% of Duo frames and all three rows on 87% of Squad frames, also with the storm's orange behind them, and a teammate's map pin over a bar is read past.
- **Reverse Impulse combos, without hurting you.** With a Reverse Impulse Grenade in your inventory and an opponent in range, it pulls them to a spot where something is waiting:
  - **Rev-nade:** a Frag thrown first, with the pull timed to land them on it just before it explodes; an RGD-5 follows the pull instead.
  - **A timed shot:** an RPG, Gift Launcher, XBow, Crossbow, sniper or DMR shot timed to arrive as they land.
  - **Pulled into the open:** for an opponent behind cover, any gun.
  - **Tight quarters:** an opponent round a corner or behind a door is pulled through it to your feet, into your shotgun or SMG.

  Explosions hurt you too, so it never throws a Frag or RGD-5 near you, never pulls you into your own blast, and never throws at a wall the grenade would bounce back from. It never fires an RPG, Gift Launcher or Assault SCAR round at anything close to you. While one of its grenades is about to go off, a red **GRENADE OUT** label above your character says to keep clear. Grenades land where you click, so throws stay within their own **Grenade circle** (60% of the view's height by default; at its largest in Settings, the whole screen). They also stay at least 6% of the view's height from every edge, and off the HUD. **Reverse Impulse combos** in the dashboard turns it off. Details are in [the weapons reference](docs/WEAPONS.md#reverse-impulse-combos).
- **Respects teams.** In Duo and Squad, a player whose name tag matches your team roster is a teammate; only players without a matching tag become enemies, and unknown players are never fired on. Each teammate's health and shield are read off their roster row; the dashboard lists them. In Solo every other player is an enemy and no name tags are read; if a teammate roster stays visible for two seconds, the dashboard warns that Solo is selected.

Items are identified from a catalog (`AssistantCore/Catalog.swift`) and from inventory icons learned from pickups. The catalog holds weapon classes, 39 named guns with their ranking and wiki stats, consumables, and 15 grenades and other throwables by name. A grenade is thrown only when its name is known; a grenade icon that matches two grenades about equally stays unnamed. A gun whose name is read ("M4") gets that gun's fire rate, reload, ammunition and ranking; one whose name is unknown, or whose icon matches two guns of its class about equally, counts as an average gun of its class. Icons are learned from pickups: when a slot changes right after a prompt, that icon is labeled with the prompt's item. Icons were pre-learned from all 33 recordings, and the library keeps learning from your pickups. A selected tile is drawn larger with a highlight; that is treated as the same item, never as a pickup, so selecting a potion can no longer relabel it (this used to teach the library that a hybrid was an AR-15 and a small shield a grenade; those entries were removed on October 11). When the panel shows a consumable's "Left Click to Consume" hint, it names the item in hand (it never relabels a gun), and an ammunition readout overrules a consumable label on the selected slot.

Still estimated or unverified:

- Fire rates, reloads and ammunition of named guns come from the ZombsRoyale wiki, not measurement; ranges, zoom and bullet speeds are still class estimates. Bullet speeds were measured for a pistol, a minigun and an Epic sniper only; the other classes use the same 1.1 view widths a second. The click-to-game delay (**Aim lead**) is an estimate to tune.
- Grenade timings and sizes are estimates: the Frag's 2 s and the RGD-5's 0.5 s fuses come from the wiki, and the Reverse Impulse's 0.5 s is assumed equal to the Impulse's. Blast and pull radii, how long a pull takes, rocket and arrow speeds, and whether a throw lands exactly where you click have not been measured. No recording contains a Reverse Impulse being thrown, so combos are tested on constructed fights only.
- The Healing Grenade's circle (radius, heal rate, 4.5 s) was measured on one recorded throw; the delay before it opens is an estimate between 0.9 and 1.8 s (1.2 s is used), and its throw range is the other grenades' estimate. No recording shows the Healing Gun fired: its fire rate (one round every 0.5 s is assumed, clicked once per round), bullet speed and range are estimates, and whether its rounds bounce back off every wall face is the wiki's word, so the assistant stops bouncing when your health does not rise.
- Whether a potion needs the mouse held or one click is not visible in recordings; the assistant holds it for the drink's measured time, which works either way. Whether an air drop needs E held is inferred from its 5 s countdown.
- Native input reaching the game, aim mapping on your display, and the speed gate have not been checked in a live match.
- Rounds and shooters out of view were checked on recordings only (see [validation](docs/VALIDATION.md)):
  - How far each kind of round flies, and how far its shooter usually stands, are estimates (`EnemyMemory.reach` and `typicalDistance`).
  - Arrows and rockets are not recognized as rounds.
  - Close quarters relies on the pilot detector's walls, its weakest class: it misses some, and now and then it takes a large object outdoors (a plane wreck, a pod) for walls around you.
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

Input can be enabled once a detector is installed, Settings are verified, and the pipeline sustains at least 15 updates/s with p95 latency ≤100 ms over at least 100 frames. The release target remains 20 updates/s. The detector's 960 × 768 model runs entirely on the Neural Engine, its float16 input and outputs included; only scaling the frame into it uses the GPU. Replaying recorded 3840 × 1736 frames on an 8 GB M1, with text recognition running as in a match, a frame takes about 8.4 ms (median; 9.3 ms p95), against 13 ms before October 14 and 27 ms with the earlier 960 × 960 export, so the pipeline keeps up with 60 Hz captures. The assistant acts only during a live match: when your inventory is visible, the game window is focused, and frames are fresh.

**Enable supervised input** turns input mode on. **=** in the game then starts and stops sending input, with a sound each time. A click-through label over the game shows the state and what the assistant is doing; it is not part of the capture. Input is sent only while Chrome is the active app; in any other app it pauses and resumes when you return. Holding Option yields control; pressing Command or Control (for example Cmd-Tab) lets go of every held input first, so a held E or mouse button is released in Chrome. Escape stops input until you press **=** again, and the dashboard says why input stopped. If ZombsRecorder is running, **=** also starts or stops its recording. Manual item keys, mouse buttons, and scrolling yield until released plus 750 ms. Movement passes through unchanged. Focus loss requires manual rearming. Resizing stops capture until it is restarted.

The bot never has a movement action. It presses the interact key when the prompt names a recognized gun, consumable or grenade and the pickup improves your loadout, or a chest or crate. A pickup is done when the inventory gains the item or the item leaves the panel (stack counts are rarely readable). An item or chest still on the panel 0.6 s after a press was a press the game missed: it is pressed again, three times in all, and then left alone for three seconds. With a free slot, the game fills it. With a full inventory, the slot to replace is selected first, because the game swaps out the selected item; interact follows as soon as the selection shows, without a weapon's switch delay. Launcher and bow pickups, doors, vehicles and revives stay manual. Grenades are picked up for the loadout's one utility slot, and a combo throws them by clicking where each should land, never near the window's edges or on the HUD. Every key tap is held for 60 ms. Earlier, the next frame's decision released it after about 18 ms, short enough for a game that samples keys once per frame to miss below 60 fps.

The prompt is read with Vision in the background, about 40 ms per read on this Mac (recorded panels, also with the detector running). The panel is translucent, so the map scrolls behind it while you walk; the read is matched to the screen by a mask of the panel's bright text, which the map does not change. On recorded matches the earlier pixel match kept a read only 30% of the time while walking (so walking over items rarely picked them up); the text mask keeps 90%, and stays apart from different text: across 607 recorded panels, the same gun at another rarity overlapped at most 0.72 and two different guns at most 0.77, below the 0.8 a match needs.

Item/slot changes are acknowledged from later frames. Healing starts after a two-second gap with no threat and no confirmed player in view, even one behind a wall, and no chest or wanted item on the panel, when a dose is worth its item (`HealPlanner`): each dose earns the points it restores, minus what the item is worth keeping for later and half a point per second of drinking, planned over the whole sequence. Once started, a heal is carried through: selecting the item, holding it for its drink time, and further doses (possibly of another item) while they still help; a started plan keeps going down to doses of a point or two, so a wobbling bar reading cannot start and stop it. Clicking with a gun in hand would fire it, so a dose starts only once the potion is confirmed in hand: the ammunition readout is read and shows no rounds (over the moving map this mostly happens once you stand still; the status then says "Stand still: checking that … is in hand"), or the panel shows the potion's "Left Click to Consume" hint, which the game shows only now and then. A readout showing rounds cancels the heal. A dose counts as done when the slot empties, or when its drink time has passed and health or shield rose; stack counts are not needed, because Vision rarely reads the small digits. A hybrid's health and shield arrive over about 10 s, and the plan counts them as on their way. Only an opponent in the open, a hit (shield lost, or five health within 0.3 s), or your own slot change ends a heal early, and the assistant then switches straight to the gun for that range; storm ticks and a briefly unreadable HUD do not. A player counts as confirmed after three detections over at least 0.12 s, so brief false detections do not interrupt it either. If heal selections keep failing to start a dose, healing pauses for 8 s instead of switching back and forth. While the assistant heals, a click-through **STOP MOVING** label appears above your character. Weapon recovery after a temporary heal swap uses the dropped weapon's prompt; remaining consumable stacks are retained.

Combat predicts each opponent's motion with a Kalman filter over the ground. Your own
movement is measured from how static scenery shifts on screen, so it is separated from
the opponent's. Bullets do not carry your movement (user-confirmed), so the lead for the
bullet's flight uses the opponent's ground velocity, and the frame delay plus the click's
latency use its on-screen velocity. Bullets fly about 1.1 view widths a second (pistol and
minigun measured; an Epic sniper's 1.05 in its zoomed-out view), so the flight is solved
for the meeting point. Players strafe and turn, so the lead fades over about a second of
flight instead of assuming they hold course. Automatic guns fire whenever the predicted
point is in range and the path is clear; single-shot guns wait until the estimate gives a
fair chance of the bullet passing within the opponent's body radius (15% for shotguns,
12% for pistols, 6% for DMRs and snipers). It can fire toward enemies behind bushes,
trees, and rocks, although those objects still block bullets. Walls, doors, chests, allies,
and unknown characters still block firing. A sniper zooms the view out about 1.2×, so
distances and ranges are converted to the default view.

Opponents out of sight are kept by `EnemyMemory` (AssistantCore/Memory.swift), each as a Kalman filter over
position and velocity whose velocity fades like the aim's lead. A remembered position moves with the scenery's shift as
you move, and scales with the sniper's zoom. One that walked out of view starts from its track. A shooter out of view is
located from its rounds. Each round says the shooter stood on the line back along its path, within its ammunition's
range. That is a measurement across the line, so rounds from several angles locate the shooter where the lines meet.
Firing at one is its own intent (`fireUnseen`). The input guard lets it through only with a mid- or long-range gun or a
bow, aimed the same way as the opponent's estimated position. No wall, door or chest may stand before that position, and
no teammate or unknown player anywhere on the line to the view's edge, since the round flies on past it.

Rounds are found by `BulletDetector` (Perception). The frame is sampled about 1,920 times across for dark outline pixels,
which are joined into outlines. An outline of a round's size and proportions is kept when its two halves, read at full
resolution, show an ammunition's colors; the tip end gives the way it flies. A pale trail behind it confirms the
direction and shows where it fades out. `BulletTracker` follows rounds across frames with the scenery's shift. It counts
a round once it has been seen three times, moving along its axis at 0.75 to 1.6 view widths a second, which ammunition
boxes, names and red flowers never do.

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
- `tools/training`: recording import, annotation UI, dataset preparation, Kaggle training/export, evaluation, and per-class threshold calibration (`evaluate.py --calibrate-thresholds`). `ingest_recordings.py` pulls Zombs Recorder matches into an annotation corpus; `select_frames.py`, `prelabel.py`, `outline.py` and `annotation_qa.py` build queues, model drafts, box-to-outline polygons and review pages. Annotators follow the [annotations guide](docs/ANNOTATIONS_GUIDE.md).
- `ZombsRecorder`: a separate SwiftPM package. It is a recording-only menu-bar app for you and friends: pressing **=** in the game records each match as hardware-encoded video, which is uploaded to a private Kaggle dataset. `make-friend-kit.sh` packages it with a setup guide for a friend's Mac. See [ZombsRecorder/README.md](ZombsRecorder/README.md).

## Research references

The design was informed by the [current game](https://zombsroyale.io/), [HackerHansen's archived experiment](https://github.com/HackerHansen/Zombsroyale.io-Aimbot-v2), and the [Surviver_dot_IO computer-vision project](https://github.com/KevinUTAT/surviver_dot_IO). The latter targets a different game. None of those projects' executable files or source code are included here.
