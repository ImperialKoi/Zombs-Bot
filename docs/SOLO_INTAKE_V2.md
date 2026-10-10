# Additional Solo recordings — October 4, 2026

Seven supplied recordings have been added: **4,988 frames over 17 minutes 42 seconds**.
The expanded corpus contains **8,059 unique images across 11 recordings**. Every
image decoded at 3840 × 1736; timestamps increased within each session; all 71,388
observation/decision pairs matched in count. No cross-match duplicate images were
found. See the [integrity report](../data/solo-pilot-v2/integrity.json).

The original four sessions and their split assignments remain intact. Working copies
of the seven new sessions are in `data/solo-recordings-v2/`; that directory also links
to the original four working sessions so their existing annotations remain canonical.
Original recordings in Application Support were not edited. Source inventories were
stable during copying, and copied manifests/frame indexes/logs were checked against
their sources. [Intake provenance](../data/solo-pilot-v2/intake.json) records details.

## Additional whole-match assignments

| New match | Frames | Recorded duration | Split |
| --- | ---: | ---: | --- |
| `2026-10-04T18-29-47Z-090BC4` | 370 | 1m 18s | Train |
| `2026-10-04T18-32-13Z-ABF049` | 361 | 1m 16s | Train |
| `2026-10-04T18-33-52Z-7437EA` | 313 | 1m 06s | Train |
| `2026-10-04T18-35-51Z-4DBB48` | 1,097 | 3m 53s | Validation |
| `2026-10-04T18-40-20Z-582E17` | 825 | 2m 55s | Test |
| `2026-10-04T18-44-20Z-8B2504` | 762 | 2m 43s | Train |
| `2026-10-04T18-47-58Z-21EE9A` | 1,260 | 4m 30s | Train |

The additional validation/test sessions were assigned from recording metadata before
viewing their images. Existing assignments were not moved. The
[v2 plan](../data/solo-pilot-v2/split-plan.json) has seven training, two validation, and
two test matches; it references and hashes the original frozen plan.

## Annotation intent: unengaged players and bots

The user reports deliberately not shooting some early-match characters to conserve
ammunition and identifies some as bots. **Every visible other character still gets
the `player` class**, including those not fired upon. Not shooting is not evidence
of an ally, a missing player, an empty frame, or a distinct opponent-identifying UI
marker. Do not infer a reliable bot/human distinction from that behavior. This is
scene annotation, not imitation labels for when to fire.

## Coverage found in visual inspection

Twelve evenly spaced frames per new session were examined on contact sheets for
selection. This is visual triage, not complete polygon review. The
[84-frame supplemental queue](../data/solo-pilot-v2/additional-annotation-queue.json)
includes those anchors. The [combined queue](../data/solo-pilot-v2/annotation-queue.json)
retains the original 2,000 entries in their original order and appends the 84 new ones.

Observed candidates include snowy and magma environments, characters near doors,
close combat around trees, crowded ground loot near chests, consumption prompts,
the large map overlay, and varied opponent appearances. Exact source references and
limitations are in [coverage candidates](../data/solo-pilot-v2/coverage-candidates.json).

Frame `006878` in `21EE9A` was additionally inspected as a full frame: it shows
**8/100 health**, **0/1102 ammunition**, a partly occluded self character, and another
character firing. A 0.3-second timer is visible; do not mistake a timer alone for
proof of healing. This supplies a useful low-health HUD candidate, not a validated
HUD-reading result or a completed scene annotation.

The user confirmed that small light-green bushes and the blue/pink-centered round
Mystic Forest objects block bullets. Label the bushes as `tree` (foliage in the
current class set) and the round stone objects as `rock`; outline their visible
occupied shapes. This collision information comes from user confirmation, not
appearance alone. The user also requested firing toward confirmed enemies behind
these objects. Their masks remain bullet-blocking, while combat permits engagement
through `tree`/`rock` cover. Walls, doors, chests, allies, and unknown characters still
veto a firing path. Never omit cover polygons merely because combat may fire at it.

The user later confirmed that all solid obstacles block bullets and break after a
few shots; actual walls block bullets and do not break. The existing `rock` class
therefore includes destructible circus tents, rope fences, silver pedestal props,
colored circular pads and other nonvegetation solid props. Foliage remains `tree`,
actual structural wall bands remain `wall`, and interaction doors/chests retain
their separate labels. Visible “Crate (Magma)” and “Gold Chest” prompts in `4DBB48`
identify square lava crates and yellow Z boxes as `chest`. See the
[annotation conventions](DATA_WORKFLOW.md#2-review-annotations-locally) for details.

On October 7, the user also confirmed blue wand/star boxes, green ammo-symbol
boxes and wrapped presents are openable breakable chests (`chest`). The orange
four-petal flower-emblem box is a breakable obstacle without interaction (`rock`).
The October 8 confirmations add yellow X and red star-emblem boxes as `chest`,
brown skull-and-crossbones boxes as `rock`, and blue skull-pattern floor rugs as
noncolliding floor artwork to exclude.

## Negative frames

The last frame of each new session was inspected individually at 1920 × 868.
**All seven were rejected as negatives.** Results/reward overlays still show world
objects, dropped items, other characters, trees, rocks, or walls beneath them.
The [negative review log](../data/solo-pilot-v2/negative-review.jsonl) retains the four
earlier rejections and adds these seven with image hashes and individual reasons.
No empty frame has been accepted as reviewed. These negative-candidate reviews do
not count as complete scene polygons.

## Actual completion status

**The annotation task remains incomplete.** The October 8 audit snapshot contains
**135 reviewed frames, 3,506 polygons and 1,949 pending frames** out of the
2,084-frame queue. Training, validation and test now all contain approved scene
annotations. The [progress report](SOLO_ANNOTATION_PROGRESS.md) records per-match
and per-class counts; the [generated coverage report](../data/solo-pilot-v2/coverage-report.json)
retains the complete pending list and current source-bound validation results.

Reviewed ordinary world classes include self/other players, ground items, doors,
chests, walls, rocks and trees. `ally_marker`, `enemy_marker` and `revive_target`
still have no validated instances. Solo cannot establish team-mode ally/revive
coverage. Accepted reviewed negative frames remain zero. Canonical approvals
follow individual full-frame, crop and overlay inspection; proposed polygons
remain explicitly unreviewed until inspected. The blue wand/star box in
`582E17/004015` is now reviewed as `chest` using the user-confirmed interaction.

No additional matches are requested at this stage. The next work is annotation of
the available footage and review of negative candidates.
Neither data intake nor queue selection satisfies the reviewed-frame requirement.
No training, evaluation, or gameplay input was enabled.

Reproduce the current audit from the project root:

```sh
python3 tools/training/scene_coverage.py data/solo-recordings-v2 \
  --queue data/solo-pilot-v2/annotation-queue.json \
  --split-plan data/solo-pilot-v2/split-plan.json \
  --input-lock data/solo-pilot-v2/annotation-input-lock.json \
  --output data/solo-pilot-v2/coverage-report.json
```

The audit returns status 2 for this incomplete queue and verifies 34 locked baseline
and expanded input files. All hashes currently match. To annotate the expanded queue:

```sh
python3 tools/training/annotate.py data/solo-recordings-v2 \
  --queue data/solo-pilot-v2/annotation-queue.json --port 8767
```

The existing baseline viewer on port 8766 contains the original queue only.
