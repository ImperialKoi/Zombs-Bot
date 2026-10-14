# Validation status

Updated October 14, 2026 on this Apple silicon Mac (8 GB M1).

## Healing Grenades, the Healing Gun and teammates' health, October 14

You asked for:
- the Healing Grenade thrown onto the ground at your feet, or at a teammate's feet when they are low on health;
- the Healing Gun used on low teammates, and bounced off walls back to you to heal yourself.

This was checked offline only.

**Measured on recordings:**
- **Healing Grenade**, two throws in Duo `1EF797`:
  - The prompt reads "Healing Grenade / Legendary Grenade", with an "x2" badge. With one in hand the ammunition readout shows a bare count ("4").
  - Thrown at a teammate who had just been revived (health 30), it lay on the ground about a second, then a lime circle opened. A circle fitted to it in every frame had a radius of 341 px at 2880 wide, 0.118 view widths, the same in every frame, for 4.5 s.
  - The teammate's roster bar rose from 35 to 100 in 2.8 s while a Hybrid Potion added its 2.5 a second. The circle gave about 20 health a second, +5 four times a second, and no shield.
  - The delay before the circle opens lies between 0.9 and 1.8 s across the two throws; 1.2 s is used.
- **Healing Gun**, a pickup in Duo `212F9A` and one on the ground in Solo `C65233`:
  - The prompt reads "Healing Weapon / Epic Unique", not "Healing Gun".
  - In hand, the readout is a bare "8" and the slot prints "8", so it does not count as a gun in hand.
  - No recording shows it fired: the fire rate (0.5 s), bullet speed and range are estimates, as is the bounce, which comes from the wiki.
  - The earlier code took this pickup for the Frag Grenade whose prompt had just been on screen. The **Duo `212F9A`** entry of October 13 below calls it a Frag. Neither icon library had learned that label.
- **Teammates' roster rows**, 2880×1376 Duo and Squad matches:
  - Each row has a shield bar over a health bar, starting 0.394 tiles from the left and 2.564 tiles long at 100%. The bars are centred 2.63 and 2.37 tiles above the bottom, rows 0.945 tiles apart.
  - Fill colours are the same in every match: health green (119, 203, 61), shield magenta (213, 86, 239), knocked-down red (209, 56, 58).
  - In `1EF797` the bar turned red exactly while the teammate was down, from the hit at 86 s to the revive at 103.6 s, and came back green at 30.

**Reading teammates' health** (`HUDReader.rosterVitals`, `Observation.squad`):
- Duo `1EF797`: 866 of 872 live frames read. Squad `26EE15`: all three rows on 421 of 486. Values followed knock-downs, revives, potions and the grenade.
- The map shows through empty bars. Over the storm's orange, an empty shield track looks like (165–173, 56–102, 18–28). A loose colour test read those as fills; the exact fill colours do not.
- A teammate's blue map pin, with its shadow 0.68 tiles wide, sometimes sits on a bar. It had read a full bar as 62–68 in 107 Squad frames; the fill now continues past such a gap. Six of those frames were checked by eye: every bar was full.
- A revive starting flashes the red bar green for one frame. That one frame had led to a throw at a teammate still down. A teammate now counts as down until their bar has been green for 1 s.
- Teammates on screen take their roster row by the name tag the app already reads (`AffiliationTracker.name`). In Duo the single row is theirs.

**Decisions** (`Coordinator.supportStep`): both items heal health only, and both are used below **Low health** (50, now a Settings slider), never with an opponent in the open.
- **Healing Grenade:**
  - At your feet: one click, so it needs no two-second safe gap. Halfway to a low teammate beside you, so the circle takes you both.
  - At a low teammate's feet, a moment ahead of where they are moving.
  - Nothing is thrown through a wall. An obstacle reported where you or the teammate stand is a character the detector misread; it does not count.
- **Healing Gun:**
  - At a low teammate, a round at a time, leading them, with no wall, tree, rock or other player on the line.
  - When you are low, in a safe gap: fired square at the nearest flat wall face 0.045 to 0.15 view widths away. Flat means rays 0.02 view widths to either side meet the same wall within 0.004. It fires only while you stand still.
  - It stops within one round of full health, and gives up for 10 s when its rounds raise nobody's health for 1.6 s.
- Circles of yours count as health on its way: nobody in one is healed again, and potions do not top up what it will restore.
- The Healing Gun never fights or finishes a combo, and is never picked up for you. In the loadout it takes one of the two slots kept for heals and utility, but it is never the item that makes way.
- The input guard checks every heal throw (someone of your team inside the circle, no opponent in the open) and every heal shot (a teammate's lead point with a clear line, or the computed wall point while you stand still).

**Tests.** 179 Swift tests pass, 14 of them new:
- 12 core tests:
  - the grenade at your feet, with its circle;
  - waiting for real need and no fight;
  - at a teammate's feet, and halfway between you;
  - the gun on a teammate until nearly full;
  - rounds that heal nobody;
  - no shot past anyone or through cover;
  - the wall bounce and the walls that will not do;
  - never fighting or finishing a combo;
  - the gun's heal slot;
  - the prompts as recorded;
  - roster names on tags.
- 2 perception tests, on new fixtures cut from the recordings:
  - a hurt teammate (30 health, 49 shield), one knocked down, and three rows over the storm with a pin;
  - the revive flash.

**Replays** (`ZombsPerceive --decide` without the detector, HEAD's build against this one, same frames):
- Solo `582E17`, `78E1A3` and `090BC4`, Duo `F91B95`, Squad `26EE15`: no decision changed in 4,272 frames.
- Solo `C65233` and Duo `212F9A`: only the status line. A Healing Gun on the floor is now named and left to you. An Airstrike is skipped as "inventory full" instead of for a utility slot holding a Frag that was not there.
- Duo `1EF797`: the one new decision is at the end of the match. The storm took you from 68 to 38 health with no opponent in view, and the Healing Grenade was selected to heal you. The recording never answers the keys, so the selection timed out.
- With the detector, Duo `1EF797` also threw at the teammate at 110.6 s, at 32 health, just as the player did. It no longer threw during the revive's green flash at 95 s.

**Still open:** the Healing Gun's fire rate, speed, range and bounce; the grenade's delay; and all of it in a live match.

## Grenade circle, safe clicks and the loadout, October 13

You asked for:
- a circle of its own for Reverse Impulse throws, at its largest a rectangle close to the screen's edges but safely clear of them;
- no click ever landing on the inventory or another button;
- a loadout to work toward: sniper, AR, SMG, a utility item (grenades, Reverse Impulses, a Grappling Hook) or heals, then heals. The assistant may still drop a gun or other item for a potion it needs, drink it, and pick the item up again.

This was checked offline only.

**Clicks:**
- **Grenade circle.** Throws have their own circle (`CombatSettings.throwRadius`), 60% of the view's height by default. In Settings, **Grenade circle** goes from 20% to "all", which is the whole screen inside the margin.
- **Edge margin.** Throws stay 6% of the view's height away from every edge.
- **No-click areas** (`HUDLayout.noClick`): the settings, sound and fullscreen buttons; the map button, minimap and match stats; name, ammunition and vitals; the inventory and its ammo counters; the item panel; the team roster.
  - They were measured on a 3840×1736 Solo frame and a 2880×1376 Duo frame and padded. Drawn over both frames, every button, the inventory, the minimap and the roster lay inside.
  - The detector's existing HUD exclusions were too small for clicks: the fullscreen button reaches 2.7 tiles from the left, against an exclusion of 1.7, and the map button sits left of the minimap's exclusion.
- **No throw is aimed at those areas.** Where the crosshair would rest on one, it steps back toward you along the same line, so the shot keeps its direction. A potion click goes on your character instead.
- **The preview** draws the margin, the no-click areas and the grenade circle.
- **Walls.** A throw's reach now also stops at the first thing in the way. With the longer circle, the spot for an opponent behind a wall had fallen on the far side and was given up. It now lands on your side, and the pull brings the opponent through.

**Loadout:**
- **Guns:** a gun of the loadout's class for its range (sniper, AR, SMG) beats any other there. A Common Uzi replaces a Legendary Pump Shotgun, an AR a pistol, a sniper a DMR. A shotgun still fills an empty close-range slot. Within a class, the ranking decides as before.
- **Utility:** one item, from the named grenades and the Grappling Hook. The Reverse Impulse ranks first, then the Frag, RGD-5, Sticky Bomb and Grappling Hook, then the rest; the ranking is a judgement.
  - It takes a free slot that no missing gun needs, replaces a weaker one, and stacks more of the same.
  - Stacks are counted like potions, and each throw is counted.
  - The Grappling Hook's prompt ("Grappling Hook / Legendary Unique") is recognized.
- **What the loadout has no place for goes first** when a slot is needed: a second gun for a range, then a second utility item. A missing gun may also take the slot of the weaker of two heal stacks. The setting **Keep 2 slots for heals and utility when picking up a missing gun** now counts the utility item.
- **Heal swaps** lend your utility item first, else your weakest gun, and pick it up again after the drink.
- **Combos:** an SMG now also finishes the pull at your feet, firing as the opponent arrives, because the loadout carries one instead of a shotgun.

**Tests.** 165 Swift tests pass, 7 of them new:
- the SMG at your feet;
- a combo spot kept off the HUD;
- clicks clear of the edges and the HUD, and the crosshair stepping back off the item panel;
- the loadout's classes;
- the one utility item: free slot, replacing a weaker one, stacking, the Grappling Hook, unknown grenades never;
- what makes way first;
- the utility item lent for a Med Kit and picked up again.

Two earlier combo tests changed with the longer reach. The rev-nade's spot is now on the opponent rather than at the crosshair circle's edge. The guard now permits a throw past the crosshair circle, though not past the grenade circle.

**Replays** (`ZombsPerceive --decide`, before and after, same frames). The recordings never answer the assistant's keys, so a swap it asks for is asked again and again; live, the first one would complete.
- **Solo `582E17`:**
  - A Frag on the ground stacked onto the Frags carried ("Pick up Frag Grenade: 3 of 9 held"), and a Snowman Grenade was skipped because the utility slot held the Frag.
  - An Uncommon M4 was no longer taken as a third mid-range gun. Before, it was compared only with the weaker of the two ARs held, an Uncommon AK; now it is compared with the better one, a Legendary AR.
- **Solo `C65233`:**
  - The player carried a Legendary P90 and an Epic Pump Shotgun. An Epic P90 no longer replaced the Pump, which would have left two P90s.
  - The Pump, the gun the loadout has no place for, made way for a Hybrid Potion, a Small Shield and a Reverse Impulse.
  - More Frags stacked.
- **Duo `212F9A`:**
  - The inventory held an AR-15, a Frag, a Small Shield, an unrecognized item and a Med Kit, with no close-range gun. An Uzi, a UMP or a KSG now takes the Small Shield's slot; before, all of them were skipped as "inventory full". The unrecognized item is never touched.
  - An Airstrike was skipped because the utility slot held the Frag.
- **Duo `1EF797`:** more Healing Grenades stacked onto the one held ("2 of 6 held"). A Grappling Hook and an RGD-5 each counted as better utility. With a slot free, each went into it, and the Healing Grenade became the spare that a later gun or heal would replace.
- No recording has a Reverse Impulse in its inventory, so nothing was thrown.

## Reverse Impulse combos and explosions, October 13

You asked for Reverse Impulse combos and for the assistant to know that explosions hurt you too. The combos pull an opponent into a Frag or RGD-5, into a sniper, XBow, rocket, Gift Launcher or AR shot, or close to your shotgun round corners and doors. This was checked offline only.

**What the game does,** from the ZombsRoyale wiki and a text-recognition pass over all 33 recordings (25,325 frames, 4,011 prompts):
- A grenade lands where you click and cannot be cooked. A Frag goes off about 2 s after the throw; an RGD-5 or an Impulse about 0.5 s after.
- The wiki's "rev-nade" is a Frag first, then a Reverse Impulse on the same spot. An RGD-5 goes after the Reverse Impulse instead.
- A Reverse Impulse pulls every player nearby to where it landed, the thrower and teammates included, even through walls.
- **Prompts as recorded:**
  - "Reverse Impulse / Common Grenade". The name has no "Grenade".
  - "Frag Grenade / Common Grenade", "RGD-5 Grenade", "Sticky Bomb / Epic Grenade".
  - RPGs say "Rare RPG".
  - The Crossbow, Gift Launcher, Grenade Launcher, Minigun, Flamethrower, Shuriken, Goo Gun and Grappling Hook all say "<rarity> Unique". The parser did not read that as an item, so a Crossbow or Gift Launcher could never be recognized.

**Changes:**
- **Grenades by name.** The catalog has 15 throwables, each with what it does (pull, push, blast or other), fuse, radius and throw range. A grenade on the panel or in a slot gets its own ID instead of a generic "throwable". The parser reads "<rarity> Unique" for launchers, bows and throwables. The XBow and Gift Launcher are new named weapons. The RPG, Gift Launcher and Assault SCAR got explosion radii.
- **Combos** (`Combos.swift`). They need a Reverse Impulse in the inventory, and use the best finisher held:
  - a Frag, thrown first, then the pull 1.15 s later at the same spot;
  - an RGD-5, thrown 0.35 s after the pull;
  - an RPG or Gift Launcher, or one XBow, Crossbow, sniper or DMR shot, fired so it arrives as the opponent lands;
  - a shotgun, with the pull at your feet, for an opponent round a corner or behind a door;
  - any other gun, only for an opponent behind cover.

  Combo spots stay inside the crosshair circle, because the game throws to the click. The spot is planned when the grenade is in hand. It is then followed on screen as you move, using the scenery's shift, now passed from the scene tracker, and through the sniper's zoom. Every later step checks again that it is still safe and worth it. Your own slot change, losing the opponent, or 4 s in all ends a combo; the next one waits 3 s.
- **Explosions hurt you too:**
  - A blast never lands within its radius plus 0.04 of you, counting your movement until it goes off.
  - A pull either lands at your feet or out of your reach. It is never thrown when it would drag you into your own Frag; it is checked again if you walk toward the Frag.
  - Grenades are never thrown through anything solid, where they would bounce back, or where they would catch a teammate.
  - Exploding rounds (RPG, Gift Launcher, Assault SCAR) are never fired when the target, or anything on the line, is that close to you. In an ordinary fight, another gun is taken instead of the Assault SCAR point-blank.
  - The input guard checks each throw (`throwAt`) and each shot at the spot (`fireAtPull`) again by itself.
  - The input driver clicks exactly on the spot and holds the cursor there until the button is up.
- **Dashboard:** a **Reverse Impulse combos** toggle; a red **GRENADE OUT** label above your character while one of the assistant's grenades is about to go off; the throw spot drawn on the preview.

**Tests.** 158 Swift tests pass, 17 of them new:
- the rev-nade's order and timing;
- the RGD-5 after the pull;
- a sniper shot timed through the zoom change;
- any gun only for an opponent behind cover;
- the shotgun pull through a door;
- no blast near you;
- no pull into your own Frag after you walk toward it;
- giving up on an opponent who runs off;
- nothing thrown into a tree;
- exploding rounds near you;
- the input guard refusing unsafe or pointless throws: at a gun in hand, beyond the circle, at nobody, at a teammate, unknown grenades, an Impulse, through a wall;
- recorded prompt texts;
- the cooldown, and your own slot change ending a combo;
- a spot followed on screen, through every frame of a slot switch;
- the icon library never taking one grenade for another.

The synthetic replay fixtures still give 4 proposed actions, 1 fire and 2 pickup presses, with 0 guard rejections.

**Replays** (`ZombsPerceive --decide`, seeded icon library), on the four recordings that carry grenades:
- Frags are now named in the inventory: Solo `582E17` (200 slot-frames), Solo `C65233` (133) and Duo `212F9A` (788).
- Duo `1EF797`: its Healing Grenade (797) and Epic RPG (559) are named. So is the Rare RPG in `582E17`.
- No recording has a Reverse Impulse in the inventory, so no combo started and nothing was thrown. What these replays check is that grenades are now named, and that a Healing Grenade, an Impulse or an unknown grenade is never thrown.

**Unverified live:**
- **Estimates:**
  - the Reverse Impulse's 0.5 s fuse (assumed equal to the Impulse's);
  - how long a pull takes (0.3 s);
  - the radii: Frag 0.08, RGD-5 0.065, pull 0.09, RPG 0.07, Gift Launcher 0.04, Assault SCAR 0.035 view widths;
  - rocket and arrow speeds;
  - that a grenade lands exactly where you click within the circle.
- Whether the game throws on the button going down or up. The click is held 60 ms with the cursor kept still, which works either way.
- Whether the Reverse Impulse moves you when it lands at your feet.
- Duo and Squad: a pulled opponent may need a new name-tag read before a gun follows up there. Grenade combos do not need one.
- The Reverse Impulse's icon is not in the icon library yet. Picking one up while its prompt is read teaches it, and until then a Reverse Impulse in a slot is not used.

## Potions first when low, and stack sizes, October 13

You asked for potions to come first when you are low on health. You also gave the stack sizes: big shields stack to 2, small shields and hybrids to 4, which is two ground pickups. This was checked offline only.

**Changes:**
- **Low on health** means under 50 health, or under 100 health and shield together (`CombatSettings.lowHealth`).
  - A potion on the panel that would help is picked up first, even into a slot kept for a missing gun.
  - With a full inventory, a potion that cannot help now (shields when your shield is full) is swapped for it.
  - Drinking then goes before any other loot, including during a heal's slot switch.
  - When you are not low, loot still goes before heals, as before.
- **Stack sizes** come from your list and the wiki: Big Shield 1 on the ground and 2 at most, Small Shield and Hybrid 2 and 4, Med Kit 1 and 2, Bandage 8 and 8. The slot's digits are rarely readable, so the assistant counts stacks itself:
  - its own pickups, using the panel's "x2" badge if it was read while the item was on the panel, else one ground stack;
  - stacks it sees arrive in an empty slot, including yours;
  - each drink.

  A key you press yourself makes the counts uncertain again. A potion joins a stack only when there is known room.
- **Full inventory and a stack of uncertain size:** the potion is left alone. The game would swap out the selected item, perhaps a gun, if the potion does not fit. That the game swaps on a full stack is inferred, not observed.
- **Hybrids one at a time.** A second hybrid waits until the first one's 10 s of healing is over, because the wiki says their effects do not stack. Other potions can be drunk meanwhile.
- Previously a held potion was always picked up "to stack", even when its stack was full.
- **Use times now follow the wiki:** Big Shield 5 s (was 4), Med Kit 5 s (was 6), Bandage 2.2 s (was 2.5). The wiki's 2 s for small shields and hybrids matches the progress ring measured on recordings.

**Tests.** 141 Swift tests pass, 9 of them new:
- the low-health threshold;
- a potion taking a slot kept for a gun;
- drinking before other loot only when low;
- stacks filling to 2 and 4 and no further;
- a stack of uncertain size left alone in a full inventory;
- a stack seen arriving, and a key you press;
- a badge read in an earlier frame;
- a useless potion swapped for a useful one;
- a second hybrid waiting out the first.

One earlier test changed. A chest no longer opens during a heal's slot switch when you are low; at 60 health it still does.

**Replays** (`ZombsPerceive --decide`, seeded icon library):
- **Solo `78E1A3`.** At 59 health and no shield, a hybrid on the panel was taken with "Pick up Hybrid Potion: low on health". Stack counts showed on pickups ("Small Shield: 2 of 4 held", "Big Shield: 1 of 2 held").
- **Solo `582E17`.** A Med Kit was first skipped, because the inventory was full and the held Med Kit's count was unknown. Counting stacks seen arriving fixed that: "Pick up Med Kit: 1 of 2 held".
- The recordings do not respond to the assistant's keys, so its presses repeat and its selections time out there.

**Unverified live:**
- whether the game swaps the item in hand for a potion whose stack is full;
- whether a hybrid during another's effect is really wasted;
- the wiki's use times for the big shield, med kit and bandage.

## Faster chests and pickups, October 13

You reported waiting beside chests for them to open, and longer for gun pickups. This was checked offline only.

**Text recognition is not the delay.** Vision's accurate mode was timed on the prompt panels of six recordings (104 distinct prompts):

| Panel width | Read time (median) | Notes |
|---|---|---|
| 486 px (3840-wide window) | 37 ms | 43 ms while the detector replays a match alongside |
| 374 px (2880-wide window) | 23 ms | |
| 243 px (half size) | 26 ms | 60 of 60 chests and items parsed |

- Every chest and item was parsed correctly at full size, and every gun was named.
- Vision's fast mode takes 8 ms but misread 41 of 91 chests and items, so it is not used.

**Root causes of the waits:**
- **Taps cut short.** Every key tap was meant to last 35 ms, but the next frame's decision, about 18 ms later, released it. A game that samples keys once per frame can miss such a press below 60 fps. A missed chest press then waited 1.5 s plus a 3 s block before the next try; a missed pickup waited 1.2 s plus 3 s.
- **Settling pauses.** After every chest (0.3 s), pickup (0.2 s) and missed slot switch (1 s), chests and pickups waited too.
- **Heals first.** In a safe gap, heals started before loot and held it up for seconds: selecting the potion, checking it is in hand, drinking.
- **Stacks never confirmed.** A consumable stack was confirmed only by a larger count, which Vision rarely reads, so stacks hit the 1.2 s + 3 s path.

**Changes:**
- Taps last 60 ms. Per-frame releases leave a tap alone until then; taking over, focus loss and Escape still release at once.
- Chests and items for a free slot go before heals, settling pauses and a slot switch on its way. Swaps into a full inventory still wait for a heal under way and for settling, because they change the selected slot. A drink under way is never cut short.
- The next item or chest on the panel is dealt with in the same frame a chest opens or an item is taken.
- A pickup is done once the inventory gains the item or the item leaves the panel.
- An item or chest still on the panel 0.6 s after a press is pressed again, three presses in all, then left alone for 3 s.
- A swap presses interact as soon as the slot shows as selected, without the weapon's switch delay.
- Gun names read by OCR also match through look-alike characters ("MPS" for MP5, "Uzl" or "Üzi" for Uzi, "AVVP" for AWP) and stray marks ("KSG Shotgun Z", read so in a recording). No two guns of a class share a look-alike spelling, which a test checks.
- The status line names both guns: "Pick up Epic M4 in place of Rare AK", "Not picking up Rare AK: not better than Rare M4".

**Replays** (`ZombsPerceive --decide`, before and after, same frames; an episode is a run of frames whose panel names one chest or item):

| Match | Episodes | Acted on, before | Acted on, after |
|---|---|---|---|
| Solo `78E1A3` | 92 | 22 | 45 |
| Solo `582E17` | 57 | 19 | 33 |

- The Air Drop Chest hold started at once instead of after 0.6 s of settling.
- Most remaining episodes are deliberate skips: a gun not better than yours, launchers, a fight, a full inventory.
- Others are replay artifacts: the recording never shows the slot switches the assistant asks for.
- **Prompt masks.** Across 607 recorded panels, the same gun at another rarity overlapped at most 0.72, and two different guns at most 0.77, below the 0.8 a match needs. A read never stands in for a different text.

132 Swift tests pass.

The synthetic replay fixtures now give 4 proposed actions, 1 fire and 2 pickup presses, with 0 guard rejections. The Med Kit still shows 2.1 s after the first press, so it is pressed again.

**Unverified live:**
- whether the game really missed the short taps;
- whether 0.6 s is long enough for the game to answer a press under lag (a second press then acts on what is next on the panel);
- how pickups while a heal waits feel in play.

## Named guns, October 13

The catalog now knows 37 guns by name, with their ranking ([weapons reference](WEAPONS.md)) and wiki stats. This was checked offline only.

- **Tests.** 129 Swift tests pass. The new ones cover:
  - matching names, including Cyrillic look-alikes and one misread letter in long names;
  - per-gun stats and power;
  - pickups that keep the stronger gun and skip near-equals;
  - the better gun of a class winning its range band;
  - the Semi-Auto Sniper's four shots a second, accepted by the input guard;
  - an icon tied between two rifles staying unnamed.
- **Solo `78E1A3` replayed** before and after (`ZombsPerceive --decide`, seeded icon library, 1,377 frames).
  - Of 2,033 inventory gun readings, 2,029 had the gun's name.
  - The only change in what the assistant did: it took an MG36 over its Mythic XM8, which it had counted as equal before.
  - Fire, reload, heal, chest and other pickup actions were identical; status lines now name the gun ("Epic M4" instead of "Epic AR").
  - A first version put pistols in the close-range slot and picked up a Common Glock and an Uncommon P2000 just to fill it. Pistols stay mid-range fallbacks.

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
