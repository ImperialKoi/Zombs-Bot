# ZombsRoyale weapons reference

Every gun, special weapon and throwable in ZombsRoyale.io, with in-game pictures, stats and a ranking of the guns. Stats come from the ZombsRoyale.io Fandom wiki, fetched on 2026-10-13. The wiki records no weapon balance changes since May 2022; the only weapons added since then are the Healing and Incendiary Grenades (2024). The pictures are the game's own inventory icons, cut from texture atlases that a wiki editor extracted from the game client in July 2026. Machine-readable data is in [weapons/weapons.json](weapons/weapons.json).

A web search turned up no recent community tier list, so the ranking is a judgement from the wiki's numbers and its strategy notes. Where the two disagree, the numbers win. A ● after a name means the assistant's icon library has learned that item from a pickup prompt in the recorded matches.

## How to read the numbers

- **TTK** (time to kill) is how long a gun takes to deal 200 damage, a full 100 health plus 100 shield, if every shot hits. It uses the best rarity normally found. **Near** is point-blank and **far** is the edge of the gun's range.
- Snipers deal much **less** damage up close, and SMGs, the P90 and the Vector lose most of their damage at range. This is why near and far TTK can differ by several seconds.
- Rarity matters as much as the gun. Each rarity step adds about 1 damage per bullet, about 7% for an AR, so a Legendary gun from a lower tier can beat an Uncommon one from a higher tier.
- Mythic weapons only come from Airdrops, Gold Chests or Zombs crates; the wiki's pages disagree on which. They are rare, but always worth picking up.

## Gun ranking

### S tier: take it over anything

| # | | Gun | Rarity | Where | TTK near / far | Why |
|---|---|---|---|---|---|---|
| 1 | <img src="weapons/scoped_m4.png" width="72" alt="Scoped M4"> | **Scoped M4** | Mythic | Gold Chests / Zombs crates | 1.1 s / 1.2 s | M4 with more damage and a wider view; the wiki calls the Mythic ARs the best guns in the game. |
| 2 | <img src="weapons/assault_scar.png" width="72" alt="Assault SCAR"> | **Assault SCAR** | Mythic | Gold Chests / Zombs crates | 1.2 s / 1.2 s | Highest AR DPS plus splash; don't use it point-blank, the explosive round hurts you too. |
| 3 | <img src="weapons/mg36.png" width="72" alt="MG36"> | **MG36** ● | Mythic | Airdrop only | 1.1 s / 1.1 s | Scoped-M4 damage with a 90-round magazine: whole fights without reloading. |
| 4 | <img src="weapons/ump.png" width="72" alt="UMP"> | **UMP** ● | Epic–Legendary | Crates, Gold Chests | 0.8 s / 1.1 s | Best non-Mythic gun: hardest-hitting SMG, kills a full 100/100 player in under a second, still fine at mid range. |
| 5 | <img src="weapons/vector.png" width="72" alt="Vector"> | **Vector** | Mythic | Airdrop only | 0.7 s / 4.8 s | Fastest kill in the game up close (288 DPS); damage collapses at range and the 24-round mag empties in 1 s. |
| 6 | <img src="weapons/m4.png" width="72" alt="M4"> | **M4** ● | Uncommon–Legendary | Floor, crates, chests | 1.3 s / 1.4 s | Best regular AR: highest non-Mythic AR DPS, accurate, steady stream. The wiki's 'ideal mid-range weapon'. |

### A tier: strong, keep it

| # | | Gun | Rarity | Where | TTK near / far | Why |
|---|---|---|---|---|---|---|
| 7 | <img src="weapons/semi_auto_sniper.png" width="72" alt="Semi-Auto Sniper"> | **Semi-Auto Sniper** ● | Epic–Legendary | Crates, Gold Chests | 3.0 s / 1.0 s | Best long-range DPS in the game (~4 shots/s) and forgiving; weak up close. |
| 8 | <img src="weapons/xm8.png" width="72" alt="XM8"> | **XM8** ● | Mythic | Airdrop only | 1.3 s / 1.5 s | Fast bursts, works as a close-to-mid SMG replacement; shorter range than the other Mythic ARs. |
| 9 | <img src="weapons/p90.png" width="72" alt="P90"> | **P90** ● | Epic–Legendary | Crates, Gold Chests | 0.7 s / 1.8 s | Vector-like shredder inside houses, but very weak beyond close range. |
| 10 | <img src="weapons/mp5.png" width="72" alt="MP5"> | **MP5** ● | Common–Legendary | Floor, crates, chests | 0.9 s / 1.3 s | Common, accurate, high DPS; a Legendary MP5 beats a Mythic SCAR point-blank. |
| 11 | <img src="weapons/uzi.png" width="72" alt="Uzi"> | **Uzi** ● | Common–Legendary | Floor, crates, chests | 0.9 s / 1.1 s | MP5 damage in bursts; slightly better at range than the MP5, smaller magazine. |
| 12 | <img src="weapons/silenced_smg.png" width="72" alt="Silenced SMG"> | **Silenced SMG** | Rare–Epic | Floor, Gold Chests | 0.9 s / 1.3 s | Epic MP5 numbers with less noise and better accuracy than most SMGs. |
| 13 | <img src="weapons/scar.png" width="72" alt="SCAR"> | **SCAR** ● | Uncommon–Legendary | Floor, crates, chests | 1.4 s / 1.6 s | Hard-hitting, accurate auto (buffed in season 19); smaller magazine and slow reload. |
| 14 | <img src="weapons/silenced_ar15.png" width="72" alt="Silenced AR-15"> | **Silenced AR-15** | Mythic | Gold Chests / Zombs crates | 1.4 s / 1.6 s | Quiet, long range, 1 s reload; DPS is only a little above a Legendary AR-15. |
| 15 | <img src="weapons/awp.png" width="72" alt="AWP"> | **AWP** | Mythic | Airdrop only | >6 s / 2.0 s | Hardest single hit at range (80) and the widest view; slow follow-ups. |
| 16 | <img src="weapons/pump_shotgun.png" width="72" alt="Pump Shotgun"> | **Pump Shotgun** ● | Common–Legendary | Floor, crates, chests | 1.0 s / — | Highest damage per shot in the game; two point-blank hits kill. A full reload takes ~6 s. |
| 17 | <img src="weapons/assault_shotgun.png" width="72" alt="Assault Shotgun"> | **Assault Shotgun** | Rare–Epic | Floor, crates, chests | 0.8 s / — | Fast, tight-spread shotgun; better than the Pump outdoors and at close-mid range. |
| 18 | <img src="weapons/ar15.png" width="72" alt="AR-15"> | **AR-15** ● | Uncommon–Legendary | Floor, crates, chests | 1.7 s / 2.0 s | Longest-reaching regular AR, fast bullets with knockback; easy to use but lower damage. |
| 19 | <img src="weapons/ak.png" width="72" alt="AK"> | **AK** ● | Uncommon–Legendary (Mythic in Zombs crates) | Floor, crates, chests | 1.7 s / 1.8 s | Most damage per bullet of any AR but the lowest AR DPS; rewards landing whole bursts. |
| 20 | <img src="weapons/bolt_mk2.png" width="72" alt="Bolt Mk. II Sniper"> | **Bolt Mk. II Sniper** ● | Uncommon–Legendary | Crates, Gold Chests | >6 s / 2.0 s | Three hits at range kill; huge damage drop-off up close and slows you down. |

### B tier: good or situational

| # | | Gun | Rarity | Where | TTK near / far | Why |
|---|---|---|---|---|---|---|
| 21 | <img src="weapons/bolt_action_sniper.png" width="72" alt="Bolt-Action Sniper"> | **Bolt-Action Sniper** | Uncommon–Epic | Floor, crates, chests | >6 s / 2.0 s | Classic bolt sniper; tops out at Epic in normal games, so slightly weaker than the Mk. II. |
| 22 | <img src="weapons/xbow.png" width="72" alt="XBow"> | **XBow** | Mythic | Airdrop only | 2 shots (~1.6 s) | Two 65-damage arrows per shot with AWP-level view; slow arrows need leading. |
| 23 | <img src="weapons/dragunov.png" width="72" alt="Dragunov"> | **Dragunov** ● | Mythic | Gold Chests / Zombs crates | >6 s / 3.4 s | Big knockback and fast bullets, but a 1-round magazine. |
| 24 | <img src="weapons/silenced_pistol.png" width="72" alt="Silenced Pistol"> | **Silenced Pistol** ● | Rare–Epic | Floor, crates, chests | 1.3 s / 1.3 s | No spread and no damage drop-off, plus the fastest movement of any gun class. |
| 25 | <img src="weapons/dual_berettas.png" width="72" alt="Dual Berettas"> | **Dual Berettas** ● | Uncommon–Rare | Floor, crates, chests | 1.3 s / 1.3 s | No spread and a very high fire rate; strong early-game gun. |
| 26 | <img src="weapons/tommy_gun.png" width="72" alt="Tommy Gun"> | **Tommy Gun** | Rare–Epic | Crates, chests | 1.4 s / 2.8 s | 50-round drum, but it uses medium (AR) ammo and falls off hard at range. |
| 27 | <img src="weapons/famas.png" width="72" alt="Famas"> | **Famas** ● | Rare–Epic | Crates, Gold Chests | 1.8 s / 2.0 s | Quick burst rifle, but the slowest-killing AR and a 2.1 s reload. |
| 28 | <img src="weapons/minigun.png" width="72" alt="Minigun"> | **Minigun** | Legendary | Crates, Gold Chests | 1.0 s / 1.7 s | Huge magazine and DPS on paper, but heavy spread, spin-up and it slows you a lot. |
| 29 | <img src="weapons/flamethrower.png" width="72" alt="Flamethrower"> | **Flamethrower** | Legendary | Crates, Gold Chests | ~0.8 s point-blank | Melts anyone in reach and keeps burning them; useless past short range. |
| 30 | <img src="weapons/rpg.png" width="72" alt="RPG"> | **RPG** ● | Uncommon–Legendary | Floor, crates, chests | 3 hits | Huge splash for houses and groups; slow rocket, and it can blow you up. |
| 31 | <img src="weapons/deagle.png" width="72" alt="Deagle"> | **Deagle** ● | Rare–Epic | Floor, crates, chests | 2.0 s / 2.0 s | Sniper-like hand cannon (41 per hit, 2 shots/s); punishing if you miss. Uses large ammo. |
| 32 | <img src="weapons/vss.png" width="72" alt="VSS"> | **VSS** ● | Rare–Legendary | Floor, crates, chests | 3.1 s / 3.5 s | Only automatic sniper; easy and decent up close, but low damage. Uses SMG (small) ammo. |
| 33 | <img src="weapons/raid_shotgun.png" width="72" alt="RAID Shotgun"> | **RAID Shotgun** | Common–Epic | Floor, crates, chests | 1 fully charged hit | Charge it fully for up to 200 in one shot; weak uncharged and the slowest shotgun to reload. |
| 34 | <img src="weapons/crossbow.png" width="72" alt="Crossbow"> | **Crossbow** | Mythic | Gold Chests / Zombs crates | 3 hits (~3.2 s) | One-shot-per-reload bow with a huge view; arrows are slow. |

### C tier: replace when you can

| # | | Gun | Rarity | Where | TTK near / far | Why |
|---|---|---|---|---|---|---|
| 35 | <img src="weapons/ksg_shotgun.png" width="72" alt="KSG Shotgun"> | **KSG Shotgun** ● | Rare–Epic | Floor, crates, chests | 1.0 s / — | Low damage per shot and no knockback; pellets pass through players. |
| 36 | <img src="weapons/hunting_rifle.png" width="72" alt="Hunting Rifle"> | **Hunting Rifle** | Common–Epic | Floor, crates, chests | >6 s / 3.0 s | Budget sniper: 4 quick shots, then a slow round-by-round reload. |
| 37 | <img src="weapons/grenade_launcher.png" width="72" alt="Grenade Launcher"> | **Grenade Launcher** | Legendary | Crates, Gold Chests | 8 hits (~3.5 s) | Flushes people out of houses; low damage per grenade. |
| 38 | <img src="weapons/glock.png" width="72" alt="Glock"> | **Glock** ● | Common–Uncommon | Floor, crates, chests | 2.6 s / 2.6 s | Early-game stopgap; 15-round magazine forces a reload before a full kill. |
| 39 | <img src="weapons/p2000.png" width="72" alt="P2000"> | **P2000** | Common–Uncommon | Floor, crates, chests | 2.7 s / 2.7 s | Weakest gun in normal loot; swap it out as soon as possible. |
| 40 | <img src="weapons/gift_launcher.png" width="72" alt="Gift Launcher"> | **Gift Launcher** | Legendary | Holiday seasons | — | Seasonal novelty; sticky explosives, splash. |
| 41 | <img src="weapons/goo_gun.png" width="72" alt="Goo Gun"> | **Goo Gun** | Legendary | Crates, Gold Chests | — | Damage over time for hit-and-run; needs a real gun to finish. |
| 42 | <img src="weapons/rubber_gun.png" width="72" alt="Rubber Gun"> | **Rubber Gun** | Legendary | Crates, Gold Chests | — | Bounces off walls, hitting harder per bounce; situational. |

## Best gun for each slot

You usually carry one close-range gun, one mid-range gun and one long-range gun. Within each slot, the best first:

- **Close range (SMG or shotgun):** UMP > Vector > P90 > MP5 > Uzi > Silenced SMG > Pump Shotgun > Assault Shotgun > Silenced Pistol > Dual Berettas > Tommy Gun > Flamethrower > RAID Shotgun > KSG Shotgun > Glock > P2000
- **Mid range (assault rifle):** Scoped M4 > Assault SCAR > MG36 > M4 > XM8 > SCAR > Silenced AR-15 > AR-15 > AK > Famas > Minigun
- **Long range (sniper):** Semi-Auto Sniper > AWP > Bolt Mk. II Sniper > Bolt-Action Sniper > XBow > Dragunov > Deagle > VSS > Crossbow > Hunting Rifle

The Semi-Auto Sniper is ranked above the AWP because it fires about four times as often, which forgives misses and makes it the fastest killer at long range. The AWP still hits harder per shot.

## Stats by class

Damage and DPS are at the best rarity normally found. A range such as 10–15 is the damage at the far and near ends of the gun's range; for snipers the higher number is the far end. Range and spread words are the wiki's.

### Assault rifles

| | Gun | Fire | Damage | DPS | Mag | Reload | Range | Ammo |
|---|---|---|---|---|---|---|---|---|
| <img src="weapons/scoped_m4.png" width="64" alt="Scoped M4"> | **Scoped M4** | Auto | 16–17 | 160–170 | 30 | 1.5 s | Long+ | Medium |
| <img src="weapons/assault_scar.png" width="64" alt="Assault SCAR"> | **Assault SCAR** | Auto, every 6th shot explodes (20) | 11–13 | 150–180 | 30 | 1.5 s | Med++ | Medium |
| <img src="weapons/mg36.png" width="64" alt="MG36"> | **MG36** ● | Auto | 17 | 170 | 90 | 1.4 s | Med++ | Medium |
| <img src="weapons/m4.png" width="64" alt="M4"> | **M4** ● | Auto | 14–15 | 140–150 | 30 | 1.4 s | Med++ | Medium |
| <img src="weapons/xm8.png" width="64" alt="XM8"> | **XM8** ● | Burst of 4 | 11–12 | 120–144 | 28 | 1.5 s | Long- | Medium |
| <img src="weapons/scar.png" width="64" alt="SCAR"> | **SCAR** ● | Auto | 18–19 | 126–133 | 24 | 2 s | Med++ | Medium |
| <img src="weapons/silenced_ar15.png" width="64" alt="Silenced AR-15"> | **Silenced AR-15** | Burst of 3, silenced | 14–15 | 117–135 | 30 | 1 s | Long+ | Medium |
| <img src="weapons/ar15.png" width="64" alt="AR-15"> | **AR-15** ● | Burst of 3 | 11–13 | 99–117 | 30 | 1.4 s | Long- | Medium |
| <img src="weapons/ak.png" width="64" alt="AK"> | **AK** ● | Burst of 3 | 18–19 | 108–114 | 30 | 1.4 s | Long-- | Medium |
| <img src="weapons/famas.png" width="64" alt="Famas"> | **Famas** ● | Burst | 16–17 | 96–102 | 30 | 2.1 s | Long | Medium |

### SMGs

| | Gun | Fire | Damage | DPS | Mag | Reload | Range | Ammo |
|---|---|---|---|---|---|---|---|---|
| <img src="weapons/ump.png" width="64" alt="UMP"> | **UMP** ● | Auto | 13–17 | 182–238 | 35 | 1 s | Med | Small |
| <img src="weapons/vector.png" width="64" alt="Vector"> | **Vector** | Auto | 3–12 | 72–288 | 24 | 1 s | Med+ | Small |
| <img src="weapons/p90.png" width="64" alt="P90"> | **P90** ● | Auto | 5–13 | 110–286 | 40 | 1.7 s | Short+ | Small |
| <img src="weapons/mp5.png" width="64" alt="MP5"> | **MP5** ● | Auto | 10–15 | 150–225 | 30 | 1 s | Med- | Small |
| <img src="weapons/uzi.png" width="64" alt="Uzi"> | **Uzi** ● | Burst of 3 | 12–15 | 180–225 | 24 | 1 s | Med- | Small |
| <img src="weapons/silenced_smg.png" width="64" alt="Silenced SMG"> | **Silenced SMG** | Auto, silenced | 10–15 | 150–225 | 30 | 1 s | Med- | Small |
| <img src="weapons/tommy_gun.png" width="64" alt="Tommy Gun"> | **Tommy Gun** | Auto | 7–14 | 70–140 | 50 | 1.5 s | Med | Medium |

### Shotguns

| | Gun | Fire | Damage | DPS | Mag | Reload | Range | Ammo |
|---|---|---|---|---|---|---|---|---|
| <img src="weapons/pump_shotgun.png" width="64" alt="Pump Shotgun"> | **Pump Shotgun** ● | Pump | 7–120 | 7–120 | 6 | 1.1 s per shell | Short | Shells |
| <img src="weapons/assault_shotgun.png" width="64" alt="Assault Shotgun"> | **Assault Shotgun** | Semi-auto | 4–85 | 10–213 | 8 | 0.9 s per shell | Short+ | Shells |
| <img src="weapons/raid_shotgun.png" width="64" alt="RAID Shotgun"> | **RAID Shotgun** | Charge | 9–200 (charged) | 12–250 | 6 | 1.5 s per shell | Short | Shells |
| <img src="weapons/ksg_shotgun.png" width="64" alt="KSG Shotgun"> | **KSG Shotgun** ● | Pump, pellets pierce | 6–46 | 24–184 | 6 | 0.9 s per shell | Med | Shells |

### Sniper rifles

| | Gun | Fire | Damage | DPS | Mag | Reload | Range | Ammo |
|---|---|---|---|---|---|---|---|---|
| <img src="weapons/semi_auto_sniper.png" width="64" alt="Semi-Auto Sniper"> | **Semi-Auto Sniper** ● | Semi-auto (hold to fire) | 26–45 | 104–180 | 5 | 1.2 s | Long++ | Large |
| <img src="weapons/awp.png" width="64" alt="AWP"> | **AWP** | Bolt-action | 16–80 | 16–80 | 5 | 1 s per shot, 3.2 s mag | Insane | Large |
| <img src="weapons/bolt_mk2.png" width="64" alt="Bolt Mk. II Sniper"> | **Bolt Mk. II Sniper** ● | Bolt-action | 15–75 | 15–75 | 4 | 1 s per shot, 2.5 s mag | Long | Large |
| <img src="weapons/bolt_action_sniper.png" width="64" alt="Bolt-Action Sniper"> | **Bolt-Action Sniper** | Bolt-action | 14–70 | 14–70 | 5 | 1 s per shot, 2.5 s mag | Long+ | Large |
| <img src="weapons/dragunov.png" width="64" alt="Dragunov"> | **Dragunov** ● | Single shot | 15–77 | 15–77 | 1 | 1.7 s | Long++ | Large |
| <img src="weapons/vss.png" width="64" alt="VSS"> | **VSS** ● | Auto, silenced | 11–13 | 88–104 | 10 | 1.2 s | Long- | Small |
| <img src="weapons/hunting_rifle.png" width="64" alt="Hunting Rifle"> | **Hunting Rifle** | Auto | 6–36 | 12–144 | 4 | 0.9 s per round | Long | Large |

### Pistols

| | Gun | Fire | Damage | DPS | Mag | Reload | Range | Ammo |
|---|---|---|---|---|---|---|---|---|
| <img src="weapons/silenced_pistol.png" width="64" alt="Silenced Pistol"> | **Silenced Pistol** ● | Auto, silenced | 15 | 150 | 15 | 1 s | Med+ | Small |
| <img src="weapons/dual_berettas.png" width="64" alt="Dual Berettas"> | **Dual Berettas** ● | Auto | 10 | 150 | 24 | 1 s | Med | Small |
| <img src="weapons/deagle.png" width="64" alt="Deagle"> | **Deagle** ● | Semi-auto | 41 | 82 | 7 | 1 s | Med++ | Large |
| <img src="weapons/glock.png" width="64" alt="Glock"> | **Glock** ● | Burst of 3 | 10 | 120 | 15 | 1 s | Med | Small |
| <img src="weapons/p2000.png" width="64" alt="P2000"> | **P2000** | Auto | 10 | 110 | 15 | 1 s | Med | Small |

### Special guns

| | Gun | Fire | Damage | DPS | Mag | Reload | Range | Ammo |
|---|---|---|---|---|---|---|---|---|
| <img src="weapons/xbow.png" width="64" alt="XBow"> | **XBow** | 2 arrows per shot | 30–130 | 30–130 | 2 | 1.6 s | Insane | Large |
| <img src="weapons/minigun.png" width="64" alt="Minigun"> | **Minigun** | Auto, spins up | 5–9 | 174–203 | 150 | 3 s | Med+ | Small |
| <img src="weapons/flamethrower.png" width="64" alt="Flamethrower"> | **Flamethrower** | Stream, burns 2/s for 5 s, pierces | 11–19 | 220–260 | 50 | 1 s | Short | Small |
| <img src="weapons/rpg.png" width="64" alt="RPG"> | **RPG** ● | Single rocket, splash | 90–95 | 90–95 | 1 | 1 s | Long- | Large |
| <img src="weapons/crossbow.png" width="64" alt="Crossbow"> | **Crossbow** | Single arrow | 20–120 | 20–120 | 1 | 1.6 s | Insane | Large |
| <img src="weapons/grenade_launcher.png" width="64" alt="Grenade Launcher"> | **Grenade Launcher** | Bouncing grenades, ~2/s | 25 splash | 100 | 8 | 0.7 s per round | Med+ | Large |
| <img src="weapons/gift_launcher.png" width="64" alt="Gift Launcher"> | **Gift Launcher** | Bursts of 4 sticky presents | 10–20 | 120–130 | 12 | 1 s | Med+ | Large |
| <img src="weapons/goo_gun.png" width="64" alt="Goo Gun"> | **Goo Gun** | 5 globs per shot + poison | up to 34 + poison 6/s for 5 s | 20–24 | 12 | 1 s | Short+ | Small |
| <img src="weapons/rubber_gun.png" width="64" alt="Rubber Gun"> | **Rubber Gun** | Bursts of 3 bouncing balls | 8–21 | — | 21 | 2 s | Short++ | Small |

### Not in normal matches

| | Gun | Rarity | Status |
|---|---|---|---|
| <img src="weapons/tactical_shotgun.png" width="64" alt="Tactical Shotgun"> | **Tactical Shotgun** | Common–Rare | Vaulted 2020 (replaced by KSG); Weapons Race and Mystery Mode only. KSG without piercing. |
| <img src="weapons/revolver.png" width="64" alt="Revolver"> | **Revolver** | Legendary | Vaulted 2018; Weapons Race and Crystal Clash only. 25 damage, slow round-by-round reload. |

## Special weapons

| | Item | Rarity | Where | What it does |
|---|---|---|---|---|
| <img src="weapons/thors_hammer.png" width="64" alt="Thor's Hammer"> | **Thor's Hammer** | Mythic | Airdrop only | Thrown hammer: 45 direct / 25 splash, knocks players back. |
| <img src="weapons/trident.png" width="64" alt="Trident of the Depths"> | **Trident of the Depths** | Mythic | Airdrop only | Thrown trident: 25 splash and pulls everyone in, like a Reverse Impulse. |
| <img src="weapons/airstrike_gun.png" width="64" alt="Airstrike Gun"> | **Airstrike Gun** | Legendary | Gold Chests | Flare that calls ~5 s of explosions (9–10 each, stacking); hurts you too. Recorded prompts show it as a throwable, "Airstrike / Legendary Grenade", in stacks of 5. |
| <img src="weapons/healing_gun.png" width="64" alt="Healing Gun"> | **Healing Gun** | Epic | Crates, Gold Chests, Airdrops | Heals 12 health per shot (no shield); bounce shots off walls to heal yourself. 8 shots, no reload. The prompt calls it "Healing Weapon / Epic Unique"; in hand, the readout shows the rounds left as a bare count ("8"), as for a grenade. |
| <img src="weapons/grappling_hook.png" width="64" alt="Grappling Hook"> | **Grappling Hook** | Legendary | Crates, Gold Chests | Pulls you to the point you hit; 20 uses. |
| <img src="weapons/turret.png" width="64" alt="Turret"> | **Turret** | Mythic | Vaulted; 50v50 Airdrops only | Thrown turret that fires at nearby enemies until destroyed. |

## Throwables

Lethal grenades hurt you but not your teammates. Stack is the amount you find / the most you can carry. All of them land where you click, except the Sticky Bomb, and none can be cooked. The prompt names them on a "<rarity> Grenade" line, for example "Reverse Impulse / Common Grenade".

| | Throwable | Rarity | Stack | What it does |
|---|---|---|---|---|
| <img src="weapons/frag_grenade.png" width="56" alt="Frag Grenade"> | **Frag Grenade** ● | Common | 3 / 9 | 35–83 damage after a ~2 s fuse, light knockback; hurts you too. |
| <img src="weapons/rgd5_grenade.png" width="56" alt="RGD-5 Grenade"> | **RGD-5 Grenade** | Common | 5 / 10 | 20–40 damage, explodes ~0.5 s after the throw; flies faster than a Frag. |
| <img src="weapons/sticky_bomb.png" width="56" alt="Sticky Bomb"> | **Sticky Bomb** | Epic | 3 / 9 | Flies straight, sticks to players or objects, 50 damage after ~2 s. |
| <img src="weapons/cactus_bomb.png" width="56" alt="Cactus Bomb"> | **Cactus Bomb** | Legendary | 3 / 9 | Bursts into bouncing thorns that hit anyone, including you. |
| <img src="weapons/gassy_grenade.png" width="56" alt="Gassy Grenade"> | **Gassy Grenade** | Legendary | 3 / 9 | Poison cloud, 15 damage per second; clouds stack. |
| <img src="weapons/incendiary_grenade.png" width="56" alt="Incendiary Grenade"> | **Incendiary Grenade** ● | Legendary | 3 / 9 | Ring of fire that burns, stacks like Gassy (added Aug 2024). |
| <img src="weapons/impulse_grenade.png" width="56" alt="Impulse Grenade"> | **Impulse Grenade** ● | Common | 3 / 9 | Pushes players away; no damage. |
| <img src="weapons/reverse_impulse_grenade.png" width="56" alt="Reverse Impulse Grenade"> | **Reverse Impulse Grenade** | Common | 3 / 9 | Pulls every player nearby to where it lands, you and teammates included, even through walls; no damage. The prompt calls it "Reverse Impulse". |
| <img src="weapons/smoke_grenade.png" width="56" alt="Smoke Grenade"> | **Smoke Grenade** | Common | 3 / 9 | Smoke cloud that hides players and items; no damage. |
| <img src="weapons/freeze_grenade.png" width="56" alt="Freeze Grenade"> | **Freeze Grenade** ● | Legendary | 3 / 3 | Slows, then freezes everyone in a small radius, you included. |
| <img src="weapons/snowman_grenade.png" width="56" alt="Snowman Grenade"> | **Snowman Grenade** ● | Common–Legendary | 3 / 6 | Builds a hollow box of breakable snowmen as cover. |
| <img src="weapons/healing_grenade.png" width="56" alt="Healing Grenade"> | **Healing Grenade** ● | Legendary | 2 / 6 | Heals you and teammates in the area, not opponents (added Jun 2024). Measured on a recorded Duo match: it lies on the ground about a second, then a circle 0.118 view widths in radius heals health only, +5 about four times a second (~20/s), for 4.5 s. |
| <img src="weapons/shuriken.png" width="56" alt="Shuriken"> | **Shuriken** | Legendary | 30 / 90 | Throws 5 stars in an arc, 20 damage each, ~2 volleys a second; short range. |
| <img src="weapons/snowball.png" width="56" alt="Snowball"> | **Snowball** | Common | 6 / 30 | 9 damage and slows the target ~5 s; found by breaking snowy trees at Lucky Lake. |

## Consumables, ammo and fists

These are not weapons, but their icons come from the same atlas and appear in the same inventory slots.

| | Item | Notes |
|---|---|---|
| <img src="weapons/bandage.png" width="48" alt="Bandage"> | **Bandage** | +15 health up to 75; 2.2 s to use. 8 on the ground, 8 at most in a slot. |
| <img src="weapons/med_kit.png" width="48" alt="Med Kit"> | **Med Kit** | Heals to full health; 5 s. 1 on the ground, 2 in a slot. |
| <img src="weapons/small_shield.png" width="48" alt="Small Shield Potion"> | **Small Shield Potion** | +25 shield up to 50; 2 s. 2 on the ground, 4 in a slot. |
| <img src="weapons/big_shield.png" width="48" alt="Big Shield Potion"> | **Big Shield Potion** | +50 shield up to 100; 5 s. 1 on the ground, 2 in a slot. |
| <img src="weapons/hybrid_potion.png" width="48" alt="Hybrid Potion"> | **Hybrid Potion** | +25 health and +25 shield over 10 s; 2 s. 2 on the ground, 4 in a slot. A second one during those 10 s is wasted. |
| <img src="weapons/stimpack.png" width="48" alt="Stimpack"> | **Stimpack** | Legendary: +50% movement speed and fire rate for 10 s; 1 s. 1 on the ground, 2 in a slot. The assistant leaves it to you. |
| <img src="weapons/ammo_small.png" width="48" alt="Small ammo"> | **Small ammo** | SMGs (not the Tommy Gun), pistols except the Deagle, VSS, Minigun, Flamethrower, Goo Gun, Rubber Gun. |
| <img src="weapons/ammo_medium.png" width="48" alt="Medium ammo"> | **Medium ammo** | Assault rifles and the Tommy Gun. |
| <img src="weapons/ammo_large.png" width="48" alt="Large ammo"> | **Large ammo** | Snipers except the VSS, Deagle, RPG, Grenade and Gift Launchers, Crossbow, XBow. |
| <img src="weapons/ammo_shells.png" width="48" alt="Shotgun shells"> | **Shotgun shells** | Shotguns. |
| <img src="weapons/fists.png" width="48" alt="Fists"> | **Fists** | Slot 1 melee. |

## In the game files but never released

The client's atlases also contain guns that never shipped. Names come from the wiki's leak pages and were matched by eye.

| | Name | Note |
|---|---|---|
| <img src="weapons/an94.png" width="64" alt="AN94 (unreleased)"> | AN94 (unreleased) | Leaked burst AR, 21–22 damage. |
| <img src="weapons/aug.png" width="64" alt="AUG (unreleased)"> | AUG (unreleased) | Leaked burst AR, ~14 damage. |
| <img src="weapons/grau.png" width="64" alt="Grau (unreleased)"> | Grau (unreleased) | Leaked rainbow AR. |
| <img src="weapons/bizon.png" width="64" alt="Bizon (unreleased)"> | Bizon (unreleased) | Matches the wiki's Bizon leak image. |
| <img src="weapons/dmr.png" width="64" alt="DMR (unreleased)"> | DMR (unreleased) | Matches the wiki's DMR image. |
| <img src="weapons/white_bolt.png" width="64" alt="White Bolt? (unreleased)"> | White Bolt? (unreleased) | Bolt sniper; name is a guess. |
| <img src="weapons/laser_cannon.png" width="64" alt="Laser Cannon (unreleased)"> | Laser Cannon (unreleased) | Leaked railgun, 24–97 damage. |
| <img src="weapons/lunar_rpg.png" width="64" alt="Lunar RPG (unreleased)"> | Lunar RPG (unreleased) | Dragon-head launcher. |
| <img src="weapons/freeze_turret.png" width="64" alt="Freeze Turret (unreleased)"> | Freeze Turret (unreleased) | Ice version of the Turret. |

Twelve more sprites in the atlases match no wiki page. They may be old designs or test items. They are kept as `weapons/unidentified_NN.png` in case one turns up in a recording:

<img src="weapons/unidentified_01.png" width="48" alt="unidentified_01"> <img src="weapons/unidentified_02.png" width="48" alt="unidentified_02"> <img src="weapons/unidentified_03.png" width="48" alt="unidentified_03"> <img src="weapons/unidentified_04.png" width="48" alt="unidentified_04"> <img src="weapons/unidentified_05.png" width="48" alt="unidentified_05"> <img src="weapons/unidentified_06.png" width="48" alt="unidentified_06"> <img src="weapons/unidentified_07.png" width="48" alt="unidentified_07"> <img src="weapons/unidentified_08.png" width="48" alt="unidentified_08"> <img src="weapons/unidentified_09.png" width="48" alt="unidentified_09"> <img src="weapons/unidentified_10.png" width="48" alt="unidentified_10"> <img src="weapons/unidentified_11.png" width="48" alt="unidentified_11"> <img src="weapons/unidentified_12.png" width="48" alt="unidentified_12">

## How the assistant uses this

The catalog (`Sources/AssistantCore/Catalog.swift`) lists the 37 guns a prompt can name, with this ranking and the wiki's fire rate, reload and ammunition. A gun whose name is recognized gets a model ID such as `ar:rare:m4`; any other gun keeps a class ID such as `ar:rare` and counts as an average gun of its class.

- **The loadout** the assistant works toward:
  - a sniper, an AR and an SMG;
  - one slot for a utility item or heals;
  - one slot for heals.

  A gun of the class the loadout wants for its range beats any other gun there. So an SMG replaces a shotgun however the two rank, an AR a pistol or LMG, and a sniper a DMR.
- **Pickups** within a class go by rarity first: a Legendary AK replaces an Epic M4, though the M4 ranks higher. Between guns of one rarity they compare power: 101 minus the rank at the gun's best normal rarity, 3 points per rarity step from there. A gun replaces one of its class when it is worth at least 1.5 more, so a Rare M4 (89) replaces a Rare AK (76).
- **Tier C guns** (KSG Shotgun, Hunting Rifle, Glock, P2000) are never picked up. One you carry is the first to go when a slot is needed, unless it is your only gun.
- **When the loadout needs a slot** (a missing gun, a first heal, a first utility item), what it has no place for goes first: a second gun for a range, then a second utility item. A missing gun may also take the slot of a second heal stack. With a full inventory and a potion needed now, your utility item is lent for the drink, else your weakest gun, and picked up again afterwards.
- **Range bands** still prefer shotguns up close, assault rifles at mid range and snipers far away. Of one class the rarest loaded gun is used, so a Legendary Bolt Mk. II comes before an Epic Semi-Auto Sniper. Between guns of one rarity the better one wins: the UMP over the MP5.
- **Firing** uses each gun's own rate:
  - The Semi-Auto Sniper clicks four times a second.
  - The VSS, Hunting Rifle and the automatic pistols are held down.
  - The Dragunov reloads after every shot.
- Pistols keep the assistant's fallback role at mid range. In the close or long slot one would only take up space, because the range bands prefer an assault rifle to a pistol.
- Range, zoom and bullet speed stay class estimates, because the wiki only describes them in words.
- Potions follow the stack sizes above. Below 50 health, or below 100 health and shield together, a potion that would help is picked up and drunk before any other loot.
- The Stimpack stays manual. Its only use is just before a fight, which the assistant cannot time.

### Healing Grenades and the Healing Gun

Both restore health only, and the assistant uses them on someone below 50 health (**Low health** in Settings): you, or a teammate on screen. A teammate's health is read off their row in the roster above your name, where a thin shield bar sits over a health bar that is green while they are up and red while they are knocked down; the tag above their head says which row is theirs. An opponent in the open always gets a gun first.

| Item | Who | How |
|---|---|---|
| **Healing Grenade** | You | Thrown at your feet, as soon as no opponent is in the open. It is one click, and the circle heals you while you fight on in it. A low teammate beside you gets it halfway between you, so the circle takes you both. A green **STAY IN THE CIRCLE** label counts down while it heals you. |
| **Healing Grenade** | A teammate | Thrown at their feet, where they will be a moment later, when a throw can reach them. Nothing is thrown through a wall, which it would bounce off. |
| **Healing Gun** | A teammate | A round at a time, leading them as they move, with no wall, tree, rock or other player on the way: a round heals whoever it reaches first, an opponent too. It stops within one round (12 health) of full. |
| **Healing Gun** | You | In a safe gap, fired square at the nearest flat wall face within 0.045–0.15 view widths along the screen's axes, so the round comes straight back to you. Only while you stand still (**STOP MOVING** shows): a round comes back to where you stood. |

Nobody in a circle of yours gets another heal while it lasts, and potions do not top up health a circle is about to restore. Rounds that raise nobody's health for 1.6 s end the heal, and that heal is not tried again for 10 s. The Healing Gun is never used to fight or to finish a combo, and it is never picked up for you. A Healing Grenade counts as the loadout's utility item, ranked below the combat grenades.

**Measured:** the circle's radius, rate and 4.5 s, on one recorded throw at a teammate. **Estimated:** the delay before the circle opens (0.9–1.8 s; 1.2 s is used), the throw range, and the Healing Gun's fire rate (one round every 0.5 s), bullet speed and range. No recording shows the Healing Gun fired.

### Reverse Impulse combos

A Reverse Impulse goes off about 0.5 s after the throw and pulls the opponent to where it landed, so the assistant knows where they will be and when. With a Reverse Impulse in your inventory, it can finish a combo in these ways, best first:

| Finisher | How it goes |
|---|---|
| **Frag Grenade** ("rev-nade") | The Frag goes off 2 s after the throw, so it goes **first**. The Reverse Impulse follows 1.15 s later at the same spot, timed to bring the opponent there just before the Frag explodes. |
| **RGD-5 Grenade** | As quick as the pull, so the Reverse Impulse goes first and the RGD-5 0.35 s later. |
| **RPG**, **Gift Launcher** | Fired at the spot so the rocket or presents arrive just as the opponent does. |
| **XBow**, **Crossbow**, sniper, DMR | One shot at the spot, timed the same way. A pinned opponent is the easiest sniper target there is. |
| **Shotgun** or **SMG** | Tight quarters: an opponent round a corner or behind a door, close enough to you. The Reverse Impulse lands **at your feet**, pulls them through the wall or door to you, and the shotgun (or, without one, the SMG) fires as they arrive. |
| **Any other gun** (AR, SMG, LMG) | Only for an opponent behind cover: the pull brings them out into your line of fire. In the open, these guns just shoot. |

What keeps you safe:

- **Explosions hurt you too.** A Frag or RGD-5 never lands within its blast radius plus a margin of you, counting how your own movement will carry you until it goes off. An RPG, Gift Launcher or Assault SCAR round is never fired at a target, or past anything solid (wall, tree, rock, another player), that is that close to you. The Assault SCAR in an ordinary fight follows the same rule, so another gun takes over point-blank.
- **The pull takes you along when you are inside it.** A Reverse Impulse lands either at your feet, where it leaves you in place and no explosion follows, or out of your reach. Before the second throw of a rev-nade, the assistant checks again: if you have walked toward the Frag, the Reverse Impulse is not thrown.
- **Grenades bounce off walls.** Nothing is thrown through a wall, door, chest, tree or rock, or past a teammate.
- **Nobody else gets pulled:** never a teammate, or a player not yet known to be an enemy.
- While one of its grenades is about to go off, a red **GRENADE OUT** label above your character tells you to keep clear.
- The input guard checks every throw and every shot at the spot again, independently.

The game throws to where you click, so a throw lands within the **Grenade circle**: 60% of the view's height by default, about 0.34 view widths at 16:9 and 0.27 in a wide window. At its largest setting it covers the whole screen. Throws also obey these limits:
- They stay 6% of the view's height away from every edge.
- They never land on the HUD: the settings, sound and fullscreen buttons, the map button and minimap, your vitals, the inventory with its ammo counters, the team roster and the item panel.
- Anything solid on the way limits a throw too: for an opponent behind a wall, the spot is on your side of it, and the pull brings them through.

The pull's reach adds a little.

**Estimated, not measured:** the Frag's 2 s and the RGD-5's 0.5 s fuses are the wiki's. The Reverse Impulse's 0.5 s is assumed equal to the Impulse's, as the wiki's combos imply. These are guesses to check in play:

- Blast radii: Frag 0.08, RGD-5 0.065, RPG 0.07, Gift Launcher 0.04, Assault SCAR 0.035 view widths.
- The pull's reach: 0.09.
- How long a pull takes: 0.3 s.
- Rocket and arrow speeds.

The catalog in `Sources/AssistantCore/Catalog.swift`, or a tuned copy in `catalog.json`, holds them.

Your loadout has room for **one utility item**, and the assistant picks one up when a free slot is not needed for a missing gun. The Reverse Impulse comes first, then the Frag, RGD-5, Sticky Bomb and Grappling Hook, then other grenades. It replaces a weaker one and stacks more of the same. A second grenade type that you pick up yourself, as a rev-nade needs, stays until the loadout needs its slot. Launcher and bow pickups stay manual. An Impulse, Sticky Bomb or any grenade it cannot name is never thrown, and a grenade it cannot name is never picked up. Unique weapons are named on the prompt rather than classed ("Gift Launcher / Legendary Unique", "Crossbow / Mythic Unique"). The assistant recognizes launchers, bows and throwables by name there. The Minigun's prompt also says "Legendary Unique", and it stays unrecognized, as before.

## Sources

- [ZombsRoyale.io wiki: Weapons](https://zombsroyaleio.fandom.com/wiki/Weapons) (stats table) and the individual weapon pages
- [Consumables](https://zombsroyaleio.fandom.com/wiki/Consumables), [Mythics](https://zombsroyaleio.fandom.com/wiki/Mythics), [Strategies](https://zombsroyaleio.fandom.com/wiki/Strategies), [Update Chronicle](https://zombsroyaleio.fandom.com/wiki/Update_Chronicle)
- Sprites: [Weapon inventory 1](https://zombsroyaleio.fandom.com/wiki/File:Weapon_inventory_1.png) and [Weapon inventory 2](https://zombsroyaleio.fandom.com/wiki/File:Weapon_inventory_2.png), extracted with RenderDoc from the official client
- Game art © the ZombsRoyale.io developers; wiki text is CC BY-SA.
