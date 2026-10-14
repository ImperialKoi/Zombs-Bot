import Testing
import Foundation
@testable import AssistantCore

struct AssistantCoreTests {
    @Test func testRecordedVitalLabels() {
        #expect(HUDText.healthOrShield("100/100") == 100)
        #expect(HUDText.healthOrShield("44/100") == 44)
        #expect(HUDText.healthOrShield("77 / 100") == 77)
        #expect(HUDText.healthOrShield("0") == 0)
        #expect(HUDText.healthOrShield("100",requiringMaximum:true) == nil)
        #expect(HUDText.healthOrShield("44/100",requiringMaximum:true) == 44)
    }
    @Test func testAmbiguousVitalLabelsAreRejected() {
        for text in ["", "IOO/100", "101/100", "44/10", "-1", "50 100", "1/100/100", "44 HP"] {
            #expect(HUDText.healthOrShield(text) == nil)
        }
    }
    @Test func testAmmunitionPreservesThousandsAndSeparators() {
        #expect(HUDText.ammunition("24/ 417")?.loaded == 24)
        #expect(HUDText.ammunition("24/ 1,308")?.reserve == 1308)
        for text in ["24 1417 lil", "24 417", "24/1,30", "24/417/5", "-1/50"] {
            #expect(HUDText.ammunition(text) == nil)
        }
    }
    func profiles()->[ItemProfile] {
        var rifle=ItemProfile(id:"rifle",name:"Rifle",kind:.weapon,role:.medium)
        rifle.verified=true; rifle.automatic=true; rifle.projectileSpeed=2
        var upgrade=rifle; upgrade.id="rifle_gold"; upgrade.name="Gold Rifle"; upgrade.tier=3
        var shotgun=ItemProfile(id:"shotgun",name:"Shotgun",kind:.weapon,role:.close)
        shotgun.verified=true; shotgun.maxRange=0.18; shotgun.shotInterval=0.8
        var sniper=ItemProfile(id:"sniper",name:"Sniper",kind:.weapon,role:.long)
        sniper.verified=true; sniper.minRange=0.2
        var med=ItemProfile(id:"med",name:"Med Kit",kind:.healing)
        med.verified=true; med.healthGain=50; med.useDuration=0.5
        var bandage=med; bandage.id="bandage"; bandage.healthCap=75; bandage.healthGain=15
        var shield=med; shield.id="shield"; shield.healthGain=0; shield.shieldGain=25; shield.shieldCap=50
        var grenade=ItemProfile(id:"grenade",name:"Grenade",kind:.throwable); grenade.verified=true
        return [rifle,upgrade,shotgun,sniper,med,bandage,shield,grenade]
    }
    func observation(_ t:Double=0)->Observation {
        var o=Observation(timestamp:t)
        o.phase = .alive; o.phaseConfidence=1; o.focused=true; o.perceptionReady=true
        o.playerConfidence=1; o.health=100; o.shield=100; o.hudConfidence=1
        o.selectedSlot=2; o.selectedSlotConfidence=1
        o.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20,reserveAmmo:50),.init(3,count:0),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        o.gunInHand=false // The readout was read; tests about guns in hand say so.
        return o
    }
    func engine(combat:Bool=true,loot:Bool=true,healing:Bool=true)->Coordinator {
        let c=Coordinator(profiles:profiles()); c.features.combat=combat; c.features.loot=loot; c.features.healing=healing
        c.features.idleWeapon=false // Covered by its own tests; elsewhere it would take the long gun in every quiet spell.
        return c
    }
    /// Interception without input latency or a fading lead, to check the constant-velocity geometry exactly.
    var exact:CombatSettings { var s=CombatSettings();s.leadLatency=0;s.leadPersistence=0;return s }
    /// An opponent on a known course, seen by a shooter standing still: screen and ground velocity agree.
    func enemy(_ velocity:Point = .init())->PlayerTrack { .init(id:1,position:.init(0.7,0.5),velocity:velocity,affiliation:.enemy,motion:.init(groundVelocity:velocity)) }
    func step(_ c:Coordinator,_ o:Observation)->Decision { c.step(o,now:o.timestamp) }
    func assertRelease(_ decision:Decision,file:StaticString=#filePath,line:UInt=#line) { expectEqual(decision.intents,[.releaseAll],decision.reason,file:file,line:line) }

    @Test func testFocusedLiveConfirmedEnemyFires() {
        var o=observation(); o.players=[enemy()]
        expectTrue(step(engine(),o).intents.contains(.fire))
    }
    @Test func testAllyAndUnknownNeverFireInAnyMode() {
        for mode in GameMode.allCases { for affiliation in [Affiliation.teammate,.unknown] {
            var o=observation();o.mode=mode;var p=enemy();p.affiliation=affiliation;o.players=[p]
            expectFalse(step(engine(),o).intents.contains(.fire))
        } }
    }
    @Test func testLowAffiliationConfidenceNeverFires() {
        var o=observation(); var p=enemy(); p.affiliationConfidence=CombatSettings().minAffiliationConfidence-0.05;o.players=[p]
        expectFalse(step(engine(),o).intents.contains(.fire))
        p.confidence=CombatSettings().minPlayerConfidence-0.05;p.affiliationConfidence=1;o.players=[p]
        expectFalse(step(engine(),o).intents.contains(.fire))
    }
    @Test func testWallsDoorsAndChestsStopFire() {
        for kind in [ObstacleKind.wall,.door,.chest] {
            var o=observation();o.players=[enemy()];o.obstacles=[.init(kind,bounds:.init(0.58,0.4,0.05,0.2))]
            expectFalse(step(engine(),o).intents.contains(.fire))
            expectFalse(ActionGuard(profiles:engine().profiles).permits(.fire,observation:o,now:0,aim:enemy().position))
        }
    }
    @Test func testEnemiesBehindFoliageAndRocksRemainTargets() {
        for kind in [ObstacleKind.tree,.rock] {
            var o=observation();o.players=[enemy()];o.obstacles=[.init(kind,bounds:.init(0.58,0.4,0.05,0.2))]
            let guardrail=ActionGuard(profiles:engine().profiles)
            expectFalse(Policy.clearShot(o,at:enemy().position)) // Still physically blocks bullets.
            expectTrue(Policy.immediateThreat(o))
            expectTrue(step(engine(),o).intents.contains(.fire))
            expectTrue(guardrail.permits(.fire,observation:o,now:0,aim:enemy().position))
            o.players.append(.init(id:2,position:.init(0.6,0.5),affiliation:.teammate))
            expectFalse(step(engine(),o).intents.contains(.fire))
            expectFalse(guardrail.permits(.fire,observation:o,now:0,aim:enemy().position))
        }
    }
    @Test func testTeammateInFiringPathStopsFire() {
        var o=observation();o.players=[enemy(),.init(id:2,position:.init(0.6,0.5),affiliation:.teammate)]
        expectFalse(step(engine(),o).intents.contains(.fire))
    }
    @Test func testFocusDeathMenuDownedAndUnvalidatedHalt() {
        let changes:[(inout Observation)->Void]=[{ $0.focused=false },{ $0.phase = .dead },{ $0.phase = .menu },{ $0.phase = .downed },{ $0.perceptionReady=false },{ $0.captureHealthy=false },{ $0.manualOverride=true },{ $0.playerConfidence=0.9 },{ $0.phaseConfidence=0.9 }]
        for change in changes { var o=observation();o.players=[enemy()];change(&o);assertRelease(step(engine(),o)) }
    }
    @Test func testStaleAndFutureAndNonFiniteFramesHalt() {
        let c=engine();let o=observation()
        assertRelease(c.step(o,now:0.2));assertRelease(c.step(o,now:-1));assertRelease(c.step(o,now:.nan))
    }
    @Test func testDuplicateFrameDoesNotRepeatInput() {
        let c=engine(); var o=observation();o.players=[enemy()]
        _=step(c,o);assertRelease(step(c,o))
    }
    @Test func testTargetLossReleasesFire() {
        let c=engine();var o=observation();o.players=[enemy()];_=step(c,o)
        o.timestamp=0.05;o.players=[];assertRelease(step(c,o))
    }
    @Test func testSelectWeaponThenWaitForAcknowledgmentAndSwitchDelay() {
        let c=engine();var o=observation();o.players=[enemy()];o.selectedSlot=3
        expectTrue(step(c,o).intents.contains(.selectSlot(2)))
        o.timestamp=0.05;assertRelease(step(c,o))
        o.selectedSlot=2;o.timestamp=0.1;assertRelease(step(c,o))
        o.timestamp=0.25;expectTrue(step(c,o).intents.contains(.fire))
    }
    @Test func testReloadWaitsForAmmoAcknowledgment() {
        let c=engine();var o=observation();o.players=[enemy()];o.inventory[1].ammo=0
        expectTrue(step(c,o).intents.contains(.reload))
        o.timestamp=0.1;assertRelease(step(c,o))
        o.timestamp=1;o.inventory[1].ammo=20;expectTrue(step(c,o).intents.contains(.fire))
    }
    @Test func testUnreadAmmunitionStillFires() {
        // The readout changes with every shot, so mid-fight it is often between reads; only a read empty magazine stops fire.
        var o=observation();o.players=[enemy()];o.inventory[1].ammo=nil;o.inventory[1].reserveAmmo=nil
        expectTrue(step(engine(),o).intents.contains(.fire))
        expectTrue(ActionGuard(profiles:engine().profiles).permits(.fire,observation:o,now:0,aim:enemy().position))
    }
    /// A heal's slot switch that never shows, which leaves a settling period of a second.
    func timedOutHealSelection()->(Coordinator,Observation) {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med",count:1)
        _=step(c,o);o.timestamp=2.1
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        o.timestamp=3.2;expectEqual(step(c,o).reason,"Slot selection timed out")
        o.timestamp=3.3;expectEqual(step(c,o).reason,"Waiting for the game to settle")
        return (c,o)
    }
    @Test func testCombatDoesNotWaitOutSettlingPeriods() {
        var (c,o)=timedOutHealSelection()
        o.timestamp=3.35;o.players=[enemy()];expectTrue(step(c,o).intents.contains(.fire))
    }
    @Test func testOpponentBeyondEveryRangeStillGetsAFirearm() {
        let c=engine();var o=observation();o.inventory[1] = .init(2,itemID:"shotgun",ammo:5);o.selectedSlot=3
        o.players=[.init(id:1,position:.init(0.8,0.5),affiliation:.enemy,motion:.init(groundVelocity:.init()))] // Beyond the shotgun's 0.18.
        expectTrue(step(c,o).intents.contains(.selectSlot(2)))
        o.selectedSlot=2;o.timestamp=0.3
        let tracking=step(c,o)
        expectFalse(tracking.intents.contains(.fire));expectTrue(tracking.intents.contains(.aim(.init(0.8,0.5))))
        expectEqual(tracking.reason,"Opponent beyond Shotgun range; tracking")
    }
    @Test func testStatusSaysWhyAVisiblePlayerIsNotEngaged() {
        var o=observation();var p=enemy();p.confirmed=false;o.players=[p]
        expectEqual(step(engine(),o).reason,"Player spotted; confirming it is real")
        o.players=[enemy()];o.obstacles=[.init(.wall,bounds:.init(0.58,0.4,0.05,0.2))]
        expectEqual(step(engine(),o).reason,"Enemy behind cover; holding fire")
    }
    @Test func testSemiAutomaticCadence() {
        let c=engine();var o=observation();o.inventory[1].itemID="shotgun";o.players=[.init(id:1,position:.init(0.6,0.5),affiliation:.enemy,motion:.init(groundVelocity:.init()))]
        expectTrue(step(c,o).intents.contains(.fire));o.timestamp=0.1
        expectFalse(step(c,o).intents.contains(.fire));o.timestamp=0.9
        expectTrue(step(c,o).intents.contains(.fire))
    }
    @Test func testAimUsesVelocityAndLatency() {
        var o=observation();let p=enemy(.init(0,0.1));o.players=[p]
        let d=engine().step(o,now:0.05)
        let aim=d.intents.compactMap { if case .aim(let p)=$0 { return p };return nil }.first!
        expectGreater(aim.y,p.position.y)
    }
    @Test func testInterceptMeetsMovingTargetAcrossAspectsAndFrameAges() throws {
        for aspect in [1.0,16.0/9.0,3840.0/1736.0] {
            for age in [0.0,0.12] {
                for velocity in [Point(),Point(0.4,0),Point(-0.4,0),Point(0,0.6),Point(-0.2,0.3)] {
                    var o=observation();o.aspect=aspect
                    let target=enemy(velocity)
                    let weapon=profiles()[0]
                    let aim=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:age,settings:exact))
                    let flight=aim.distance(to:o.player,aspect:aspect)/weapon.projectileSpeed
                    let future=target.position+velocity*(age+flight)
                    #expect(aim.distance(to:future,aspect:aspect)<1e-10)
                }
            }
        }
    }
    @Test func testLongLeadIsAcceptedByInputGuard() throws {
        var weapon=profiles()[0];weapon.projectileSpeed=0.4
        let c=Coordinator(profiles:[weapon],settings:exact), guardrail=ActionGuard(profiles:[weapon.id:weapon],settings:exact)
        var o=observation();let target=enemy(Point(0.2,0));o.players=[target]
        let decision=c.step(o,now:0.05)
        let aim=try #require(decision.intents.compactMap { if case .aim(let p)=$0 { return p };return nil }.first)
        #expect(abs(aim.x-0.92)<1e-10) // More than the previous 0.1 displacement and 0.25-second caps.
        #expect(decision.intents.contains(.fire))
        #expect(guardrail.permits(.fire,observation:o,now:0.055,aim:aim))
        #expect(!guardrail.permits(.fire,observation:o,now:0.05,aim:target.position))
    }
    @Test func testInterceptDegenerateAndUnreachableCases() throws {
        var o=observation();var target=enemy();var weapon=profiles()[0];weapon.projectileSpeed=0.4
        target=enemy(Point(-0.4,0))
        let equalSpeed=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0,settings:exact))
        #expect(abs(equalSpeed.x-0.6)<1e-10)
        target=enemy(Point(-0.8,0))
        let fastApproach=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0,settings:exact))
        #expect(abs(fastApproach.x-(0.5+0.2/3))<1e-10)
        for velocity in [Point(0.4,0),Point(0.8,0),Point(0,1),Point(.nan,0),Point(.greatestFiniteMagnitude,0)] {
            target=enemy(velocity)
            #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0,settings:exact)==nil)
        }
        target=enemy(Point(0.3,0)) // Future intersection would be outside the viewport.
        #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0,settings:exact)==nil)
        target=enemy(Point(0.2,0));weapon.maxRange=0.3 // Present position in range, intercept beyond range.
        #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0,settings:exact)==nil)
        o.players=[target]
        #expect(!Coordinator(profiles:[weapon],settings:exact).step(o,now:0).intents.contains(.fire))
    }
    @Test func testUncalibratedSpeedOnlyCompensatesFrameAge() throws {
        let o=observation();let target=enemy(Point(0.2,0.1))
        var weapon=profiles()[0];weapon.projectileSpeed=0
        let aim=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0.1,settings:exact))
        #expect(aim.distance(to:Point(0.72,0.51))<1e-10)
        #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0.2,settings:exact)==nil)
    }
    @Test func testPredictedPathDoesNotFallBackToUnledShot() throws {
        var o=observation();let target=enemy(Point(0,0.8));o.players=[target]
        var weapon=profiles()[0];weapon.projectileSpeed=0.6
        let predicted=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0))
        let halfway=o.player+(predicted-o.player)*0.5
        o.obstacles=[.init(.wall,bounds:.init(halfway.x-0.01,halfway.y-0.01,0.02,0.02))]
        #expect(Policy.canFireToward(o,at:target.position))
        #expect(!Coordinator(profiles:[weapon]).step(o,now:0).intents.contains(.fire))
        o.obstacles=[];o.players.append(.init(id:2,position:halfway,affiliation:.unknown))
        #expect(!Coordinator(profiles:[weapon]).step(o,now:0).intents.contains(.fire))
        #expect(!ActionGuard(profiles:[weapon.id:weapon]).permits(.fire,observation:o,now:0,aim:predicted))
    }
    func itemPrompt(_ name:String,_ id:String,_ kind:InteractionPrompt.Kind = .healing,stable:Bool=true)->InteractionPrompt {
        InteractionPrompt(name:name,subtitle:kind == .weapon ? "Rare AR" : "Healing",kind:kind,itemID:id,stable:stable)
    }
    @Test func testPickupNeedsStableItemPrompt() {
        var o=observation();o.prompt=itemPrompt("Med Kit","med")
        expectTrue(step(engine(),o).intents.contains(.pickup("Med Kit")))
        o.prompt=itemPrompt("Med Kit","med",stable:false);expectFalse(step(engine(),o).intents.contains(.pickup("Med Kit")))
        for (name,subtitle) in [("Gold Chest","Interact"),("Hoverboard","Exit Vehicle"),("Door","Open"),("Chris_Hansen","Revive")] {
            o.prompt=InteractionPrompt(name:name,subtitle:subtitle,kind:.other)
            expectEqual(step(engine(),o).intents,[.releaseAll])
        }
    }
    @Test func testPickupIsPressedAgainOnlyWhileTheItemStillShows() {
        // The item still on the panel after a press the game missed: pressed again, three times in all, then left alone.
        let c=engine();var o=observation();o.selectedSlot=3;o.prompt=itemPrompt("Med Kit","med")
        expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=0.1;assertRelease(step(c,o))
        o.timestamp=0.6;expectEqual(step(c,o).intents,[.releaseAll,.pickup("Med Kit")])
        o.timestamp=1.2;expectEqual(step(c,o).reason,"Pick up Med Kit (press 3)")
        o.timestamp=1.8;expectEqual(step(c,o).reason,"Med Kit not picked up after 3 presses; not pressing again for 3 s")
        o.timestamp=2.5;expectFalse(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=4.8;expectEqual(step(c,o).reason,"Pick up Med Kit")
        // An item that leaves the panel was taken, even when its slot shows no change (stack counts are rarely read).
        let d=engine();o.timestamp=0;o.inventory[2] = .init(3,itemID:"med",count:1)
        expectTrue(step(d,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=0.2;o.prompt=nil;o.promptVisible=true;expectEqual(step(d,o).reason,"Waiting for pickup confirmation") // Panel not read yet.
        o.timestamp=0.3;o.promptVisible=false;expectEqual(step(d,o).reason,"Med Kit taken or left behind")
        o.timestamp=0.4;o.prompt=itemPrompt("Bandage","bandage");expectTrue(step(d,o).intents.contains(.pickup("Bandage")))
        // The next item on the panel once one is taken is decided on in that same frame.
        let e=engine();o.timestamp=0;o.prompt=itemPrompt("Med Kit","med");_=step(e,o)
        o.timestamp=0.2;o.prompt=itemPrompt("Bandage","bandage");expectEqual(step(e,o).intents,[.releaseAll,.pickup("Bandage")])
    }
    @Test func testPickupConfirmedWhenASlotFills() {
        let c=engine();var o=observation();o.prompt=itemPrompt("Med Kit","med")
        expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=0.1;o.inventory[3] = .init(4,itemID:"med");o.prompt=nil
        expectEqual(step(c,o).reason,"Pickup confirmed")
    }
    @Test func testPickupRequiresCompleteInventory() {
        var o=observation();o.inventory=Array(o.inventory.prefix(2));o.inventory.append(.init(3,count:0,confidence:0.3))
        o.prompt=itemPrompt("Med Kit","med")
        expectFalse(step(engine(healing:false),o).intents.contains(.pickup("Med Kit")))
    }
    @Test func testMissingWeaponRoleFillsAFreeSlotWithoutSwitching() {
        var o=observation();o.prompt=itemPrompt("Pump","shotgun",.weapon)
        let d=step(engine(),o)
        expectTrue(d.intents.contains(.pickup("Pump")));expectFalse(d.intents.contains(.selectSlot(3)))
    }
    @Test func testFullInventoryUpgradeSelectsTheReplacedSlotFirst() {
        let c=engine();var o=observation();o.selectedSlot=3
        o.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20),.init(3,itemID:"shotgun"),.init(4,itemID:"sniper"),.init(5,itemID:"med"),.init(6,itemID:"shield")]
        o.prompt=itemPrompt("SCAR","rifle_gold",.weapon)
        expectTrue(step(c,o).intents.contains(.selectSlot(2)))
        o.timestamp=0.03;assertRelease(step(c,o))
        // Interact needs the slot selected, not the gun ready to fire: pressed as soon as the selection shows.
        o.timestamp=0.05;o.selectedSlot=2
        let d=step(c,o);expectTrue(d.intents.contains(.pickup("SCAR")));expectEqual(d.reason,"Pick up Gold Rifle in place of Rifle")
    }
    @Test func testLootGoesBeforeHealsAndSettlingPeriods() {
        // A settling period holds up heals and swaps, not a chest or an item for a free slot.
        var (c,o)=timedOutHealSelection()
        o.timestamp=3.35;o.prompt=chestPrompt();expectEqual(step(c,o).intents,[.releaseAll,.open("Gold Chest")])
        // A chest is opened while a heal's slot switch is on its way…
        let d=engine();var p=observation();p.health=60;p.inventory[2] = .init(3,itemID:"med",count:1)
        _=step(d,p);p.timestamp=2.1;expectTrue(step(d,p).intents.contains(.selectSlot(3)))
        p.timestamp=2.15;p.prompt=chestPrompt();expectTrue(step(d,p).intents.contains(.open("Gold Chest")))
        // …low on health too, as it may hold more potions; a gun waits for the drink.
        let low=engine();var l=observation();l.health=20;l.inventory[2] = .init(3,itemID:"med",count:1)
        _=step(low,l);l.timestamp=2.1;expectTrue(step(low,l).intents.contains(.selectSlot(3)))
        l.timestamp=2.15;l.prompt=chestPrompt();expectTrue(step(low,l).intents.contains(.open("Gold Chest")))
        l.timestamp=2.2;l.prompt=itemPrompt("SCAR","rifle_gold",.weapon)
        let drink=step(low,l);expectFalse(drink.intents.contains(.pickup("SCAR")));expectEqual(drink.reason,"Select Med Kit to heal")
        // …and an item is taken before a heal starts: the loot stays behind once you walk on.
        let e=engine();var q=observation();q.health=20;q.inventory[2] = .init(3,itemID:"med",count:1)
        _=step(e,q);q.timestamp=2.1;q.prompt=itemPrompt("Bandage","bandage")
        expectTrue(step(e,q).intents.contains(.pickup("Bandage")))
        // A swap changes the selected slot, so it waits for a heal under way.
        let f=engine();var r=observation();r.health=20;r.gunInHand=nil
        r.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20),.init(3,itemID:"shotgun"),.init(4,itemID:"sniper"),.init(5,itemID:"med"),.init(6,itemID:"shield")]
        _=step(f,r);r.timestamp=2.1;expectTrue(step(f,r).intents.contains(.selectSlot(5)))
        r.timestamp=2.35;r.selectedSlot=5;expectEqual(step(f,r).reason,"Stand still: checking that Med Kit is in hand")
        r.timestamp=2.45;r.prompt=itemPrompt("SCAR","rifle_gold",.weapon)
        let held=step(f,r);expectFalse(held.intents.contains(.selectSlot(2)));expectEqual(held.reason,"Stand still: checking that Med Kit is in hand")
    }
    @Test func testAnItemInAnEmptySlotConfirmsThePickupBeforeItIsRecognized() {
        let before=[InventorySlot(2,itemID:"rifle"),InventorySlot(3,count:0)]
        expectTrue(Coordinator.inventoryGained(from:before,to:[InventorySlot(2,itemID:"rifle"),InventorySlot(3,confidence:0.5)]))
        expectFalse(Coordinator.inventoryGained(from:before,to:before))
        expectFalse(Coordinator.inventoryGained(from:[InventorySlot(3,confidence:0.5)],to:[InventorySlot(3,confidence:0.5)]))
    }
    @Test func testFullInventoryMissingRoleGivesUpAnExtraConsumable() {
        let c=engine();var o=observation()
        o.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20),.init(3,itemID:"sniper"),.init(4,itemID:"med"),.init(5,itemID:"bandage"),.init(6,itemID:"shield")]
        o.prompt=itemPrompt("Pump","shotgun",.weapon)
        let d=step(c,o)
        expectTrue(d.intents.contains(where:{ if case .selectSlot(let i)=$0 { return (4...6).contains(i) }; return false }))
        c.reset();o.inventory[5] = .init(6,count:0,confidence:1);o.timestamp=0.5
        expectTrue(step(c,o).intents.contains(.pickup("Pump"))) // A free slot appeared: no swap needed.
    }
    @Test func testLaunchersAndUnknownItemsAreNeverPickedUp() {
        var launcher=ItemProfile(id:"launcher",name:"Launcher",kind:.weapon,role:nil);launcher.verified=true
        let c=Coordinator(profiles:profiles()+[launcher]);var o=observation()
        o.prompt=itemPrompt("RPG","launcher",.weapon);expectFalse(step(c,o).intents.contains(.pickup("RPG")))
        o.timestamp=0.1;o.prompt=InteractionPrompt(name:"Mystery",subtitle:"Healing",kind:.healing,itemID:nil)
        expectFalse(step(c,o).intents.contains(.pickup("Mystery")))
    }
    @Test func testThreatPreemptsPickupAcknowledgment() {
        let c=engine();var o=observation();o.selectedSlot=3;o.prompt=itemPrompt("Med Kit","med")
        expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=0.05;o.players=[enemy()]
        expectTrue(step(c,o).intents.contains(.selectSlot(2)))
        o.timestamp=0.1;o.selectedSlot=2;assertRelease(step(c,o))
        o.timestamp=0.3;expectTrue(step(c,o).intents.contains(.fire))
    }
    func chestPrompt(_ name:String="Gold Chest",stable:Bool=true)->InteractionPrompt {
        InteractionPrompt(name:name,subtitle:"Interact",kind:.chest,stable:stable)
    }
    @Test func testChestIsPressedAgainUntilItOpens() {
        let c=engine();var o=observation();o.prompt=chestPrompt()
        expectEqual(step(c,o).intents,[.releaseAll,.open("Gold Chest")])
        o.timestamp=0.1;expectEqual(step(c,o).reason,"Opening Gold Chest")
        // Opened: its loot is under you now, and is taken in the same frame, without a settling pause.
        o.timestamp=0.3;o.prompt=itemPrompt("Med Kit","med");expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        let e=engine();o.timestamp=0;o.prompt=chestPrompt();_=step(e,o)
        o.timestamp=0.3;o.prompt=nil;expectEqual(step(e,o).reason,"Chest prompt gone; Gold Chest opened or left behind")
        // A chest still closed was a press the game missed: pressed again, three times in all, then left alone a while.
        let d=engine();o.timestamp=0;o.prompt=chestPrompt("Ammo Chest")
        expectTrue(step(d,o).intents.contains(.open("Ammo Chest")))
        o.timestamp=0.3;expectEqual(step(d,o).reason,"Opening Ammo Chest")
        o.timestamp=0.6;expectEqual(step(d,o).reason,"Open Ammo Chest (press 2)")
        o.timestamp=1.2;expectEqual(step(d,o).reason,"Open Ammo Chest (press 3)")
        o.timestamp=1.8;expectEqual(step(d,o).reason,"Ammo Chest did not open; not pressing again for 3 s")
        o.timestamp=3;expectFalse(step(d,o).intents.contains(.open("Ammo Chest")))
        o.timestamp=4.8;expectEqual(step(d,o).reason,"Open Ammo Chest")
    }
    @Test func testChestsWaitForAStablePromptNoThreatAndTheFeature() {
        var o=observation();o.prompt=chestPrompt(stable:false)
        expectFalse(step(engine(),o).intents.contains(.open("Gold Chest")))
        o.prompt=chestPrompt();o.players=[enemy()]
        expectFalse(step(engine(),o).intents.contains(.open("Gold Chest")))
        o.players=[];let off=engine();off.features.chests=false
        expectFalse(step(off,o).intents.contains(.open("Gold Chest")))
        for (name,subtitle) in [("Door","Open"),("Hoverboard","Enter Vehicle"),("Chris_Hansen","Revive")] {
            o.prompt=InteractionPrompt(name:name,subtitle:subtitle,kind:.other)
            expectEqual(step(engine(),o).intents,[.releaseAll])
        }
    }
    @Test func testInputGuardOpensOnlyTheChestOnScreen() {
        let guardrail=ActionGuard(profiles:engine().profiles);var o=observation();o.prompt=chestPrompt()
        expectTrue(guardrail.permits(.open("Gold Chest"),observation:o,now:0,aim:nil))
        expectFalse(guardrail.permits(.open("Ammo Chest"),observation:o,now:0,aim:nil))
        o.prompt=InteractionPrompt(name:"Gold Chest",subtitle:"Interact",kind:.other)
        expectFalse(guardrail.permits(.open("Gold Chest"),observation:o,now:0,aim:nil))
        o.prompt=chestPrompt();o.players=[enemy()]
        expectFalse(guardrail.permits(.open("Gold Chest"),observation:o,now:0,aim:nil))
        o.players=[];o.prompt=itemPrompt("Med Kit","med")
        expectFalse(guardrail.permits(.open("Med Kit"),observation:o,now:0,aim:nil))
    }
    @Test func testHealingWaitsTwoSecondsAndConfirmsCompletion() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med",count:1);o.selectedSlot=3
        assertRelease(step(c,o));o.timestamp=1.9;assertRelease(step(c,o));o.timestamp=2.1
        expectTrue(step(c,o).intents.contains(.useConsumable));o.timestamp=2.3
        expectTrue(step(c,o).intents.contains(.useConsumable));o.timestamp=2.8;o.health=70;o.inventory[2] = .init(3,count:0)
        expectEqual(step(c,o).reason,"Healing confirmed")
    }
    @Test func testFullHealthCapsAndShieldLimits() {
        let catalog=Dictionary(uniqueKeysWithValues:profiles().map { ($0.id,$0) })
        var o=observation();o.health=75;o.shield=50
        expectEqual(Policy.healingBenefit(catalog["bandage"]!,in:o),0)
        expectEqual(Policy.healingBenefit(catalog["shield"]!,in:o),0)
        o.health=100;o.shield=100
        expectEqual(Policy.healingBenefit(catalog["med"]!,in:o),0)
    }
    @Test func testThreatInterruptsHealing() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;_=step(c,o)
        expectEqual(c.healingItem,"Med Kit")
        o.timestamp=2.2;o.players=[enemy()]
        let decision=step(c,o)
        expectFalse(decision.intents.contains(.useConsumable))
        expectTrue(decision.intents.contains(.selectSlot(2))) // Straight to the weapon for the opponent's range.
        expectEqual(c.healingItem,nil)
    }
    @Test func testThreatCancelsAHealSelectionAndFights() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med")
        _=step(c,o);o.timestamp=2.1
        let selecting=step(c,o)
        expectTrue(selecting.intents.contains(.selectSlot(3)));expectEqual(c.healingItem,"Med Kit")
        o.timestamp=2.15;o.selectedSlot=3;o.players=[enemy()]
        expectTrue(step(c,o).intents.contains(.selectSlot(2)));expectEqual(c.healingItem,nil)
        o.timestamp=2.2;o.selectedSlot=2;assertRelease(step(c,o))
        o.timestamp=2.4;expectTrue(step(c,o).intents.contains(.fire))
    }
    @Test func testConfirmedPlayerBehindAWallDelaysHealing() {
        // Never fired on, but a confirmed player anywhere in view delays the next heal by two seconds.
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=1.5;o.players=[enemy()];o.obstacles=[.init(.wall,bounds:.init(0.58,0.4,0.05,0.2))]
        expectEqual(step(c,o).reason,"Enemy behind cover; holding fire")
        o.timestamp=2.1;o.players=[];o.obstacles=[]
        expectFalse(step(c,o).intents.contains(.useConsumable))
        o.timestamp=3.6;expectTrue(step(c,o).intents.contains(.useConsumable))
    }
    @Test func testStrayDetectionsDoNotFlipBetweenHealAndGun() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med")
        _=step(c,o);o.timestamp=2.1
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        var stray=enemy();stray.confirmed=false // A one-frame false detection.
        o.timestamp=2.15;o.players=[stray];assertRelease(step(c,o))
        expectEqual(c.healingItem,"Med Kit")
        o.timestamp=2.4;o.players=[];o.selectedSlot=3
        expectTrue(step(c,o).intents.contains(.useConsumable))
        // A confirmed player behind a wall cannot be fought; the heal carries on.
        o.timestamp=2.5;o.players=[enemy()];o.obstacles=[.init(.wall,bounds:.init(0.58,0.4,0.05,0.2))]
        expectEqual(step(c,o).intents,[.useConsumable]);expectEqual(c.healingItem,"Med Kit")
    }
    @Test func testBriefUnreadableHUDDoesNotCutAHealShort() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.useConsumable))
        o.timestamp=2.2;o.hudConfidence=0
        let held=step(c,o)
        expectEqual(held.intents,[]);expectEqual(c.healingItem,"Med Kit") // Keeps holding; nothing released.
        o.timestamp=2.3;o.hudConfidence=1;expectEqual(step(c,o).intents,[.useConsumable])
        o.timestamp=2.4;o.hudConfidence=0;_=step(c,o)
        o.timestamp=3.0;expectEqual(step(c,o).reason,"Healing state became uncertain")
    }
    @Test func testCommittedHealTakesFurtherDosesWithoutAnotherSafeGap() {
        let c=engine();var o=observation();o.shield=0;o.inventory[2] = .init(3,itemID:"shield",count:2);o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.useConsumable))
        o.timestamp=2.5;o.shield=25;expectTrue(step(c,o).intents.contains(.useConsumable)) // Still drinking: 0.5 s plus a margin.
        o.timestamp=2.8;o.inventory[2].count=1;expectEqual(step(c,o).reason,"Healing confirmed")
        o.timestamp=3.05;expectTrue(step(c,o).intents.contains(.useConsumable)) // Shields are not full yet.
        o.timestamp=3.5;o.shield=50;o.inventory[2] = .init(3,count:0);expectEqual(step(c,o).reason,"Healing confirmed")
        o.timestamp=3.75;_=step(c,o);expectEqual(c.healingItem,nil)
    }
    @Test func testUnknownPlayerAlsoDelaysHealing() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;o.players=[.init(id:4,position:.init(0.7,0.5),affiliation:.unknown)]
        expectFalse(step(c,o).intents.contains(.useConsumable))
    }
    @Test func testDamageWithoutVisibleEnemyDelaysHealing() {
        let c=engine();var o=observation();o.health=60;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;o.health=40;expectFalse(step(c,o).intents.contains(.useConsumable))
    }
    func recoveryStart()->(Coordinator,Observation) {
        let c=engine();var o=observation();o.health=20
        o.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20),.init(3,itemID:"shotgun",ammo:10),.init(4,itemID:"sniper",ammo:10),.init(5,itemID:"grenade"),.init(6,itemID:"grenade")]
        o.prompt=itemPrompt("Med Kit","med")
        _=step(c,o);o.timestamp=2.1
        expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=2.2;o.inventory[1] = .init(2,itemID:"med");o.prompt=itemPrompt("Rifle","rifle",.weapon)
        _=step(c,o);o.timestamp=2.5
        expectTrue(step(c,o).intents.contains(.useConsumable))
        return(c,o)
    }
    @Test func testTemporaryHealingSwapRecoversWeapon() {
        let(c,base)=recoveryStart();var o=base
        o.timestamp=3.1;o.health=70;o.inventory[1] = .init(2,count:0);_=step(c,o)
        o.timestamp=3.4;expectTrue(step(c,o).intents.contains(.pickup("Rifle")))
        o.timestamp=3.5;o.inventory[1] = .init(2,itemID:"rifle",ammo:20);o.prompt=nil
        expectEqual(step(c,o).reason,"Pickup confirmed")
    }
    @Test func testRecoveryDoesNotChaseMissingWeapon() {
        let(c,base)=recoveryStart();var o=base
        o.timestamp=3.1;o.health=70;o.inventory[1] = .init(2,count:0);o.prompt=nil;_=step(c,o)
        o.timestamp=3.4;expectFalse(step(c,o).intents.contains(.pickup("Rifle")))
    }
    @Test func testRecoveryNeverSwapsOutRemainingConsumableStack() {
        let(c,base)=recoveryStart();var o=base
        o.timestamp=2.6;o.inventory[1].count=2;_=step(c,o)
        o.timestamp=3.1;o.health=70;o.inventory[1].count=1;_=step(c,o)
        o.timestamp=3.4;expectFalse(step(c,o).intents.contains(.pickup("Rifle")))
    }
    @Test func testActionGuardRejectsWrongItemEvenWithFireIntent() {
        let c=engine();let guardrail=ActionGuard(profiles:c.profiles)
        var o=observation();o.players=[enemy()];o.inventory[1].itemID="med"
        expectFalse(guardrail.permits(.fire,observation:o,now:0,aim:.init(0.7,0.5)))
        o.inventory[1].itemID="grenade"
        expectFalse(guardrail.permits(.fire,observation:o,now:0,aim:.init(0.7,0.5)))
    }
    @Test func testActionGuardRejectsUnverifiedProfiles() {
        var p=profiles()[0];p.verified=false
        var o=observation();o.players=[enemy()]
        expectFalse(ActionGuard(profiles:[p.id:p]).permits(.fire,observation:o,now:0,aim:.init(0.7,0.5)))
    }
    @Test func testMovementBindingsCannotBeConfigured() {
        expectTrue(KeyBindings().isValid)
        for key:UInt16 in [0,1,2,13,123,124,125,126,53,49] {
            var bindings=KeyBindings();bindings.interact=key;expectFalse(bindings.isValid)
        }
        var duplicate=KeyBindings();duplicate.reload=duplicate.interact;expectFalse(duplicate.isValid)
    }
    @Test func testPerformanceGateRequiresMeasuredThroughputAndLatency() {
        var fast=PerformanceWindow(),slow=PerformanceWindow()
        for i in 0..<200 { let t=Double(i)/30;fast.record(frameTime:t,completedAt:t+0.04);slow.record(frameTime:t,completedAt:t+0.2) }
        expectTrue(fast.passes);expectFalse(slow.passes)
    }
    @Test func testSegmentGeometryAcrossAspectAndParallelEdges() {
        let box=Rect(0.5,0.4,0.1,0.1)
        expectTrue(box.intersectsSegment(from:.init(0.2,0.45),to:.init(0.9,0.45)))
        expectFalse(box.intersectsSegment(from:.init(0.2,0.3),to:.init(0.9,0.3)))
        expectTrue(box.intersectsSegment(from:.init(0.55,0.45),to:.init(0.9,0.45)))
    }
    @Test func testObservationAndIntentRoundTrip() throws {
        let o=observation();expectEqual(try JSONDecoder().decode(Observation.self,from:JSONEncoder().encode(o)),o)
        let decision=Decision(0,[.aim(.init(0.7,0.5)),.fire],"test")
        expectEqual(try JSONDecoder().decode(Decision.self,from:JSONEncoder().encode(decision)),decision)
    }
    @Test func testAllFeaturesDisabledNeverProduceInput() {
        var o=observation();o.players=[enemy()];let c=engine(combat:false,loot:false,healing:false)
        assertRelease(step(c,o))
    }
    @Test func testEmptiedSlotEndsTheDoseAtOnce() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;_=step(c,o)
        o.timestamp=2.4;o.inventory[2] = .init(3,count:0)
        let done=step(c,o);expectEqual(done.reason,"Healing confirmed");assertRelease(done)
        o.timestamp=2.7;o.health=70;expectFalse(step(c,o).intents.contains(.useConsumable))
    }
    @Test func testPickupGuardChecksThePromptAndThreat() {
        let guardrail=ActionGuard(profiles:engine().profiles)
        var o=observation();o.prompt=itemPrompt("Med Kit","med")
        expectTrue(guardrail.permits(.pickup("Med Kit"),observation:o,now:0,aim:nil))
        expectFalse(guardrail.permits(.pickup("Bandage"),observation:o,now:0,aim:nil))
        o.prompt?.stable=false;expectFalse(guardrail.permits(.pickup("Med Kit"),observation:o,now:0,aim:nil))
        o.prompt?.stable=true;o.players=[enemy()];expectFalse(guardrail.permits(.pickup("Med Kit"),observation:o,now:0,aim:nil))
        o.players=[];o.prompt=InteractionPrompt(name:"Med Kit",subtitle:"Interact",kind:.other)
        expectFalse(guardrail.permits(.pickup("Med Kit"),observation:o,now:0,aim:nil))
    }
    @Test func testWeaponUpgradeAndNoDowngradeLoop() {
        let c=engine();var o=observation()
        o.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20),.init(3,itemID:"shotgun"),.init(4,itemID:"sniper"),.init(5,itemID:"med"),.init(6,itemID:"shield")]
        o.prompt=itemPrompt("SCAR","rifle_gold",.weapon)
        expectTrue(step(c,o).intents.contains(.pickup("SCAR")))
        o.timestamp=0.1;o.inventory[1].itemID="rifle_gold";o.prompt=itemPrompt("M4","rifle",.weapon)
        _=step(c,o);o.timestamp=0.4
        expectFalse(step(c,o).intents.contains(.pickup("M4")))
    }
    // MARK: Weapon bands
    /// Shotgun, rifle and sniper loaded, with the rifle held, against an opponent `distance` to the right.
    func armed(_ distance:Double,_ t:Double=0)->Observation {
        var o=observation(t)
        o.inventory=[.init(1,itemID:"melee"),.init(2,itemID:"rifle",ammo:20,reserveAmmo:50),.init(3,itemID:"shotgun",ammo:5,reserveAmmo:10),
                     .init(4,itemID:"sniper",ammo:5,reserveAmmo:10),.init(5,count:0),.init(6,count:0)]
        o.players=[.init(id:1,position:.init(0.5+distance,0.5),affiliation:.enemy,motion:.init(groundVelocity:.init()))]
        return o
    }
    @Test func testWeaponFollowsTheDistanceBand() {
        expectTrue(step(engine(),armed(0.08)).intents.contains(.selectSlot(3)))  // Close: shotgun.
        expectTrue(step(engine(),armed(0.2)).intents.contains(.fire))            // Medium: keep the rifle.
        expectTrue(step(engine(),armed(0.42)).intents.contains(.selectSlot(4)))  // Long: sniper.
    }
    @Test func testBandHysteresisAndDwellPreventFlapping() {
        let c=engine();var o=armed(0.08);o.selectedSlot=3
        expectTrue(step(c,o).intents.contains(.fire))
        o=armed(0.14,0.1);o.selectedSlot=3 // Just past the cutoff: still close range.
        expectFalse(step(c,o).intents.contains(.selectSlot(2)))
        o=armed(0.2,0.2);o.selectedSlot=3
        expectTrue(step(c,o).intents.contains(.selectSlot(2)))
        o=armed(0.08,0.5);o.selectedSlot=2 // Back to close range within the dwell time: keep firing the rifle.
        expectTrue(step(c,o).intents.contains(.fire))
        o=armed(0.08,0.9);o.selectedSlot=2
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
    }
    @Test func testEmptyMagazineSwitchesToALoadedWeaponBeforeReloading() {
        var smg=ItemProfile(id:"smg",name:"SMG",kind:.weapon,role:.close);smg.verified=true;smg.weaponClass = .smg;smg.automatic=true
        let c=Coordinator(profiles:profiles()+[smg]);var o=armed(0.2);o.inventory[1].ammo=0
        o.inventory[2] = .init(3,itemID:"smg",ammo:30,reserveAmmo:60)
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        var lone=armed(0.2);lone.inventory=Array(lone.inventory.prefix(2));lone.inventory[1].ammo=0
        expectTrue(step(engine(),lone).intents.contains(.reload))
    }
    @Test func testWeaponsWithoutAmmunitionAreSkipped() {
        var o=armed(0.08);o.inventory[2].ammo=0;o.inventory[2].reserveAmmo=0
        let d=step(engine(),o)
        expectFalse(d.intents.contains(.selectSlot(3)));expectTrue(d.intents.contains(.fire))
    }
    @Test func testCatalogWeaponsFollowTheBands() {
        let catalog=ItemCatalog.standard;let c=Coordinator(catalog:catalog)
        expectTrue(catalog.profiles.allSatisfy(\.isValid))
        var o=armed(0.08)
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:epic",ammo:30,reserveAmmo:90),.init(3,itemID:"shotgun:common",ammo:5,reserveAmmo:12),
                     .init(4,itemID:"sniper:rare",ammo:5,reserveAmmo:20),.init(5,itemID:"smg:legendary",ammo:30,reserveAmmo:90),.init(6,itemID:"hybrid_potion")]
        expectTrue(step(c,o).intents.contains(.selectSlot(3))) // A common shotgun still beats a legendary SMG up close.
        c.reset();o=armed(0.42);o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:epic",ammo:30,reserveAmmo:90),.init(3,itemID:"sniper:rare",ammo:5,reserveAmmo:20)]
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        expectEqual(ItemCatalog.parseWeaponID("ar:legendary")?.0,WeaponClass.ar)
        expectEqual(ItemCatalog.parseWeaponID(ItemCatalog.weaponID(.sniper,.mythic))?.1,Rarity.mythic)
    }

    // MARK: Named guns
    @Test func testCatalogNamesGunsFromPromptsAndIcons() {
        let catalog=ItemCatalog.standard
        expectEqual(catalog.weaponID(.ar,.rare,name:"M4"),"ar:rare:m4")
        expectEqual(catalog.weaponID(.ar,.epic,name:"АК"),"ar:epic:ak")                              // Cyrillic look-alikes, as OCR read them once.
        expectEqual(catalog.weaponID(.sniper,.rare,name:"Bolt Mk. Il Sniper"),"sniper:rare:bolt_mk2")  // One misread letter in a long name.
        expectEqual(catalog.weaponID(.ar,.rare,name:"M5"),"ar:rare")                                 // Short names must match exactly.
        expectEqual(catalog.weaponID(.shotgun,.rare,name:"M4"),"shotgun:rare")                       // Another class's gun is not trusted.
        expectEqual(catalog.weaponID(.ar,.rare,name:""),"ar:rare")
        expectEqual(ItemCatalog.parseWeaponID("ar:rare:m4")?.1,Rarity.rare)
        expectEqual(ItemCatalog.modelID(in:"ar:rare:m4"),"m4");expectEqual(ItemCatalog.modelID(in:"ar:rare"),nil)
        expectTrue(catalog.profile("ar:rare:nosuchgun")==nil);expectTrue(catalog.profile("shotgun:rare:m4")==nil)
        // A gun swapped out for a potion is recognized again even if one of the two readings missed its name.
        expectTrue(Coordinator.sameItem("ar:rare:m4","ar:rare"));expectFalse(Coordinator.sameItem("ar:rare:m4","ar:rare:ak"))
        expectFalse(Coordinator.sameItem("ar:rare","ar:epic"));expectTrue(Coordinator.sameItem("med","med"))
        let ids=Set(catalog.profiles.map(\.id))
        expectTrue(catalog.models.allSatisfy { m in Rarity.allCases.allSatisfy { ids.contains(ItemCatalog.weaponID(m.weaponClass,$0,model:m.id)) } })
        expectTrue(catalog.profiles.allSatisfy(\.isValid))
    }
    @Test func testGunNamesSurviveCommonMisreads() {
        let catalog=ItemCatalog.standard
        // Look-alike characters in the prompt's font, and a stray mark beside the name.
        expectEqual(catalog.weaponID(.smg,.rare,name:"MPS"),"smg:rare:mp5")
        expectEqual(catalog.weaponID(.smg,.rare,name:"P9O"),"smg:rare:p90")
        expectEqual(catalog.weaponID(.smg,.epic,name:"Uzl"),"smg:epic:uzi");expectEqual(catalog.weaponID(.smg,.epic,name:"Üzi"),"smg:epic:uzi")
        expectEqual(catalog.weaponID(.ar,.rare,name:"AR-I5"),"ar:rare:ar15")
        expectEqual(catalog.weaponID(.ar,.mythic,name:"XMB"),"ar:mythic:xm8")
        expectEqual(catalog.weaponID(.ar,.mythic,name:"MG3G"),"ar:mythic:mg36")
        expectEqual(catalog.weaponID(.sniper,.mythic,name:"AVVP"),"sniper:mythic:awp")
        expectEqual(catalog.weaponID(.sniper,.rare,name:"V55"),"sniper:rare:vss")
        expectEqual(catalog.weaponID(.shotgun,.uncommon,name:"KSG Shotgun Z"),"shotgun:uncommon:ksg_shotgun") // Read so in a recording.
        expectEqual(catalog.weaponID(.ar,.rare,name:"M4 E"),"ar:rare:m4")
        expectEqual(HUDText.prompt(lines:["MPS","Epic SMG"],confidence:1,catalog:catalog)?.itemID,"smg:epic:mp5")
        // Nothing else is guessed: a short name one letter off, or another class's gun.
        expectEqual(catalog.weaponID(.ar,.rare,name:"M5"),"ar:rare");expectEqual(catalog.weaponID(.ar,.rare,name:"MP5"),"ar:rare")
        // No two guns of a class share a shape key, so a look-alike never names the wrong gun.
        for weaponClass in WeaponClass.allCases {
            let shapes=catalog.models.filter { $0.weaponClass==weaponClass }.map { m in Set(([m.name]+(m.aliases ?? [])).map(ItemCatalog.shapeKey)) }
            for (i,a) in shapes.enumerated() { for b in shapes.dropFirst(i+1) { expectEqual(a.intersection(b),[],"\(weaponClass)") } }
        }
    }
    @Test func testNamedGunsUseTheWikiStats() {
        let catalog=ItemCatalog.standard
        func gun(_ id:String)->ItemProfile { catalog.profile(id)! }
        expectEqual(gun("sniper:epic:semi_auto_sniper").shotInterval,0.25);expectEqual(gun("sniper:epic").shotInterval,1.1)
        expectTrue(gun("sniper:legendary:vss").automatic);expectEqual(gun("sniper:legendary:vss").ammo,.small)
        expectEqual(gun("smg:rare:tommy_gun").ammo,.medium)
        expectTrue(gun("pistol:epic:silenced_pistol").automatic);expectFalse(gun("pistol:epic:deagle").automatic)
        expectEqual(gun("pistol:epic:silenced_pistol").role,.medium) // Pistols stay the fallback they were.
        expectEqual(gun("ar:rare:m4").name,"Rare M4");expectEqual(gun("ar:rare").name,"Rare AR")
        // What the wiki only describes in words stays the class estimate: range, bullet speed and zoom.
        expectEqual(gun("sniper:rare:awp").zoom,1.2);expectEqual(gun("ar:rare:m4").maxRange,gun("ar:rare").maxRange)
        expectEqual(gun("launcher:rare:rpg").role,nil) // Launchers stay manual.
    }
    @Test func testPowerFollowsTheRankingAndRarity() {
        let catalog=ItemCatalog.standard
        func power(_ id:String)->Double { catalog.profile(id)!.power! }
        // At the best rarity each gun normally drops at, power follows the ranking of docs/WEAPONS.md.
        let ranked=catalog.models.sorted { $0.rank < $1.rank }.map { power(ItemCatalog.weaponID($0.weaponClass,$0.best,model:$0.id)) }
        expectEqual(ranked,ranked.sorted(by:>))
        expectEqual(power("ar:epic:m4")-power("ar:rare:m4"),3)          // One rarity step.
        expectTrue(power("ar:uncommon:m4")>power("ar:legendary:ak"))     // About the same kill time; the M4 is steadier.
        expectEqual(power("ar:legendary"),85)                              // An unnamed rifle counts as an average one…
        expectEqual(catalog.profile("ar:rare")!.edge,0)                    // …with no edge over its class.
        expectTrue(catalog.profile("ar:rare:m4")!.edge>0 && catalog.profile("ar:rare:ak")!.edge<0)
    }
    /// Catalog guns in slots 2 to 4 and two potions, with a potion selected.
    func stocked(_ close:String,_ medium:String,_ long:String)->(Coordinator,Observation) {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.selectedSlot=5
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:close,ammo:5,reserveAmmo:10),.init(3,itemID:medium,ammo:30,reserveAmmo:90),
                     .init(4,itemID:long,ammo:5,reserveAmmo:10),.init(5,itemID:"hybrid_potion",count:2),.init(6,itemID:"small_shield",count:2)]
        return (c,o)
    }
    func gunPrompt(_ name:String,_ subtitle:String)->InteractionPrompt? { HUDText.prompt(lines:[name,subtitle],confidence:1,catalog:.standard) }
    @Test func testPickupsKeepTheStrongerNamedGun() {
        // A Legendary UMP beats an Epic Pump Shotgun: the shotgun's slot is selected for the swap.
        var (c,o)=stocked("shotgun:epic:pump_shotgun","ar:rare:m4","sniper:rare:bolt_mk2");o.prompt=gunPrompt("UMP","Legendary SMG")
        expectTrue(step(c,o).intents.contains(.selectSlot(2)))
        // At the same rarity an M4 replaces an AK, never the other way round.
        (c,o)=stocked("smg:rare:mp5","ar:rare:ak","sniper:rare:bolt_mk2");o.prompt=gunPrompt("M4","Rare AR")
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        (c,o)=stocked("smg:rare:mp5","ar:rare:m4","sniper:rare:bolt_mk2");o.prompt=gunPrompt("AK","Rare AR")
        var d=step(c,o);expectFalse(d.intents.contains(.selectSlot(3)));expectFalse(d.intents.contains(.pickup("AK")))
        expectEqual(d.reason,"Not picking up Rare AK: not better than Rare M4")
        // Near equals are not worth a swap: a Legendary Uzi for a Legendary MP5.
        (c,o)=stocked("smg:legendary:mp5","ar:rare:m4","sniper:rare:bolt_mk2");o.prompt=gunPrompt("Uzi","Legendary SMG")
        expectFalse(step(c,o).intents.contains(.selectSlot(2)))
        // Of one class the rarer gun wins, whatever the ranking: an Epic Semi-Auto Sniper does not replace a Legendary Bolt Mk. II…
        (c,o)=stocked("smg:rare:mp5","ar:rare:m4","sniper:legendary:bolt_mk2");o.prompt=gunPrompt("Semi-Auto Sniper","Epic Sniper")
        expectEqual(step(c,o).reason,"Not picking up Epic Semi-Auto Sniper: not better than Legendary Bolt Mk. II Sniper")
        // …and a Legendary AK replaces an Epic M4.
        (c,o)=stocked("smg:rare:mp5","ar:epic:m4","sniper:rare:bolt_mk2");o.prompt=gunPrompt("AK","Legendary AR")
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        (c,o)=stocked("smg:rare:mp5","ar:legendary:ak","sniper:rare:bolt_mk2");o.prompt=gunPrompt("M4","Epic AR")
        expectEqual(step(c,o).reason,"Not picking up Epic M4: not better than Legendary AK")
        // A gun whose name was never read counts as an average one of its class.
        (c,o)=stocked("smg:rare:mp5","ar:legendary","sniper:rare:bolt_mk2");o.prompt=gunPrompt("M4","Legendary AR")
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        (c,o)=stocked("smg:rare:mp5","ar:legendary","sniper:rare:bolt_mk2");o.prompt=gunPrompt("AK","Legendary AR")
        d=step(c,o);expectFalse(d.intents.contains(.selectSlot(3)))
    }
    @Test func testTheBetterGunOfAClassIsChosenForTheBand() throws {
        // Two SMGs up close: the UMP, though the MP5 is in hand.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=armed(0.08)
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"smg:legendary:mp5",ammo:30,reserveAmmo:90),.init(3,itemID:"smg:legendary:ump",ammo:35,reserveAmmo:90),
                     .init(4,count:0),.init(5,count:0),.init(6,count:0)]
        expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        // In a quiet spell the rarer sniper is carried: a Legendary Bolt Mk. II before an Epic Semi-Auto Sniper.
        let q=Coordinator(catalog:.standard);var p=observation();p.selectedSlot=2
        p.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"smg:rare:mp5",ammo:30,reserveAmmo:90),.init(3,itemID:"sniper:legendary:bolt_mk2",ammo:5,reserveAmmo:10),
                     .init(4,itemID:"sniper:epic:semi_auto_sniper",ammo:5,reserveAmmo:10),.init(5,count:0),.init(6,count:0)]
        _=step(q,p);p.timestamp=2.6
        let d=step(q,p);expectTrue(d.intents.contains(.selectSlot(3)));expectEqual(d.reason,"Carry Legendary Bolt Mk. II Sniper while nothing is happening")
    }
    @Test func testSemiAutoSniperFiresFourTimesASecond() throws {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=armed(0.42)
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"sniper:epic:semi_auto_sniper",ammo:5,reserveAmmo:20),.init(3,count:0),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        let first=step(c,o);expectTrue(first.intents.contains(.fire))
        // The input guard checks the shot against the same named profile.
        let aim=try #require(first.intents.compactMap { if case .aim(let p)=$0 { return p }; return nil }.first)
        expectTrue(ActionGuard(profiles:c.profiles).permits(.fire,observation:o,now:0,aim:aim))
        o.timestamp=0.1;expectFalse(step(c,o).intents.contains(.fire))
        o.timestamp=0.3;expectTrue(step(c,o).intents.contains(.fire)) // A bolt-action waits a second.
    }

    // MARK: Prompt text
    @Test func testPromptParserIdentifiesItemsAndRejectsEverythingElse() throws {
        let catalog=ItemCatalog.standard
        let gun=try #require(HUDText.prompt(lines:["M4","Rare AR","E"],confidence:1,catalog:catalog,key:"E"))
        expectEqual(gun.kind,.weapon);expectEqual(gun.itemID,"ar:rare:m4");expectEqual(gun.name,"M4")
        let pump=try #require(HUDText.prompt(lines:["Pump Shotgun","Legendary Shotgun"],confidence:1,catalog:catalog))
        expectEqual(pump.itemID,"shotgun:legendary:pump_shotgun")
        let potion=try #require(HUDText.prompt(lines:["Hybrid Potion","x2","Healing","E"],confidence:1,catalog:catalog,key:"E"))
        expectEqual(potion.itemID,"hybrid_potion");expectEqual(potion.count,2)
        let appended=try #require(HUDText.prompt(lines:["Bandage x5","Healing"],confidence:1,catalog:catalog))
        expectEqual(appended.itemID,"bandage");expectEqual(appended.count,5)
        for lines in [["Hoverboard","Exit Vehicle","E"],["Door","Open"],["Chris_Hansen","Revive"],["Mystery","Rare Gizmo"],["Door","Interact"]] {
            let p=try #require(HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E"))
            expectEqual(p.kind,.other);expectFalse(p.isItem)
        }
        // Chests and crates open with the interact key; they are never items.
        for lines in [["Gold Chest","Interact","E"],["Ammo Chest","E","Interact"],["Air Drop Chest","Interact"],["Present Crate","Interact"],["Crate (Mystic)","Interact"],["Crate","00","E","Interact"]] {
            let p=try #require(HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E"))
            expectEqual(p.kind,.chest,"\(lines)");expectFalse(p.isItem)
        }
        expectFalse(HUDText.prompt(lines:["M4","Rare AR","F"],confidence:1,catalog:catalog,key:"E")?.isItem ?? true)
        expectTrue(HUDText.prompt(lines:["M4"],confidence:1,catalog:catalog)==nil)
        let unknownHeal=try #require(HUDText.prompt(lines:["Mystery Brew","Healing"],confidence:1,catalog:catalog))
        expectEqual(unknownHeal.kind,.healing);expectFalse(unknownHeal.isItem)
        // Recorded misreads: Cyrillic look-alikes and stray symbols.
        expectEqual(HUDText.prompt(lines:["MP5","E","Еріс SMG"],confidence:1,catalog:catalog,key:"E")?.itemID,"smg:epic:mp5")
        expectEqual(HUDText.prompt(lines:["MP5","Epіc SMG"],confidence:1,catalog:catalog)?.itemID,"smg:epic:mp5")
        expectEqual(HUDText.prompt(lines:["SCAR","Uncommon AR •"],confidence:1,catalog:catalog)?.itemID,"ar:uncommon:scar")
        expectEqual(HUDText.prompt(lines:["Pump Shotgun","&Common Shotgun"],confidence:1,catalog:catalog)?.itemID,"shotgun:common:pump_shotgun")
        expectEqual(HUDText.prompt(lines:["Small Shield","x2","Potion"],confidence:1,catalog:catalog)?.itemID,"small_shield")
        expectEqual(HUDText.prompt(lines:["Big Shield","Potion"],confidence:1,catalog:catalog)?.itemID,"large_shield")
        expectEqual(HUDText.prompt(lines:["Frag Grenade","Common Grenade"],confidence:1,catalog:catalog)?.kind,.throwable)
        for lines in [["Hoverboard","Exir Vehicle"],["Door","•Close"],["Crate (Mystic)","Interact"],["x15","Small","Ammo"],["Katana","Mythic Melee"],["Bow","Legendary Unique"]] {
            expectFalse(HUDText.prompt(lines:lines,confidence:1,catalog:catalog)?.isItem ?? false)
        }
    }
    // MARK: Potions
    func potionPrompt(_ lines:[String])->InteractionPrompt? { HUDText.prompt(lines:lines,confidence:1,catalog:.standard) }
    /// Catalog guns in slots 2 to 4 (close, medium, long) and the given items in slots 5 and 6, with the rifle in hand.
    func potionCarrier(_ five:InventorySlot,_ six:InventorySlot)->(Coordinator,Observation) {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.selectedSlot=3
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"smg:rare:mp5",ammo:30,reserveAmmo:90),.init(3,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90),
                     .init(4,itemID:"sniper:rare:bolt_mk2",ammo:5,reserveAmmo:10),five,six]
        return (c,o)
    }
    @Test func testLowOnHealthMeansHealthOrHealthAndShieldUnderTheThreshold() {
        var o=observation()
        for (hp,shield,low) in [(49.0,100.0,true),(60,30,true),(60,40,false),(100,0,false),(50,50,false)] {
            o.health=hp;o.shield=shield;expectEqual(Policy.lowOnHealth(o),low,"\(hp)/\(shield)")
        }
        o.health=10;o.hudConfidence=0.5;expectFalse(Policy.lowOnHealth(o)) // Only a clear reading counts.
        expectEqual(ItemCatalog.standard.heal(id:"large_shield")?.maxStack,2);expectEqual(ItemCatalog.standard.heal(id:"large_shield")?.groundStack,1)
        expectEqual(ItemCatalog.standard.heal(id:"hybrid_potion")?.maxStack,4);expectEqual(ItemCatalog.standard.heal(id:"small_shield")?.groundStack,2)
        expectEqual(ItemCatalog.standard.heal(id:"large_shield")?.useDuration,5)
    }
    @Test func testLowOnHealthAPotionTakesASlotKeptForAGun() {
        // One free slot, kept for the missing close-range gun, offered `after` seconds into the match.
        func offer(health:Double,after:Double)->Decision {
            let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
            var o=observation();o.selectedSlot=3;o.health=health
            o.inventory=[.init(1,itemID:"fists"),.init(2,count:0),.init(3,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90),
                         .init(4,itemID:"sniper:rare:bolt_mk2",ammo:5,reserveAmmo:10),.init(5,itemID:"large_shield"),.init(6,itemID:"small_shield",count:2)]
            _=step(c,o);o.timestamp=after;o.prompt=potionPrompt(["Med Kit","Healing"])
            return step(c,o)
        }
        // Early in the match potions are stocked up…
        var d=offer(health:100,after:1);expectEqual(d.reason,"Pick up Med Kit: stocking up on heals early")
        // …later the slot waits for a gun, unless you are low on health.
        d=offer(health:100,after:200);expectFalse(d.intents.contains(.pickup("Med Kit")))
        expectEqual(d.reason,"Not picking up Med Kit: keeping free slots for missing guns")
        d=offer(health:30,after:200);expectTrue(d.intents.contains(.pickup("Med Kit")));expectEqual(d.reason,"Pick up Med Kit: low on health")
    }
    @Test func testLowOnHealthDrinksBeforeOtherLoot() {
        func run(health:Double,shield:Double)->Decision {
            let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
            var o=observation();o.selectedSlot=2;o.health=health;o.shield=shield
            o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"smg:rare:mp5",ammo:30,reserveAmmo:90),.init(3,itemID:"hybrid_potion",count:2),
                         .init(4,count:0),.init(5,count:0),.init(6,count:0)]
            _=step(c,o);o.timestamp=2.1;o.prompt=gunPrompt("M4","Rare AR") // A wanted gun on the panel, in a quiet moment.
            return step(c,o)
        }
        let low=run(health:30,shield:20);expectTrue(low.intents.contains(.selectSlot(3)));expectFalse(low.intents.contains(.pickup("M4")))
        // Any time below full health or shield, a heal worth drinking goes first…
        let below=run(health:90,shield:60);expectTrue(below.intents.contains(.selectSlot(3)));expectFalse(below.intents.contains(.pickup("M4")))
        let full=run(health:100,shield:100);expectTrue(full.intents.contains(.pickup("M4"))) // …at full, loot.
    }
    @Test func testPotionStacksFillToTheirSizeAndNoFurther() {
        var (c,o)=potionCarrier(.init(5,count:0),.init(6,itemID:"small_shield",count:4))
        func offer(_ t:Double,_ lines:[String])->Decision { o.timestamp=t;o.prompt=potionPrompt(lines);return step(c,o) }
        expectTrue(offer(0,["Big Shield","Potion"]).intents.contains(.pickup("Big Shield")))
        o.timestamp=0.1;o.prompt=nil;o.inventory[4] = .init(5,itemID:"large_shield");expectEqual(step(c,o).reason,"Pickup confirmed")
        // The inventory is full now, but the big shield's stack has room for one more.
        var d=offer(0.9,["Big Shield","Potion"]);expectTrue(d.intents.contains(.pickup("Big Shield")));expectEqual(d.reason,"Pick up Big Shield: 1 of 2 held")
        o.timestamp=1.0;o.prompt=nil;_=step(c,o)
        d=offer(1.8,["Big Shield","Potion"]);expectFalse(d.intents.contains(.pickup("Big Shield")))
        expectEqual(d.reason,"Not picking up Big Shield: its stack is full; inventory full")
        // Four small shields read off the slot are a full stack too.
        d=offer(2.6,["Small Shield","x2","Potion"]);expectEqual(d.reason,"Not picking up Small Shield: its stack is full; inventory full")
    }
    @Test func testAStackOfUnknownSizeIsNotAddedToInAFullInventory() {
        // One small shield as far as the slot shows: the digits were not read, so the stack may be full. The game would swap
        // the gun in hand for it if it does not fit.
        var (c,o)=potionCarrier(.init(5,itemID:"large_shield"),.init(6,itemID:"small_shield",count:1))
        o.prompt=potionPrompt(["Small Shield","x2","Potion"])
        var d=step(c,o);expectFalse(d.intents.contains(.pickup("Small Shield")))
        expectEqual(d.reason,"Not picking up Small Shield: its stack may be full, and the inventory is full")
        (c,o)=potionCarrier(.init(5,count:0),.init(6,itemID:"small_shield",count:1));o.prompt=potionPrompt(["Small Shield","x2","Potion"])
        d=step(c,o);expectTrue(d.intents.contains(.pickup("Small Shield"))) // With a free slot it lands there at worst.
    }
    @Test func testTierCGunsAreNotWorthASlot() {
        let catalog=ItemCatalog.standard
        expectEqual(catalog.model(id:"ump")?.tier,"S");expectEqual(catalog.model(id:"ak")?.tier,"A");expectEqual(catalog.model(id:"famas")?.tier,"B")
        expectEqual(catalog.model(id:"glock")?.tier,"C");expectEqual(catalog.profile("shotgun:epic:ksg_shotgun")?.rankingTier,"C")
        // Not picked up, even for a range with no gun yet.
        for (name,subtitle) in [("Glock","Uncommon Pistol"),("P2000","Uncommon Pistol"),("KSG Shotgun","Epic Shotgun"),("Hunting Rifle","Epic Sniper")] {
            let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
            var o=observation();o.selectedSlot=3
            o.inventory=[.init(1,itemID:"fists"),.init(2,count:0),.init(3,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
            o.prompt=gunPrompt(name,subtitle);let d=step(c,o)
            expectFalse(d.intents.contains(.pickup(name)));expectTrue(d.reason.hasSuffix("a tier C gun is not worth picking up"))
        }
        // One you carry is the first to go when a potion needs a slot.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.selectedSlot=3
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"shotgun:epic:ksg_shotgun",ammo:6,reserveAmmo:12),.init(3,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90),
                     .init(4,itemID:"sniper:rare:bolt_mk2",ammo:5,reserveAmmo:10),.init(5,itemID:"hybrid_potion",count:2),.init(6,itemID:"small_shield",count:2)]
        o.prompt=potionPrompt(["Big Shield","Potion"])
        expectEqual(step(c,o).reason,"Select slot 2 to swap for Big Shield")
    }
    @Test func testTheRarerGunOfAClassIsUsed() {
        // An Epic M4 in hand and a Legendary AK carried: the AK, though the M4 ranks higher.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=armed(0.2);o.selectedSlot=2
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:epic:m4",ammo:30,reserveAmmo:90),.init(3,itemID:"ar:legendary:ak",ammo:30,reserveAmmo:90),
                     .init(4,count:0),.init(5,count:0),.init(6,count:0)]
        expectEqual(step(c,o).reason,"Select Legendary AK for medium range")
        // With the AK's magazine empty in a fight, the loaded M4 beats reloading.
        let d=Coordinator(catalog:.standard);d.features.idleWeapon=false
        var p=armed(0.2);p.selectedSlot=3
        p.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:epic:m4",ammo:nil,reserveAmmo:nil),.init(3,itemID:"ar:legendary:ak",ammo:0,reserveAmmo:90),
                     .init(4,count:0),.init(5,count:0),.init(6,count:0)]
        expectEqual(step(d,p).reason,"Select Epic M4 for medium range")
    }
    @Test func testAPotionOnTheGroundIsDrunkFromABorrowedSlotAndTheGunTakenBack() {
        // Half shield, a full inventory, a Big Shield on the ground: drink it, keep the potions you carry, take the gun back.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.shield=50;o.selectedSlot=3
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"smg:rare:mp5",ammo:30,reserveAmmo:90),.init(3,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90),
                     .init(4,itemID:"sniper:rare:bolt_mk2",ammo:5,reserveAmmo:10),.init(5,itemID:"hybrid_potion",count:2),.init(6,itemID:"small_shield",count:2)]
        _=step(c,o);o.timestamp=2.1;o.prompt=potionPrompt(["Big Shield","Potion"])
        expectEqual(step(c,o).reason,"Select slot 4 to swap for Big Shield") // The gun you would miss least.
        o.timestamp=2.15;o.selectedSlot=4;expectTrue(step(c,o).intents.contains(.pickup("Big Shield")))
        o.timestamp=2.2;o.inventory[3] = .init(4,itemID:"large_shield");o.prompt=gunPrompt("Bolt Mk. II Sniper","Rare Sniper");_=step(c,o)
        // The borrowed Big Shield is drunk, not the hybrids you carry…
        o.timestamp=2.45;expectEqual(step(c,o).reason,"Start healing with Big Shield")
        o.timestamp=7.6;o.shield=100;o.inventory[3] = .init(4,count:0);expectEqual(step(c,o).reason,"Healing confirmed")
        // …and the sniper is picked up again.
        o.timestamp=7.7;let back=step(c,o)
        expectTrue(back.intents.contains(.pickup("Bolt Mk. II Sniper")));expectEqual(back.reason,"Pick up Bolt Mk. II Sniper again after healing")
    }
    @Test func testAStackSeenArrivingIsOneGroundStackUntilYouPressAKey() {
        // Slot 5 is seen empty, then holds a big shield you picked up: one ground stack, so room for one more.
        var (c,o)=potionCarrier(.init(5,count:0),.init(6,itemID:"small_shield",count:4))
        _=step(c,o);o.timestamp=0.2;o.inventory[4] = .init(5,itemID:"large_shield");_=step(c,o)
        o.timestamp=0.4;o.prompt=potionPrompt(["Big Shield","Potion"])
        expectEqual(step(c,o).reason,"Pick up Big Shield: 1 of 2 held")
        // A key you press yourself may have stacked another: the count is a guess again.
        (c,o)=potionCarrier(.init(5,count:0),.init(6,itemID:"small_shield",count:4))
        _=step(c,o);o.timestamp=0.2;o.inventory[4] = .init(5,itemID:"large_shield");_=step(c,o)
        o.timestamp=0.3;o.manualOverride=true;_=step(c,o)
        o.timestamp=0.4;o.manualOverride=false;o.prompt=potionPrompt(["Big Shield","Potion"])
        expectEqual(step(c,o).reason,"Not picking up Big Shield: its stack may be full, and the inventory is full")
    }
    @Test func testABadgeReadOnceCountsForThePickup() {
        // A dead player's four hybrids: "x4" is read in one frame, not in the next, where the press happens.
        var (c,o)=potionCarrier(.init(5,count:0),.init(6,itemID:"small_shield",count:4));o.selectedSlot=3
        o.prompt=potionPrompt(["Hybrid Potion","x4","Healing"]);o.prompt?.stable=false;_=step(c,o)
        o.timestamp=0.1;o.prompt=potionPrompt(["Hybrid Potion","Healing"]);expectTrue(step(c,o).intents.contains(.pickup("Hybrid Potion")))
        o.timestamp=0.2;o.prompt=nil;o.inventory[4] = .init(5,itemID:"hybrid_potion");_=step(c,o)
        o.timestamp=1.0;o.prompt=potionPrompt(["Hybrid Potion","Healing"])
        expectEqual(step(c,o).reason,"Not picking up Hybrid Potion: its stack is full; inventory full")
    }
    @Test func testLowOnHealthSwapsAPotionThatCannotHelpForOneThatDoes() {
        // Shield full and health low: the shields cannot help, the med kit can. The cheapest to keep makes room.
        var (c,o)=potionCarrier(.init(5,itemID:"large_shield"),.init(6,itemID:"small_shield",count:2));o.health=30
        _=step(c,o);o.timestamp=2.1;o.prompt=potionPrompt(["Med Kit","Healing"])
        let d=step(c,o);expectTrue(d.intents.contains(.selectSlot(6)));expectEqual(d.reason,"Select slot 6 to swap for Med Kit")
    }
    @Test func testASecondHybridWaitsForTheFirstOnesEffect() {
        // Very low: the first hybrid's 25/25 on their way would not be enough, but a second one now would be wasted.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.health=10;o.shield=0;o.selectedSlot=3
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare",ammo:20,reserveAmmo:50),.init(3,itemID:"hybrid_potion",count:4),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.useConsumable))
        o.timestamp=4.3;o.health=11;expectEqual(step(c,o).reason,"Healing confirmed")
        for t in [4.6,8.0,13.0] { o.timestamp=t;o.health=10+2.5*(t-4.2);o.shield=2.5*(t-4.2);#expect(!step(c,o).intents.contains(.useConsumable),"at \(t) s") }
        o.timestamp=14.5;o.health=35;o.shield=25;expectTrue(step(c,o).intents.contains(.useConsumable)) // Its effect is over.
    }

    // MARK: Heal planning
    func standardHeals()->[String:ItemProfile] { Dictionary(uniqueKeysWithValues:ItemCatalog.standard.profiles.filter { $0.kind == .healing }.map { ($0.id,$0) }) }
    func plan(_ health:Double,_ shield:Double,_ stock:[String:Int])->[String] {
        let heals=standardHeals()
        return HealPlanner.plan(health:health,shield:shield,stacks:stock.map { HealPlanner.Stack(heals[$0.key]!,count:$0.value) }).map(\.id)
    }
    @Test func testHealPlanUsesSmallShieldsBeforeHybridsWhenBothAreLow() {
        // The user's rule: with health and shield both below 50, small shields first (they only fill to 50), then hybrids.
        expectEqual(plan(40,30,["small_shield":2,"hybrid_potion":2,"large_shield":1]),["small_shield","hybrid_potion","hybrid_potion"])
        expectEqual(plan(40,40,["small_shield":1,"hybrid_potion":1]),["small_shield","hybrid_potion"])
        expectEqual(plan(45,45,["small_shield":1,"hybrid_potion":1]),["small_shield","hybrid_potion"])
        expectEqual(plan(30,10,["small_shield":3,"hybrid_potion":2,"large_shield":1]),["small_shield","small_shield","hybrid_potion","hybrid_potion"])
    }
    @Test func testHealPlanFillsShieldsInOrderAndSavesBigShields() {
        expectEqual(plan(100,0,["small_shield":4,"large_shield":2]),["small_shield","small_shield","large_shield"])
        expectEqual(plan(100,40,["small_shield":1,"large_shield":1]),["small_shield","large_shield"])
        expectEqual(plan(100,95,["large_shield":1]),[]) // Five points are not worth a big shield.
        expectEqual(plan(100,80,["large_shield":1]),["large_shield"])
        expectEqual(plan(100,60,["large_shield":1,"hybrid_potion":1]),["large_shield"]) // A hybrid would waste its health.
        expectEqual(plan(95,100,["hybrid_potion":1]),[])
        expectEqual(plan(100,100,["small_shield":3,"large_shield":3,"hybrid_potion":3,"medkit":1,"bandage":5]),[])
        expectEqual(plan(60,49,["small_shield":1,"hybrid_potion":1]),["hybrid_potion"]) // One point of shield is not a dose.
    }
    @Test func testHealPlanAddsUpStacksAndIgnoresInvalidStates() {
        let heals=standardHeals()
        let split=HealPlanner.plan(health:100,shield:0,stacks:[.init(heals["small_shield"]!,count:1),.init(heals["small_shield"]!,count:1),.init(heals["large_shield"]!,count:1)]).map(\.id)
        expectEqual(split,["small_shield","small_shield","large_shield"])
        expectEqual(HealPlanner.plan(health:.nan,shield:0,stacks:[.init(heals["small_shield"]!,count:1)]).count,0)
        expectEqual(HealPlanner.plan(health:20,shield:0,stacks:[.init(heals["small_shield"]!,count:0)]).count,0)
    }
    @Test func testCoordinatorFollowsTheHealPlan() {
        let c=Coordinator(catalog:.standard);var o=observation();o.health=40;o.shield=30;o.selectedSlot=2
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare",ammo:20,reserveAmmo:50),.init(3,itemID:"hybrid_potion",count:2),
                     .init(4,itemID:"small_shield",count:2),.init(5,count:0),.init(6,count:0)]
        assertRelease(step(c,o));o.timestamp=2.1
        let first=step(c,o)
        expectTrue(first.intents.contains(.selectSlot(4)));expectEqual(c.healingItem,"Small Shield")
        // Shield reaches 50 after one dose: the plan moves on to the hybrids.
        o.timestamp=2.5;o.selectedSlot=4;o.shield=50;o.inventory[3].count=1
        expectTrue(step(c,o).intents.contains(.selectSlot(3)));expectEqual(c.healingItem,"Hybrid Potion")
    }

    // MARK: Heal execution
    func healing(_ c:Coordinator,shield:Double=0)->Observation {
        var o=observation();o.shield=shield;o.inventory[2] = .init(3,itemID:"shield",count:2);o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.useConsumable));return o
    }
    @Test func testStormTicksDoNotInterruptAHealButGunfireDoes() {
        let c=engine();var o=healing(c)
        o.timestamp=2.2;o.health=98;expectTrue(step(c,o).intents.contains(.useConsumable)) // Storm ticks: a couple of points
        o.timestamp=2.6;o.health=96;expectTrue(step(c,o).intents.contains(.useConsumable)) // now and then.
        o.timestamp=2.62;o.health=89;expectEqual(step(c,o).reason,"Interrupt healing") // Seven points at once: a hit.
        let e=engine();var q=healing(e,shield:40)
        q.timestamp=2.2;q.shield=30;expectFalse(step(e,q).intents.contains(.useConsumable)) // Shield taken: gunfire.
    }
    @Test func testHealSelectionLoopPausesHealing() {
        // A potion that never reads as selected would be selected again and again; after a few tries heals pause.
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=2
        _=step(c,o);var t=2.1,selections=0,paused=false
        while t<12 {
            o.timestamp=t;let d=step(c,o)
            if d.intents.contains(.selectSlot(3)) { selections+=1 }
            if d.reason.hasPrefix("Healing keeps failing") { paused=true;break }
            t+=0.1
        }
        expectTrue(paused);expectTrue(selections<=Coordinator.healAttemptLimit)
        o.timestamp=t+1;expectFalse(step(c,o).intents.contains(.selectSlot(3)))
    }
    @Test func testHybridGainsStillArrivingAreNotHealedAgain() {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.health=70;o.shield=100;o.selectedSlot=3
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare",ammo:20,reserveAmmo:50),.init(3,itemID:"hybrid_potion",count:3),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.useConsumable))
        o.timestamp=4.3;o.health=71;expectEqual(step(c,o).reason,"Healing confirmed")
        // About 24 more points are on their way over 10 s; another hybrid now would mostly be wasted.
        o.timestamp=4.6;o.health=72;expectFalse(step(c,o).intents.contains(.useConsumable))
    }

    @Test func testTwoPlannedHybridsAreTwoDrinks() {
        // A small game: holding the potion 2 s drinks one, and each drink adds 25/25 over the next 10 s. The second drink
        // waits for the first one's 10 s to end; the 20 s here leave room for both.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.health=50;o.shield=50;o.selectedSlot=3
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare",ammo:20,reserveAmmo:50),.init(3,itemID:"hybrid_potion",count:4),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        var drinks:[Double]=[],holdingSince:Double?=nil,starts=0
        for k in 0...400 {
            let t=Double(k)*0.05;o.timestamp=t
            let regen=drinks.reduce(0.0) { $0+25*min(1,max(0,(t-$1)/10)) }
            o.health=min(100,50+regen);o.shield=min(100,50+regen)
            let d=step(c,o)
            if d.reason.hasPrefix("Start healing") { starts+=1 }
            if d.intents.contains(.useConsumable) || (d.intents.isEmpty && holdingSince != nil) { if holdingSince==nil { holdingSince=t } } else { holdingSince=nil }
            if let since=holdingSince, t-since>=2 { drinks.append(t);holdingSince=nil;o.inventory[2].count-=1 }
        }
        expectEqual(drinks.count,2);expectEqual(starts,2)
    }
    @Test func testAWobblingBarDoesNotStartAndStopAHeal() {
        // A small shield restores exactly the minimum at shield 45; the bar reads 44.8 or 45.2.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.shield=44.8;o.selectedSlot=2
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare",ammo:20,reserveAmmo:50),.init(3,count:0),.init(4,itemID:"small_shield",count:3),.init(5,count:0),.init(6,count:0)]
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.selectSlot(4)))
        o.timestamp=2.4;o.selectedSlot=4;o.shield=45.2;_=step(c,o)
        o.timestamp=2.5;o.shield=44.8;let d=step(c,o)
        expectFalse(d.intents.contains(.selectSlot(2)))
        o.timestamp=2.6;o.shield=45.2;expectTrue(step(c,o).intents.contains(.useConsumable) || c.healingItem=="Small Shield")
    }
    @Test func testInterruptedHealsAreNotFailures() {
        let c=engine();var o=observation();o.health=30;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        var t=0.0
        for _ in 0..<3 {
            o.players=[];t+=2.1;o.timestamp=t;_=step(c,o)            // Safe gap: the heal starts.
            o.timestamp=t+0.1;o.players=[enemy()];_=step(c,o)         // An opponent steps out: interrupted.
            t+=0.2
        }
        o.players=[];t+=2.1;o.timestamp=t;_=step(c,o) // The rifle combat asked for never showed up: that selection times out.
        o.timestamp=t+1.1
        let d=step(c,o);expectFalse(d.reason.hasPrefix("Healing keeps failing"));expectTrue(d.intents.contains(.useConsumable))
    }
    @Test func testAGunMislabeledAsAPotionIsNeverClicked() {
        let c=engine();var o=observation();o.health=30;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3;o.gunInHand=true
        _=step(c,o);o.timestamp=2.1;let first=step(c,o)
        expectFalse(first.intents.contains(.useConsumable));expectEqual(first.reason,"Stand still: checking that Med Kit is in hand")
        o.timestamp=2.5;expectEqual(step(c,o).reason,"That slot holds a gun, not Med Kit; not healing")
        expectFalse(ActionGuard(profiles:c.profiles).permits(.useConsumable,observation:o,now:2.5,aim:nil))
        // An unknown readout waits; once it reads empty, or the panel names the potion, the drink starts.
        let d=engine();var p=observation();p.health=30;p.inventory[2] = .init(3,itemID:"med");p.selectedSlot=3;p.gunInHand=nil
        _=step(d,p);p.timestamp=2.1;expectFalse(step(d,p).intents.contains(.useConsumable))
        p.timestamp=2.3;p.heldConsumable="med";expectTrue(step(d,p).intents.contains(.useConsumable))
    }
    @Test func testAnUnreadableHUDEndsAWaitingPlan() {
        let c=engine();var o=observation();o.health=30;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=2
        _=step(c,o);o.timestamp=2.1;expectTrue(step(c,o).intents.contains(.selectSlot(3)))
        o.timestamp=2.4;o.selectedSlot=3;o.hudConfidence=0;expectEqual(step(c,o).reason,"Waiting for a clear health reading")
        o.timestamp=4.0;_=step(c,o);expectEqual(c.healingItem,nil)
    }

    // MARK: Idle weapon
    func quietCarrier()->(Coordinator,Observation) {
        let c=Coordinator(catalog:.standard);var o=observation();o.selectedSlot=2
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"shotgun:rare",ammo:5,reserveAmmo:20),.init(3,itemID:"ar:epic"),.init(4,itemID:"sniper:rare"),.init(5,count:0),.init(6,count:0)]
        return (c,o)
    }
    @Test func testQuietSpellsCarryTheSniper() {
        let(c,base)=quietCarrier();var o=base
        assertRelease(step(c,o));o.timestamp=2.0;assertRelease(step(c,o)) // Not quiet for 2.5 s yet.
        o.timestamp=2.6;let d=step(c,o)
        expectTrue(d.intents.contains(.selectSlot(4)));expectEqual(d.reason,"Carry Rare SNIPER while nothing is happening")
        o.timestamp=3.0;o.selectedSlot=4;_=step(c,o);o.timestamp=3.5;assertRelease(step(c,o))
        // A player in view resets the quiet spell; a fight keeps the gun for 8 s afterwards.
        let(e,start)=quietCarrier();var p=start;p.players=[.init(id:9,position:.init(0.7,0.5),affiliation:.enemy,motion:.init(groundVelocity:Point()))]
        _=step(e,p);p.players=[];p.timestamp=2.6;expectFalse(step(e,p).intents.contains(.selectSlot(4)))
        p.timestamp=8.1;expectTrue(step(e,p).intents.contains(.selectSlot(4)))
    }
    @Test func testIdleWeaponLeavesYourOwnChoiceAlone() {
        let(c,base)=quietCarrier();var o=base
        _=step(c,o);o.timestamp=2.6;expectTrue(step(c,o).intents.contains(.selectSlot(4)))
        o.timestamp=3.0;o.selectedSlot=4;_=step(c,o)
        o.timestamp=5.0;o.selectedSlot=3;assertRelease(step(c,o)) // You picked the AR yourself.
        o.timestamp=20;assertRelease(step(c,o))
        o.timestamp=35.1;expectTrue(step(c,o).intents.contains(.selectSlot(4)))
        c.features.idleWeapon=false;let(d,other)=quietCarrier();d.features.idleWeapon=false;var q=other;q.timestamp=3
        _=step(d,q);q.timestamp=6;assertRelease(step(d,q))
    }

    @Test func testAnEmptySniperIsNotCarriedBackAndForth() {
        let(c,base)=quietCarrier();var o=base
        _=step(c,o);o.timestamp=2.6;expectTrue(step(c,o).intents.contains(.selectSlot(4)))
        o.timestamp=3.0;o.selectedSlot=4;o.inventory[3].ammo=0;o.inventory[3].reserveAmmo=0;_=step(c,o) // Read 0 / 0.
        o.timestamp=8.0;o.selectedSlot=3;o.inventory[3].ammo=nil;o.inventory[3].reserveAmmo=nil;_=step(c,o)
        for t in stride(from:8.5,through:30,by:0.5) { o.timestamp=t;expectFalse(step(c,o).intents.contains(.selectSlot(4))) }
    }

    // MARK: Ranges with the sniper's zoom
    func sniperFight(at x:Double,selected:Int)->Observation {
        var o=observation();o.aspect=1;o.selectedSlot=selected
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:epic",ammo:30,reserveAmmo:90),.init(3,itemID:"sniper:epic",ammo:5,reserveAmmo:20),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        o.players=[.init(id:1,position:.init(x,0.5),affiliation:.enemy,motion:.init(groundVelocity:Point()))]
        return o
    }
    @Test func testSniperZoomDoesNotMakeOpponentsLookCloser() {
        // 0.30 view widths with the sniper's 1.2× zoom-out is 0.36 in the default view: beyond the 0.33 sniper cutoff.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        let held=step(c,sniperFight(at:0.8,selected:3))
        expectFalse(held.intents.contains(.selectSlot(2)));expectEqual(c.currentBand,.long)
        let d=Coordinator(catalog:.standard);d.features.idleWeapon=false
        expectTrue(step(d,sniperFight(at:0.86,selected:2)).intents.contains(.selectSlot(3))) // The AR shows true distances.
    }
    @Test func testBrieflyMissedTargetKeepsItsBand() {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=sniperFight(at:0.8,selected:3);_=step(c,o);expectEqual(c.currentBand,.long)
        o.timestamp=0.1;o.players=[];_=step(c,o);expectEqual(c.currentBand,.long)
        o.timestamp=1.5;_=step(c,o);expectEqual(c.currentBand,nil)
    }

    // MARK: Air drops
    @Test func testAirDropHoldsInteractUntilItOpens() {
        let c=engine();var o=observation();o.prompt=chestPrompt("Air Drop Chest")
        expectEqual(step(c,o).intents,[.releaseAll,.holdOpen("Air Drop Chest")])
        o.timestamp=1;expectEqual(step(c,o).intents,[.holdOpen("Air Drop Chest")])
        o.timestamp=1.2;o.prompt=nil;expectEqual(step(c,o).intents,[.holdOpen("Air Drop Chest")]) // A frame without the panel.
        o.timestamp=1.4;o.prompt=chestPrompt("Air Drop Chest");_=step(c,o)
        // Opened: its loot is taken in the same frame (the driver lets go of the held key before tapping it again).
        o.timestamp=5.2;o.prompt=itemPrompt("AWP","sniper",.weapon);expectEqual(step(c,o).intents,[.releaseAll,.pickup("AWP")])
        let guardrail=ActionGuard(profiles:c.profiles);var p=observation()
        expectTrue(guardrail.permits(.holdOpen("Air Drop Chest"),observation:p,now:0,aim:nil)) // No panel this frame.
        p.prompt=InteractionPrompt(name:"Door",subtitle:"Open",kind:.other)
        expectFalse(guardrail.permits(.holdOpen("Air Drop Chest"),observation:p,now:0,aim:nil))
        p.prompt=chestPrompt("Air Drop Chest");p.players=[enemy()]
        expectFalse(guardrail.permits(.holdOpen("Air Drop Chest"),observation:p,now:0,aim:nil))
    }

    @Test func testUnreadPanelOrChestsOffEndAnAirDropHold() {
        let c=engine();var o=observation();o.prompt=chestPrompt("Air Drop Chest");o.promptVisible=true
        _=step(c,o);o.timestamp=1;expectEqual(step(c,o).intents,[.holdOpen("Air Drop Chest")])
        // The drop opens and the panel changes to loot that is not read yet: interact must let go at once.
        o.timestamp=1.1;o.prompt=nil;expectEqual(step(c,o).intents,[.releaseAll])
        let guardrail=ActionGuard(profiles:c.profiles)
        expectFalse(guardrail.permits(.holdOpen("Air Drop Chest"),observation:o,now:1.1,aim:nil))
        o.promptVisible=false;expectTrue(guardrail.permits(.holdOpen("Air Drop Chest"),observation:o,now:1.1,aim:nil))
        let d=engine();var p=observation();p.prompt=chestPrompt("Air Drop Chest");p.promptVisible=true
        _=step(d,p);d.features.chests=false;p.timestamp=0.5;expectEqual(step(d,p).intents,[.releaseAll])
    }

    // MARK: Crosshair circle
    /// The aim direction from you in pixel proportions, the way the game turns your character.
    func pixelAngle(_ p:Point,from player:Point,aspect:Double)->Double { atan2(p.y-player.y,(p.x-player.x)*aspect) }
    @Test func testCursorKeepsTheAngleButStaysInsideTheCircle() {
        let center=Point(0.5,0.5)
        for aspect in [1.0,16.0/9.0,3840.0/1736.0] {
            for k in 0..<72 {
                let a=Double(k)*Double.pi/36
                // Opponents at the screen's edge in every direction, where the old cursor pressed on the window border.
                let far=Point(min(0.999,max(0.001,0.5+cos(a)*0.6/aspect)),min(0.999,max(0.001,0.5+sin(a)*0.6)))
                let c=Targeting.cursor(toward:far,from:center,aspect:aspect,radius:0.35)
                #expect(abs(c.angle-pixelAngle(far,from:center,aspect:aspect)) < 1e-9)
                #expect(abs(pixelAngle(c.point,from:center,aspect:aspect)-c.angle) < 1e-9)
                let reach=(((c.point.x-0.5)*aspect)*((c.point.x-0.5)*aspect)+(c.point.y-0.5)*(c.point.y-0.5)).squareRoot()
                #expect(reach <= 0.35+1e-12)
                #expect((0.04-1e-12...0.96+1e-12).contains(c.point.x) && (0.04-1e-12...0.96+1e-12).contains(c.point.y))
            }
        }
        // Inside the circle the crosshair goes right on the point.
        let near=Point(0.55,0.6), inside=Targeting.cursor(toward:near,from:center,aspect:16.0/9.0,radius:0.35)
        #expect(inside.point==near)
        // Angles are measured in pixels: on a 2:1 view, 0.1 of the width right and 0.2 of the height down is 45°.
        #expect(abs(Targeting.cursor(toward:Point(0.6,0.7),from:center,aspect:2,radius:0.35).angle-Double.pi/4) < 1e-12)
    }
    @Test func testCursorRespectsTheEdgesWhenYouAreNotCentered() {
        // Close to the top edge, straight up can only go to the margin; the direction stays straight up.
        let c=Targeting.cursor(toward:Point(0.5,0.0),from:Point(0.5,0.2),aspect:16.0/9.0,radius:0.35)
        #expect(abs(c.point.x-0.5) < 1e-12 && abs(c.point.y-0.04) < 1e-12 && abs(c.angle+Double.pi/2) < 1e-12)
        // A diagonal toward the top-left corner is cut where it meets the margin, keeping its angle.
        let player=Point(0.2,0.2), corner=Point(0,0)
        let d=Targeting.cursor(toward:corner,from:player,aspect:16.0/9.0,radius:0.35)
        #expect(abs(pixelAngle(d.point,from:player,aspect:16.0/9.0)-pixelAngle(corner,from:player,aspect:16.0/9.0)) < 1e-9)
        #expect(min(d.point.x,d.point.y) >= 0.04-1e-12 && abs(min(d.point.x,d.point.y)-0.04) < 1e-12)
    }
    @Test func testCursorDegenerateInputsStayOnYou() {
        let you=Point(0.5,0.5)
        #expect(Targeting.cursor(toward:you,from:you,aspect:2,radius:0.35).point==you)
        #expect(Targeting.cursor(toward:Point(.nan,0.2),from:you,aspect:2,radius:0.35).point==you)
        #expect(Targeting.cursor(toward:Point(0.9,0.5),from:you,aspect:0,radius:0.35).point==you)
        var settings=CombatSettings();settings.aimRadius=0.6;#expect(!settings.isValid)
        settings.aimRadius=0.3;#expect(settings.isValid)
        // Saved settings from before the circle load with the default.
        let old=try! JSONDecoder().decode(CombatSettings.self,from:Data(#"{"closeCutoff":0.13,"longCutoff":0.33}"#.utf8))
        #expect(old.aimRadius==0.35 && old.isValid)
    }

    // MARK: Prompt misreads and the consumable in hand
    @Test func testPromptParserToleratesRecordedMisreads() throws {
        let catalog=ItemCatalog.standard
        func read(_ lines:[String])->InteractionPrompt? { HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E") }
        let badge=try #require(read(["XZ","Small Shield","E","Potion"]));expectEqual(badge.itemID,"small_shield");expectEqual(badge.count,2)
        expectEqual(read(["XI5","Bandage","Healing"])?.count,15)
        expectEqual(read(["SCAR","Eo","Rare AR"])?.itemID,"ar:rare:scar")
        expectEqual(read(["MP5","E","Uncommon SMC"])?.itemID,"smg:uncommon:mp5")
        expectEqual(read(["SCAR","E","Rare ARO"])?.itemID,"ar:rare:scar")
        expectEqual(read(["AWP","egendary Sniper"])?.itemID,"sniper:legendary:awp")
        expectEqual(read(["Glock","Rafe Pistol"])?.itemID,"pistol:rare:glock")
        expectEqual(read(["Gold Chest","E","Interast"])?.kind,.chest)
        expectEqual(read(["Hoverboard","5","Exit Vehicle"])?.kind,.other)
        expectEqual(read(["Door","E","Oper"])?.kind,.other)
        expectFalse(read(["Gun","Epic XMG"])?.isItem ?? false) // SMG and LMG are equally close: no guess.
        expectFalse(read(["Mystery","Rare Pi"])?.isItem ?? false)
    }
    @Test func testConsumableInHandIsReadFromItsHint() {
        let catalog=ItemCatalog.standard
        expectEqual(HUDText.heldConsumable(lines:["Left Click to Consume","Charge shield by 25% up to 50%"],catalog:catalog),"small_shield")
        expectEqual(HUDText.heldConsumable(lines:["Left Click to Consume","Charge shields by 50% up to full"],catalog:catalog),"large_shield")
        expectEqual(HUDText.heldConsumable(lines:["Left Click to Consume","Heals and shields 25% over time"],catalog:catalog),"hybrid_potion")
        expectEqual(HUDText.heldConsumable(lines:["Left Click to Consume","Heals to full health"],catalog:catalog),"medkit")
        expectEqual(HUDText.heldConsumable(lines:["Left Clck to Consume","Charge shield by 25% up to 5O%"],catalog:catalog),"small_shield")
        expectTrue(HUDText.heldConsumable(lines:["Charge shield by 25% up to 50%"],catalog:catalog)==nil)
        expectTrue(HUDText.heldConsumable(lines:["Left Click to Consume","Charge"],catalog:catalog)==nil)
        expectTrue(HUDText.heldConsumable(lines:["M4","Rare AR"],catalog:catalog)==nil)
    }

    @Test func testSlotCountsAndNameSimilarity() {
        expectEqual(HUDText.count("1,132"),1132);expectEqual(HUDText.count("33"),33);expectTrue(HUDText.count("3a")==nil)
        expectTrue(HUDText.nameSimilarity("Chris_Hansen","Chris Hansen")>0.99)
        expectTrue(HUDText.nameSimilarity("Chris_Hanscn","Chris_Hansen")>=AffiliationTracker.teammateSimilarity)
        expectTrue(HUDText.nameSimilarity("speedrun","Chris_Hansen")<AffiliationTracker.strangerSimilarity)
    }

    // MARK: Team modes
    @Test func testTeammatesNeedARosterNameAndEnemiesRepeatedMisses() {
        var t=AffiliationTracker();let roster=["Chris_Hansen","SLK_2fps"]
        t.record(track:1,read:.text("Chris_Hansen",0.9),roster:roster,time:0)
        expectEqual(t.affiliation(track:1,time:0.1).0,.teammate)
        t.record(track:2,read:.nothing(colored:false),roster:roster,time:0)
        expectEqual(t.affiliation(track:2,time:0.1).0,.unknown) // One miss is not enough.
        t.record(track:2,read:.nothing(colored:false),roster:roster,time:0.5)
        expectEqual(t.affiliation(track:2,time:0.6).0,.enemy)
        t.record(track:2,read:.text("SLK_2fps",0.8),roster:roster,time:1) // A later legible tag corrects a misread teammate.
        expectEqual(t.affiliation(track:2,time:1.1).0,.teammate)
        t.record(track:3,read:.nothing(colored:true),roster:roster,time:0);t.record(track:3,read:.nothing(colored:true),roster:roster,time:0.5)
        expectEqual(t.affiliation(track:3,time:0.6).0,.unknown) // Colored tag pixels: possibly a teammate.
        t.record(track:4,read:.nothing(colored:false),roster:[],time:0);t.record(track:4,read:.nothing(colored:false),roster:[],time:0.5)
        expectEqual(t.affiliation(track:4,time:0.6).0,.unknown) // No roster read yet: never an enemy.
        t.record(track:5,read:.text("speedrun",0.9),roster:roster,time:0);t.record(track:5,read:.text("speedrun",0.9),roster:roster,time:0.5)
        expectEqual(t.affiliation(track:5,time:0.6).0,.enemy)
    }
    @Test func testUnconfirmedOrUnknownPlayersAreNeverEngaged() {
        var o=observation();var p=enemy();p.confirmed=false;o.players=[p]
        expectFalse(step(engine(),o).intents.contains(.fire))
        p.confirmed=true;p.affiliation = .unknown;o.players=[p];o.teamMode=true
        expectFalse(step(engine(),o).intents.contains(.fire))
    }
    @Test func testTrackerConfirmsAfterRepeatedDetectionsOverTime() {
        // Three detections spread over at least 0.12 s: at 20 Hz the fourth; at 55 Hz not before 0.12 s.
        var tracker=PlayerMotionTracker();var states:[Bool]=[]
        for k in 0..<4 { states.append(tracker.update(time:Double(k)*0.05,aspect:1,sceneryShift:Point(),players:[Point(0.7,0.5)])[0].confirmed) }
        expectEqual(states,[false,false,false,true])
        var live=PlayerMotionTracker();var first:Double?
        for k in 0..<12 {
            let t=Double(k)/55
            if live.update(time:t,aspect:1,sceneryShift:Point(),players:[Point(0.7,0.5)])[0].confirmed && first==nil { first=t }
        }
        expectTrue((first ?? 0) >= PlayerMotionTracker.confirmAge)
    }

    /// Ground motion after tracking an opponent at 20 Hz while you stand still.
    func tracked(frames:Int,velocity:Point=Point(0.18,0))->MotionEstimate {
        var tracker=PlayerMotionTracker(); var estimate:MotionEstimate?
        for k in 0..<frames {
            let t=Double(k)*0.05
            estimate=tracker.update(time:t,aspect:1,sceneryShift:Point(),players:[Point(0.7,0.5)+velocity*t]).first?.motion
        }
        return estimate!
    }
    @Test func testTrackerSeparatesYourMovementFromOpponentMotion() {
        let aspect=3840.0/1736.0, dt=0.05, yours=Point(0.15,0), runner=Point(0,0.1)
        var tracker=PlayerMotionTracker(); var you=Point(), standing=Point(0.2,0.05), running=Point(-0.2,-0.1)
        var tracks:[PlayerMotionTracker.Track]=[]
        func screen(_ ground:Point)->Point { let r=ground-you; return Point(0.5+r.x,0.5+r.y*aspect) }
        for k in 0...20 {
            if k>0 { you=you+yours*dt; running=running+runner*dt }
            let shift:Point?=k==0 ? nil : Point(-yours.x*dt,-yours.y*dt*aspect) // Scenery slides opposite to you.
            tracks=tracker.update(time:Double(k)*dt,aspect:aspect,sceneryShift:shift,players:[screen(standing),screen(running)])
        }
        #expect(tracks[0].id != tracks[1].id)
        #expect(tracks[0].motion.groundVelocity.length<0.01)
        #expect((tracks[0].velocity-Point(-0.15,0)).length<0.01) // It drifts across the screen as you pass.
        #expect((tracks[1].motion.groundVelocity-Point(0,0.1*aspect)).length<0.01)
        #expect(tracks[1].motion.velocityVariance<PlayerMotionTracker.initialVelocityVariance/4)
    }
    @Test func testTrackerFollowsReversalAndKeepsIdentityThroughBriefMisses() {
        var tracker=PlayerMotionTracker(); var x=0.3; var ids=Set<Int>()
        func step(_ t:Double,_ players:[Point])->[PlayerMotionTracker.Track] { tracker.update(time:t,aspect:1,sceneryShift:Point(),players:players) }
        for k in 0...23 {
            let t=Double(k)*0.05
            if k>0 { x+=(t<=1.0001 ? 0.18 : -0.18)*0.05 }
            let track=step(t,[Point(x,0.5)])[0]; ids.insert(track.id)
            if k==20 { #expect(abs(track.motion.groundVelocity.x-0.18)<0.01) }
            if k==23 { #expect(track.motion.groundVelocity.x < -0.09) } // Within 0.15 s of reversing at full speed.
        }
        #expect(ids.count==1)
        _=step(1.20,[]); _=step(1.25,[]) // Two missed detections.
        #expect(step(1.30,[Point(x-0.18*0.15,0.5)])[0].id==ids.first)
        for k in 1...7 { _=step(1.30+Double(k)*0.05,[]) } // Lost for longer than the coast period.
        #expect(step(1.70,[Point(x-0.18*0.55,0.5)])[0].id != ids.first)
    }
    @Test func testConfirmedPlayerIsHeldBrieflyAtItsPredictedPosition() {
        var tracker=PlayerMotionTracker()
        func step(_ t:Double,_ players:[Point])->[PlayerMotionTracker.Track] { tracker.update(time:t,aspect:1,sceneryShift:Point(),players:players) }
        _=step(0,[Point(0.3,0.5)])
        _=step(0.05,[]); #expect(tracker.held.isEmpty) // One sighting is not yet a player.
        for k in 1...5 { _=step(0.05*Double(k),[Point(0.3+0.01*Double(k),0.5)]) }
        _=step(0.3,[])
        #expect(tracker.held.count==1)
        #expect(tracker.held.first.map { $0.position.x>0.35 && $0.track.confirmed } == true) // Still moving right.
        _=step(0.45,[]); #expect(tracker.held.count==1)
        _=step(0.55,[]); #expect(tracker.held.isEmpty) // Missed for longer than the hold.
    }
    @Test func testBulletsLeadGroundMotionNotYourOwn() throws {
        let weapon=profiles()[0]; var o=observation(); o.aspect=3840.0/1736.0
        // You strafe past an opponent standing still: it slides across the screen but needs no flight lead.
        var target=enemy(); target.velocity=Point(-0.15,0); target.motion = .init(groundVelocity:Point())
        let standing=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0.1,settings:exact))
        #expect(standing.distance(to:target.position+target.velocity*0.1)<1e-12)
        // An opponent running alongside you looks still on screen but does need a lead.
        target.velocity=Point(); target.motion = .init(groundVelocity:Point(0.15,0))
        let alongside=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0.1,settings:exact))
        let flight=alongside.distance(to:o.player,aspect:o.aspect)/weapon.projectileSpeed
        #expect(alongside.distance(to:target.position+Point(0.15,0)*flight,aspect:o.aspect)<1e-10)
        #expect(alongside.x>target.position.x)
    }
    @Test func testFiringWaitsUntilOpponentMotionSettles() throws {
        let c=engine(); var o=observation(); var target=enemy(Point(0.18,0))
        target.motion=tracked(frames:1) // Just appeared: course unknown.
        o.players=[target]
        let waiting=step(c,o)
        expectEqual(waiting.reason,"Opponent motion still uncertain")
        expectEqual(waiting.intents.first,.releaseAll); expectFalse(waiting.intents.contains(.fire))
        let aim=try #require(waiting.intents.compactMap { if case .aim(let p)=$0 { return p };return nil }.first)
        expectFalse(ActionGuard(profiles:c.profiles).permits(.fire,observation:o,now:0,aim:aim))
        target.motion=tracked(frames:10); o.players=[target] // Half a second of 20 Hz tracking.
        let settled=Coordinator(profiles:profiles(),settings:exact);settled.features.idleWeapon=false
        let firing=step(settled,o)
        expectTrue(firing.intents.contains(.fire))
        let lead=try #require(firing.intents.compactMap { if case .aim(let p)=$0 { return p };return nil }.first)
        expectTrue(ActionGuard(profiles:c.profiles,settings:exact).permits(.fire,observation:o,now:0,aim:lead))
        let intercept=try #require(Targeting.intercept(target,in:o,weapon:profiles()[0],now:0,settings:exact))
        expectTrue(intercept.hitProbability>=Policy.minHitProbability && intercept.hitProbability<1)
    }
    @Test func testLeadCoversInputLatencyAndFadesOverLongFlights() throws {
        var o=observation(); o.aspect=1
        var target=enemy(); target.velocity=Point(0,0.18); target.motion = .init(groundVelocity:Point(0,0.18))
        var weapon=profiles()[0]; weapon.projectileSpeed=1.1; weapon.maxRange=0.8
        var s=exact
        let none=try #require(Targeting.intercept(target,in:o,weapon:weapon,now:0,settings:s)).point
        s.leadLatency=0.06
        let delayed=try #require(Targeting.intercept(target,in:o,weapon:weapon,now:0,settings:s)).point
        #expect(abs((delayed.y-none.y)-0.18*0.06) < 0.002) // The click reaches the game 60 ms later.
        s.leadPersistence=1
        let faded=try #require(Targeting.intercept(target,in:o,weapon:weapon,now:0,settings:s)).point
        #expect(faded.y < delayed.y && faded.y > target.position.y+0.18*0.06) // Less lead, never none.
        // A sniper zooms the view out 1.2×: the same screen distance is farther, and a range limit applies sooner.
        var sniper=weapon; sniper.maxRange=0.215; target.position=Point(0.68,0.5)
        #expect(Targeting.intercept(target,in:o,weapon:sniper,now:0,settings:exact) != nil)
        sniper.zoom=1.2
        #expect(Targeting.intercept(target,in:o,weapon:sniper,now:0,settings:exact) == nil)
    }
    @Test func testOpponentWithoutMotionEstimateIsNotEngaged() {
        var o=observation(); var target=enemy(); target.motion=nil; o.players=[target]
        let decision=step(engine(),o)
        expectEqual(decision.reason,"Opponent motion unknown"); expectFalse(decision.intents.contains(.fire))
        expectFalse(ActionGuard(profiles:engine().profiles).permits(.fire,observation:o,now:0,aim:target.position))
    }
    // MARK: Reverse Impulse combos
    /// A Solo fight with catalog items: a Rare M4 in slot 2, in hand, the given items in slots 3 to 6 (three of each
    /// grenade), and one opponent standing still to your right, 0.2 view widths away unless said otherwise.
    func comboFight(_ items:[String?],enemyAt x:Double=0.7)->(Coordinator,Observation) {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation()
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90)]+items.enumerated().map { i,id in
            guard let id else { return InventorySlot(i+3,count:0) }
            return ItemCatalog.parseWeaponID(id) != nil ? InventorySlot(i+3,itemID:id,ammo:5,reserveAmmo:10) : InventorySlot(i+3,itemID:id,count:3)
        }
        var foe=enemy();foe.position=Point(x,0.5);o.players=[foe]
        return (c,o)
    }
    func thrown(_ decision:Decision)->Point? { decision.intents.compactMap { if case .throwAt(let p)=$0 { return p };return nil }.first }
    func aimed(_ decision:Decision)->Point? { decision.intents.compactMap { if case .aim(let p)=$0 { return p };return nil }.first }
    @Test func testRevNadeThrowsTheFragFirstAndThePullJustBeforeItGoesOff() throws {
        var (c,o)=comboFight(["frag_grenade","reverse_impulse_grenade",nil,nil])
        let guardrail=ActionGuard(profiles:c.profiles)
        // A Frag goes off 2 s after the throw and the pull 0.5 s: the Frag goes first.
        let start=step(c,o)
        expectEqual(start.intents,[.releaseAll,.selectSlot(3)])
        expectEqual(start.reason,"Rev-nade: Frag Grenade, then Reverse Impulse on the same spot: take Frag Grenade")
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;let first=step(c,o)
        let spot=try #require(thrown(first))
        // Where the opponent stands, well inside the grenade circle and clear of you.
        #expect(abs(spot.y-0.5)<1e-9 && abs(spot.x-0.7)<1e-9)
        expectTrue(guardrail.permits(.throwAt(spot),observation:o,now:0.25,aim:nil))
        expectEqual(c.liveGrenade?.name,"Frag Grenade")
        o.timestamp=0.3;expectEqual(step(c,o).intents,[]) // The click goes up where it was made.
        o.timestamp=0.4;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(4)])
        o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        o.timestamp=0.7;let waiting=step(c,o)
        expectEqual(waiting.intents,[.releaseAll]);expectEqual(waiting.reason,"Rev-nade: Reverse Impulse in 0.7 s")
        // The pull goes off 0.5 s after its throw and takes 0.3 s: thrown 1.15 s after the Frag, it brings the opponent to
        // the spot just before the Frag goes off.
        o.timestamp=1.38;expectEqual(step(c,o).intents,[.releaseAll])
        o.timestamp=1.41;let second=step(c,o)
        expectEqual(second.intents,[.releaseAll,.throwAt(spot)]);expectEqual(second.reason,"Rev-nade: Reverse Impulse on the spot")
        expectTrue(guardrail.permits(.throwAt(spot),observation:o,now:1.41,aim:nil))
        // Both are out: the fight goes on with the M4.
        o.timestamp=1.55;expectTrue(step(c,o).intents.contains(.selectSlot(2)))
    }
    @Test func testAQuickRGD5FollowsThePull() throws {
        var (c,o)=comboFight(["reverse_impulse_grenade","rgd5_grenade",nil,nil])
        expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(3)])
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;let spot=try #require(thrown(step(c,o)))
        o.timestamp=0.4;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(4)])
        o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        // An RGD-5 goes off 0.5 s after its throw: 0.35 s after the pull's throw, it goes off as the opponent lands.
        o.timestamp=0.66;let bomb=step(c,o)
        expectEqual(bomb.intents,[.releaseAll,.throwAt(spot)]);expectEqual(bomb.reason,"Rev-nade: RGD-5 Grenade on the spot")
        expectTrue(ActionGuard(profiles:c.profiles).permits(.throwAt(spot),observation:o,now:0.66,aim:nil))
        expectEqual(c.liveGrenade?.name,"RGD-5 Grenade")
    }
    @Test func testTheSpotMovesWithYouThroughEverySlotSwitchFrame() throws {
        var (c,o)=comboFight(["reverse_impulse_grenade","rgd5_grenade",nil,nil])
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;let spot=try #require(thrown(step(c,o)))
        o.timestamp=0.4;_=step(c,o) // Asks for slot 4.
        // You walk on while the RGD-5 comes to hand: every frame's scenery shift moves the spot, not only the last one's.
        for (time,selected) in [(0.45,3),(0.5,4),(0.55,4)] {
            o.timestamp=time;o.selectedSlot=selected;o.sceneryShift=Point(-0.005,0);o.players[0].position.x -= 0.005
            expectEqual(step(c,o).reason,"Waiting for selected slot")
        }
        o.timestamp=0.62;o.sceneryShift=Point(-0.005,0);o.players[0].position.x -= 0.005
        let bomb=try #require(thrown(step(c,o)))
        #expect(abs(bomb.x-(spot.x-0.02))<1e-9 && abs(bomb.y-spot.y)<1e-9)
    }
    @Test func testASniperShotIsTimedToArriveWithThePulledOpponent() throws {
        var (c,o)=comboFight(["reverse_impulse_grenade","sniper:rare:bolt_mk2",nil,nil])
        expectEqual(step(c,o).reason,"Combo: Reverse Impulse, then Rare Bolt Mk. II Sniper as the opponent lands: take Reverse Impulse")
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;let spot=try #require(thrown(step(c,o)))
        o.timestamp=0.4;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(4)])
        // The sniper zooms the view out 1.2×, which brings the spot and the opponent closer to you on screen.
        o.timestamp=0.45;o.selectedSlot=4;o.players[0].position=Point(0.5+0.2/1.2,0.5);_=step(c,o)
        o.timestamp=0.75;let early=step(c,o)
        expectEqual(early.intents.first,.releaseAll);expectFalse(early.intents.contains(.fireAtPull))
        #expect(aimed(early).map { abs($0.x-(0.5+(spot.x-0.5)/1.2))<1e-9 } == true)
        // The opponent lands 0.86 s after the throw; the bullet flies about 0.19 s. It is fired so as to arrive just after.
        o.timestamp=0.93;let shot=step(c,o)
        expectTrue(shot.intents.contains(.fireAtPull))
        let aim=try #require(aimed(shot))
        expectTrue(ActionGuard(profiles:c.profiles).permits(.fireAtPull,observation:o,now:0.93,aim:aim))
        // One shot, then ordinary fighting.
        o.timestamp=0.96;expectFalse(step(c,o).intents.contains(.fireAtPull))
    }
    @Test func testAnyGunFinishesAPullThatBringsAnOpponentOutFromCover() {
        // In the open, the M4 just fires: a pull would gain it nothing.
        var (c,o)=comboFight(["reverse_impulse_grenade",nil,nil,nil])
        expectTrue(step(c,o).intents.contains(.fire))
        // Behind a wall the M4 cannot shoot through, the pull brings the opponent out to your side of it.
        (c,o)=comboFight(["reverse_impulse_grenade",nil,nil,nil],enemyAt:0.75)
        o.obstacles=[.init(.wall,bounds:.init(0.715,0.4,0.02,0.2))]
        let start=step(c,o)
        expectEqual(start.intents,[.releaseAll,.selectSlot(3)])
        expectEqual(start.reason,"Combo: Reverse Impulse, then Rare M4 as the opponent lands: take Reverse Impulse")
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;#expect(thrown(step(c,o)).map { $0.x<0.707 } == true)
    }
    @Test func testAPullAtYourFeetBringsAnOpponentThroughADoorToYourShotgun() throws {
        var (c,o)=comboFight(["reverse_impulse_grenade","shotgun:rare:pump_shotgun",nil,nil],enemyAt:0.56)
        o.obstacles=[.init(.door,bounds:.init(0.53,0.45,0.012,0.1))]
        expectEqual(step(c,o).reason,"Combo: Reverse Impulse at your feet, then Rare Pump Shotgun: take Reverse Impulse")
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;let feet=try #require(thrown(step(c,o)))
        #expect(abs(feet.distance(to:o.player,aspect:o.aspect)-Combos.feetOffset)<1e-9 && feet.x>0.5)
        expectTrue(ActionGuard(profiles:c.profiles).permits(.throwAt(feet),observation:o,now:0.25,aim:nil))
        o.timestamp=0.4;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(4)])
        o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        o.timestamp=0.7;expectFalse(step(c,o).intents.contains(.fireAtPull)) // Still on the way.
        o.timestamp=1.09;let blast=step(c,o)
        expectTrue(blast.intents.contains(.fireAtPull))
        expectTrue(ActionGuard(profiles:c.profiles).permits(.fireAtPull,observation:o,now:1.09,aim:feet))
    }
    @Test func testABlastNeverLandsNearYou() {
        // An opponent 0.05 view widths away: a Frag that caught them would catch you too, so the M4 fights instead.
        var (c,o)=comboFight(["frag_grenade","reverse_impulse_grenade",nil,nil],enemyAt:0.55)
        expectTrue(step(c,o).intents.contains(.fire))
        // The input guard refuses such a throw by itself: a Frag's blast reaches 0.08, plus a margin of 0.04.
        o.selectedSlot=3
        let guardrail=ActionGuard(profiles:c.profiles)
        expectFalse(guardrail.permits(.throwAt(Point(0.55,0.5)),observation:o,now:0,aim:nil))
        expectFalse(guardrail.permits(.throwAt(Point(0.6,0.5)),observation:o,now:0,aim:nil))
        expectTrue(guardrail.permits(.throwAt(Point(0.65,0.5)),observation:o,now:0,aim:nil))
    }
    @Test func testAPullNeverDragsYouIntoYourOwnFrag() {
        var (c,o)=comboFight(["frag_grenade","reverse_impulse_grenade",nil,nil])
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;_=step(c,o) // The Frag is out.
        o.timestamp=0.4;_=step(c,o);o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        // You walk toward the spot: the scenery, the Frag and the opponent slide toward you on screen.
        o.timestamp=1.41;o.sceneryShift=Point(-0.08,0);o.players[0].position.x -= 0.08
        let decision=step(c,o)
        expectEqual(decision.reason,"Rev-nade off: Reverse Impulse would pull you into your own Frag Grenade")
        expectEqual(thrown(decision),nil)
    }
    @Test func testARevNadeGivesUpOnAnOpponentWhoRunsOff() {
        var (c,o)=comboFight(["frag_grenade","reverse_impulse_grenade",nil,nil])
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;_=step(c,o) // The Frag is out.
        o.timestamp=0.4;_=step(c,o);o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        // Running at full speed away from the Frag: no pull will catch them, so the guns take over.
        o.timestamp=0.7;o.players[0].position.x=0.62;o.players[0].velocity=Point(-0.18,0);o.players[0].motion = .init(groundVelocity:Point(-0.18,0))
        expectEqual(step(c,o).reason,"Rev-nade off: the opponent got away from the Frag Grenade")
        o.timestamp=0.75;expectTrue(step(c,o).intents.contains(.selectSlot(2)))
    }
    @Test func testGrenadesAreNeverThrownAtSomethingTheyWouldBounceOff() {
        // A tree on the line would stop a grenade or send it back at you. Bullets still go for the opponent.
        var (c,o)=comboFight(["frag_grenade","reverse_impulse_grenade","sniper:rare:bolt_mk2",nil])
        o.obstacles=[.init(.tree,bounds:.init(0.6,0.45,0.03,0.1))]
        expectTrue(step(c,o).intents.contains(.fire))
        o.selectedSlot=3
        expectFalse(ActionGuard(profiles:c.profiles).permits(.throwAt(Point(0.69,0.5)),observation:o,now:0,aim:nil))
    }
    @Test func testExplodingRoundsNeverGoOffNearYou() {
        let catalog=ItemCatalog.standard
        let scar=catalog.profile("ar:mythic:assault_scar")!, rpg=catalog.profile("launcher:rare:rpg")!, m4=catalog.profile("ar:rare:m4")!
        var o=observation()
        // The target itself, or anything solid on the way within the explosion's reach of you, is too close.
        expectTrue(Policy.explosiveSafe(o,weapon:rpg,toward:Point(0.7,0.5),zoom:1))
        expectFalse(Policy.explosiveSafe(o,weapon:rpg,toward:Point(0.58,0.5),zoom:1))
        o.obstacles=[.init(.wall,bounds:.init(0.54,0.45,0.02,0.1))]
        expectFalse(Policy.explosiveSafe(o,weapon:rpg,toward:Point(0.7,0.5),zoom:1)) // The rocket would hit the wall beside you.
        o.obstacles=[.init(.tree,bounds:.init(0.54,0.45,0.02,0.1))]
        expectFalse(Policy.explosiveSafe(o,weapon:scar,toward:Point(0.7,0.5),zoom:1))
        expectTrue(Policy.explosiveSafe(o,weapon:m4,toward:Point(0.53,0.5),zoom:1)) // Ordinary bullets do not explode.
        // In a fight, the Assault SCAR is not fired at an opponent right next to you; an SMG is taken instead.
        let c=Coordinator(catalog:catalog);c.features.idleWeapon=false
        var fight=observation()
        fight.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:mythic:assault_scar",ammo:30,reserveAmmo:90),.init(3,count:0),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        var foe=enemy();foe.position=Point(0.53,0.5);fight.players=[foe]
        let held=step(c,fight)
        expectFalse(held.intents.contains(.fire));expectEqual(held.reason,"Not firing Mythic Assault SCAR: its explosion would hit you too")
        expectFalse(ActionGuard(profiles:c.profiles).permits(.fire,observation:fight,now:0,aim:foe.position))
        fight.inventory[2] = .init(3,itemID:"smg:rare:mp5",ammo:30,reserveAmmo:90);fight.timestamp=0.1
        expectTrue(step(c,fight).intents.contains(.selectSlot(3)))
    }
    @Test func testTheInputGuardRefusesUnsafeOrPointlessThrows() {
        let (c,base)=comboFight(["frag_grenade","reverse_impulse_grenade","throwable","impulse_grenade"],enemyAt:0.6)
        let guardrail=ActionGuard(profiles:c.profiles)
        var o=base;o.selectedSlot=4 // The Reverse Impulse in hand.
        expectTrue(guardrail.permits(.throwAt(Point(0.52,0.5)),observation:o,now:0,aim:nil)) // At your feet: you stay put.
        expectFalse(guardrail.permits(.throwAt(Point(0.56,0.5)),observation:o,now:0,aim:nil)) // It would drag you along.
        expectTrue(guardrail.permits(.throwAt(Point(0.65,0.5)),observation:o,now:0,aim:nil))
        expectTrue(guardrail.permits(.throwAt(Point(0.72,0.5)),observation:o,now:0,aim:nil)) // Past the crosshair circle, within the grenade circle.
        o.players[0].position.x=0.82;expectFalse(guardrail.permits(.throwAt(Point(0.85,0.5)),observation:o,now:0,aim:nil)) // Beyond it.
        o=base;o.selectedSlot=4
        expectFalse(guardrail.permits(.throwAt(Point(0.5,0.5-0.15*o.aspect)),observation:o,now:0,aim:nil)) // Nobody there.
        o.gunInHand=true;expectFalse(guardrail.permits(.throwAt(Point(0.65,0.5)),observation:o,now:0,aim:nil)) // A gun would fire.
        o=base;o.selectedSlot=4;o.teamMode=true;o.players.append(.init(id:2,position:.init(0.66,0.52),affiliation:.teammate))
        expectFalse(guardrail.permits(.throwAt(Point(0.65,0.5)),observation:o,now:0,aim:nil)) // It would catch your teammate.
        // A throwable of unknown name and an Impulse are never thrown.
        for slot in [5,6] { o=base;o.selectedSlot=slot;expectFalse(guardrail.permits(.throwAt(Point(0.65,0.5)),observation:o,now:0,aim:nil)) }
        // Nor anything through a wall, which would send it back at you.
        o=base;o.selectedSlot=3;o.obstacles=[.init(.wall,bounds:.init(0.6,0.4,0.01,0.2))]
        expectFalse(guardrail.permits(.throwAt(Point(0.65,0.5)),observation:o,now:0,aim:nil))
    }
    @Test func testGrenadeAndUniqueWeaponPromptsNameTheItem() {
        let catalog=ItemCatalog.standard
        func id(_ lines:[String])->String? { HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E")?.itemID }
        // As recorded: the stack badge, the name, the key and the subtitle.
        expectEqual(id(["X3","Reverse Impulse","E","Common Grenade"]),"reverse_impulse_grenade")
        expectEqual(id(["X3","Impulse Grenade","E","Common Grenade"]),"impulse_grenade")
        expectEqual(id(["Frag Grenade","E","Common Grenade"]),"frag_grenade")
        expectEqual(id(["x5","RGD-5 Grenade","E","Common Grenade"]),"rgd5_grenade")
        expectEqual(id(["RGD-S Grenade","Common Grenade"]),"rgd5_grenade") // A look-alike character.
        expectEqual(id(["X3","Sticky Bomb","E","Epic Grenade"]),"sticky_bomb")
        expectEqual(id(["Mystery Grenade","Common Grenade"]),ItemCatalog.throwableID)
        // Unique items are named, not classed.
        expectEqual(id(["Gift Launcher","E","Legendary Unique"]),"launcher:legendary:gift_launcher")
        expectEqual(id(["Crossbow","E","Mythic Unique"]),"special:mythic:crossbow")
        expectEqual(id(["Grossbow","E","Mythid Unique"]),"special:mythic:crossbow") // As misread in a recording.
        expectEqual(id(["X30","Shuriken","E","Legendary Unique"]),"shuriken")
        expectEqual(HUDText.prompt(lines:["Minigun","E","Legendary Unique"],confidence:1,catalog:catalog)?.kind,.other)
        let rev=catalog.profile("reverse_impulse_grenade")!, frag=catalog.profile("frag_grenade")!
        expectEqual(rev.effect,.pull);expectEqual(frag.effect,.blast);expectTrue(rev.isValid && frag.isValid)
        expectGreater(frag.fuse,rev.fuse+rev.pullDuration) // So the Frag goes first.
        expectEqual(catalog.profile("launcher:rare:rpg")!.radius,0.07)
        expectEqual(catalog.profile("ar:mythic:assault_scar")!.radius,0.035)
        expectTrue(catalog.profiles.allSatisfy(\.isValid))
    }
    @Test func testCombosWaitTheirTurn() {
        // Turned off, the M4 just fires.
        var (c,o)=comboFight(["reverse_impulse_grenade","rgd5_grenade",nil,nil])
        c.features.combos=false;expectTrue(step(c,o).intents.contains(.fire))
        // After a combo, the next one waits 3 s.
        (c,o)=comboFight(["reverse_impulse_grenade","rgd5_grenade",nil,nil])
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;_=step(c,o);o.timestamp=0.4;_=step(c,o);o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        o.timestamp=0.66;_=step(c,o) // The RGD-5 is out.
        o.timestamp=0.8;expectTrue(step(c,o).intents.contains(.selectSlot(2))) // Back to the M4.
        o.timestamp=0.85;o.selectedSlot=2;_=step(c,o)
        o.timestamp=1.1;expectTrue(step(c,o).intents.contains(.fire))
        o.timestamp=3.7;expectTrue(step(c,o).intents.contains(.fire))
        o.timestamp=3.85;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(3)])
    }
    @Test func testYourOwnSlotChoiceEndsACombo() {
        var (c,o)=comboFight(["frag_grenade","reverse_impulse_grenade",nil,nil])
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;_=step(c,o) // The Frag is out.
        o.timestamp=0.3;o.selectedSlot=2 // You press 2 yourself.
        expectEqual(step(c,o).reason,"Combo stopped: you changed slots")
    }
    @Test func testAnSMGFinishesAPullAtYourFeetToo() throws {
        // Your loadout's SMG instead of a shotgun: the opponent behind the door comes to it, and it keeps firing as they land.
        var (c,o)=comboFight(["reverse_impulse_grenade","smg:rare:ump",nil,nil],enemyAt:0.56)
        o.obstacles=[.init(.door,bounds:.init(0.53,0.45,0.012,0.1))]
        expectEqual(step(c,o).reason,"Combo: Reverse Impulse at your feet, then Rare UMP: take Reverse Impulse")
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;_=try #require(thrown(step(c,o)))
        o.timestamp=0.4;_=step(c,o);o.timestamp=0.45;o.selectedSlot=4;_=step(c,o)
        for t in [1.09,1.2,1.3] { o.timestamp=t;expectTrue(step(c,o).intents.contains(.fireAtPull)) }
        o.timestamp=1.6;expectFalse(step(c,o).intents.contains(.fireAtPull)) // The window is over.
    }
    @Test func testAComboSpotStaysOffTheHUD() throws {
        // A HUD element over the opponent: the spot lands short of it, near enough for the pull.
        var (c,o)=comboFight(["reverse_impulse_grenade","sniper:rare:bolt_mk2",nil,nil])
        o.hudAreas=[.init(0.65,0.3,0.1,0.4)]
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.25;let spot=try #require(thrown(step(c,o)))
        #expect(spot.x<0.65 && spot.x>0.6)
        expectTrue(ActionGuard(profiles:c.profiles).permits(.throwAt(spot),observation:o,now:0.25,aim:nil))
        expectFalse(ActionGuard(profiles:c.profiles).permits(.throwAt(Point(0.7,0.5)),observation:o,now:0.25,aim:nil))
    }
    // MARK: Safe clicks
    @Test func testClicksNeverLandNearTheEdgesOrOnTheHUD() {
        var o=observation()
        // As the HUD layout reports them: the buttons at the top left, the inventory at the bottom right, the item panel.
        o.hudAreas=[.init(0,0,0.13,0.08),.init(0.74,0.78,0.26,0.22),.init(0.43,0.64,0.14,0.1)]
        expectTrue(Policy.clickable(Point(0.6,0.4),in:o))
        expectFalse(Policy.clickable(Point(0.05,0.03),in:o)) // A button.
        expectFalse(Policy.clickable(Point(0.8,0.9),in:o))   // An inventory slot.
        expectFalse(Policy.clickable(Point(0.5,0.68),in:o))  // The item panel.
        expectFalse(Policy.clickable(Point(0.3,0.97),in:o))  // Near the bottom edge.
        expectFalse(Policy.clickable(Point(0.98,0.4),in:o))  // Near the right edge.
        // The crosshair keeps its direction but steps back off the panel.
        let down=Targeting.cursor(toward:Point(0.5,0.7),from:o.player,aspect:o.aspect,radius:0.35,avoiding:o.hudAreas)
        #expect(abs(down.point.x-0.5)<1e-9 && down.point.y<0.64 && down.point.y>0.55 && abs(down.angle-Double.pi/2)<1e-9)
        // Throws land within the grenade circle, 60% of the view's height by default, where a click is safe.
        var s=CombatSettings()
        expectTrue(Policy.throwClickable(Point(0.8,0.5),in:o,settings:s))
        expectFalse(Policy.throwClickable(Point(0.86,0.5),in:o,settings:s))
        s.throwRadius=1.25 // At its largest, anywhere but near the edges and on the HUD.
        expectTrue(Policy.throwClickable(Point(0.95,0.5),in:o,settings:s))
        expectFalse(Policy.throwClickable(Point(0.99,0.5),in:o,settings:s))
        expectFalse(Policy.throwClickable(Point(0.8,0.9),in:o,settings:s))
        s.throwRadius=1.3;expectFalse(s.isValid)
    }
    // MARK: Loadout
    /// A sniper, an M4 and an MP5 in slots 2 to 4, the given items in slots 5 and 6, the sniper in hand.
    func kitted(_ five:String?,_ six:String?)->(Coordinator,Observation) {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.selectedSlot=2
        let rest:[InventorySlot]=[five,six].enumerated().map { i,id in
            guard let id else { return InventorySlot(i+5,count:0) }
            return ItemCatalog.parseWeaponID(id) != nil ? InventorySlot(i+5,itemID:id,ammo:30,reserveAmmo:60) : InventorySlot(i+5,itemID:id)
        }
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"sniper:rare:bolt_mk2",ammo:5,reserveAmmo:10),.init(3,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90),
                     .init(4,itemID:"smg:rare:mp5",ammo:30,reserveAmmo:90)]+rest
        return (c,o)
    }
    func grenadePrompt(_ name:String,_ subtitle:String="Common Grenade")->InteractionPrompt? {
        HUDText.prompt(lines:["X3",name,"E",subtitle],confidence:1,catalog:.standard,key:"E")
    }
    @Test func testTheLoadoutWantsASniperAnARAndAnSMG() {
        // A Common Uzi takes the place of a Legendary Pump Shotgun, though the ranking puts the shotgun higher.
        var (c,o)=stocked("shotgun:legendary:pump_shotgun","ar:rare:m4","sniper:rare:bolt_mk2");o.prompt=gunPrompt("Uzi","Common SMG")
        expectEqual(step(c,o).reason,"Select slot 2 to swap for Uzi")
        // A shotgun never takes an SMG's place, however good.
        (c,o)=stocked("smg:common:uzi","ar:rare:m4","sniper:rare:bolt_mk2");o.prompt=gunPrompt("Pump Shotgun","Legendary Shotgun")
        expectEqual(step(c,o).reason,"Not picking up Legendary Pump Shotgun: not better than Common Uzi")
        // An AR takes a pistol's place, a sniper a DMR's.
        (c,o)=stocked("smg:rare:mp5","pistol:legendary:deagle","sniper:rare:bolt_mk2");o.prompt=gunPrompt("AK","Common AR")
        expectEqual(step(c,o).reason,"Select slot 3 to swap for AK")
        (c,o)=stocked("smg:rare:mp5","ar:rare:m4","dmr:legendary");o.prompt=gunPrompt("Bolt-Action Sniper","Uncommon Sniper")
        expectEqual(step(c,o).reason,"Select slot 4 to swap for Bolt-Action Sniper")
        // With no close-range gun yet, a shotgun is still welcome.
        (c,o)=kitted(nil,nil);o.inventory[3] = .init(4,count:0);o.prompt=gunPrompt("Pump Shotgun","Rare Shotgun")
        expectEqual(step(c,o).reason,"Pick up Rare Pump Shotgun for close range")
    }
    @Test func testTheLoadoutCarriesOneUtilityItem() {
        // A free slot takes a Reverse Impulse; the other stays for heals.
        var (c,o)=kitted(nil,nil);o.prompt=grenadePrompt("Reverse Impulse")
        var d=step(c,o);expectTrue(d.intents.contains(.pickup("Reverse Impulse")));expectEqual(d.reason,"Pick up Reverse Impulse for your utility slot")
        expectTrue(ActionGuard(profiles:c.profiles).permits(.pickup("Reverse Impulse"),observation:o,now:0,aim:nil))
        // One utility item: a Frag does not join a Reverse Impulse…
        (c,o)=kitted("reverse_impulse_grenade",nil);o.prompt=grenadePrompt("Frag Grenade")
        expectEqual(step(c,o).reason,"Not picking up Frag Grenade: your utility slot holds Reverse Impulse")
        // …but a Reverse Impulse replaces a Smoke Grenade.
        (c,o)=kitted("smoke_grenade","hybrid_potion");o.prompt=grenadePrompt("Reverse Impulse")
        expectEqual(step(c,o).reason,"Select slot 5 to swap for Reverse Impulse")
        // Two heals keep their slots: nothing is dropped for a grenade.
        (c,o)=kitted("hybrid_potion","small_shield");o.prompt=grenadePrompt("Reverse Impulse")
        expectEqual(step(c,o).reason,"Not picking up Reverse Impulse: inventory full")
        // More of the one carried joins its stack when it has room.
        (c,o)=kitted("reverse_impulse_grenade","hybrid_potion");o.inventory[4].count=3;o.prompt=grenadePrompt("Reverse Impulse")
        d=step(c,o);expectTrue(d.intents.contains(.pickup("Reverse Impulse")));expectEqual(d.reason,"Pick up Reverse Impulse: 3 of 9 held")
        // A Grappling Hook is utility too ("Legendary Unique" on its prompt).
        (c,o)=kitted(nil,"hybrid_potion");o.prompt=HUDText.prompt(lines:["X15","Grappling Hook","E","Legendary Unique"],confidence:1,catalog:.standard,key:"E")
        expectEqual(step(c,o).reason,"Pick up Grappling Hook for your utility slot")
        // A grenade it cannot name is never picked up.
        (c,o)=kitted(nil,nil);o.prompt=grenadePrompt("Mystery Grenade")
        expectFalse(step(c,o).intents.contains(.pickup("Mystery Grenade")))
        expectFalse(ActionGuard(profiles:c.profiles).permits(.pickup("Mystery Grenade"),observation:o,now:0,aim:nil))
    }
    @Test func testWhatTheLoadoutHasNoPlaceForMakesWayFirst() {
        // No SMG yet, and two utility items: the weaker one goes for the SMG.
        var (c,o)=kitted("frag_grenade","hybrid_potion");o.inventory[3] = .init(4,itemID:"reverse_impulse_grenade",count:3);o.prompt=gunPrompt("MP5","Rare SMG")
        expectEqual(step(c,o).reason,"Select slot 5 to swap for MP5")
        // One utility item and two heals: the heal that helps least goes; a utility item and a heal stay.
        (c,o)=kitted("small_shield","hybrid_potion");o.inventory[3] = .init(4,itemID:"reverse_impulse_grenade",count:3);o.shield=40;o.prompt=gunPrompt("MP5","Rare SMG")
        expectEqual(step(c,o).reason,"Select slot 5 to swap for MP5")
        // A potion takes the place of a second SMG.
        (c,o)=kitted("smg:common:uzi","reverse_impulse_grenade");o.prompt=potionPrompt(["Hybrid Potion","Healing"])
        expectEqual(step(c,o).reason,"Select slot 5 to swap for Hybrid Potion")
        // So does a grenade, when there is no utility item yet.
        (c,o)=kitted("smg:common:uzi","hybrid_potion");o.prompt=grenadePrompt("Reverse Impulse")
        expectEqual(step(c,o).reason,"Select slot 5 to swap for Reverse Impulse")
    }
    @Test func testToHealItLendsTheUtilitySlotAndTakesItsItemBack() {
        // Nothing held helps (the shield is full), so the Reverse Impulse makes room for the Med Kit, not a gun.
        var (c,o)=kitted("reverse_impulse_grenade","small_shield");o.inventory[4].count=3;o.health=60
        o.prompt=potionPrompt(["Med Kit","Healing"])
        _=step(c,o);o.timestamp=2.1
        expectEqual(step(c,o).reason,"Select slot 5 to swap for Med Kit")
        o.timestamp=2.15;o.selectedSlot=5;expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        // It is drunk while the Reverse Impulses lie on the ground…
        o.timestamp=2.2;o.inventory[4] = .init(5,itemID:"medkit");o.prompt=grenadePrompt("Reverse Impulse");_=step(c,o)
        o.timestamp=2.45;expectEqual(step(c,o).reason,"Start healing with Med Kit")
        o.timestamp=7.6;o.health=100;o.inventory[4] = .init(5,count:0);expectEqual(step(c,o).reason,"Healing confirmed")
        // …and then picked up again.
        o.timestamp=7.7;let back=step(c,o)
        expectTrue(back.intents.contains(.pickup("Reverse Impulse")))
        expectTrue(ActionGuard(profiles:c.profiles).permits(.pickup("Reverse Impulse"),observation:o,now:7.7,aim:nil))
    }
    @Test func testASpotOnTheGroundFollowsTheView() {
        var o=observation()
        var mark=GroundMark(Point(0.7,0.5),zoom:1,time:0)
        o.timestamp=0.1;o.sceneryShift=Point(-0.02,0.01);mark.follow(o,zoom:1)
        #expect(abs(mark.point.x-0.68)<1e-12 && abs(mark.point.y-0.51)<1e-12)
        // Without a measured shift, your last velocity carries it the other way.
        o.timestamp=0.2;o.sceneryShift=nil;o.ownVelocity=Point(0.1,0);mark.follow(o,zoom:1)
        #expect(abs(mark.point.x-0.67)<1e-12)
        // A sniper zooms the view out 1.2×: the spot comes closer to you on screen.
        o.timestamp=0.3;mark.follow(o,zoom:1.2)
        #expect(abs(mark.point.x-(0.5+0.17/1.2))<1e-12)
    }

    // MARK: Healing Grenades and the Healing Gun
    /// A Duo match with catalog items: a Rare M4 in slot 2, in hand, the given items in slots 3 to 6 (grenades in threes, the
    /// Healing Gun with 8 rounds, as its slot prints them; in hand its readout shows a bare "8", like a grenade's), and you
    /// on the given health with no shield. Nobody else in view unless a test adds them.
    func medic(_ items:[String?],health:Double=30)->(Coordinator,Observation) {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.mode = .duo;o.teamMode=true;o.health=health;o.shield=0
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:rare:m4",ammo:30,reserveAmmo:90)]+items.enumerated().map { i,id in
            guard let id else { return InventorySlot(i+3,count:0) }
            return ItemCatalog.parseWeaponID(id) != nil ? InventorySlot(i+3,itemID:id,totalAmmo:8) : InventorySlot(i+3,itemID:id,count:3)
        }
        return (c,o)
    }
    /// Your teammate, standing still, with the health their roster row shows.
    func teammate(_ position:Point,health:Double?,id:Int=7)->PlayerTrack {
        .init(id:id,position:position,affiliation:.teammate,motion:.init(groundVelocity:Point()),name:"Chris_Hansen",health:health,shield:0)
    }
    @Test func testAHealingGrenadeLandsAtYourFeetWhenYouAreLow() throws {
        var (c,o)=medic(["healing_grenade","medkit",nil,nil])
        let guardrail=ActionGuard(profiles:c.profiles)
        let select=step(c,o)
        expectEqual(select.intents,[.releaseAll,.selectSlot(3)]);expectEqual(select.reason,"Select Healing Grenade to heal you")
        o.timestamp=0.05;o.selectedSlot=3;expectEqual(step(c,o).reason,"Waiting for selected slot")
        o.timestamp=0.3;let throwing=step(c,o)
        let spot=try #require(thrown(throwing))
        expectEqual(throwing.reason,"Healing Grenade at your feet: health 30")
        #expect(spot.distance(to:o.player,aspect:o.aspect) <= Combos.feetOffset+1e-9)
        expectTrue(guardrail.permits(.throwAt(spot),observation:o,now:0.3,aim:nil))
        o.timestamp=0.35;expectEqual(step(c,o).intents,[]) // The click goes up where it was made.
        // The M4 comes back, and the app asks you to stay in the circle while it heals.
        o.timestamp=0.5;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(2)])
        expectEqual(c.healCircle?.inside,true)
        // Nothing more for your health while the circle heals you, about 20 a second once it opens: no second grenade, no
        // Med Kit.
        o.timestamp=0.55;o.selectedSlot=2;_=step(c,o)
        for (time,health) in [(1.0,30.0),(2.6,51.0)] { o.timestamp=time;o.health=health;assertRelease(step(c,o)) }
        // You walked out of it: the app says so, and what it did not heal is the Med Kit's.
        o.timestamp=2.7;o.sceneryShift=Point(-0.2,0)
        expectEqual(step(c,o).reason,"Select Med Kit to heal")
        expectEqual(c.healCircle?.inside,false)
        o.sceneryShift=nil;o.timestamp=6.2;_=step(c,o)
        #expect(c.healCircle == nil) // Closed.
    }
    @Test func testHealingGrenadesWaitForRealNeedAndNoFight() {
        // 60 health is not low: the grenade is kept.
        var (c,o)=medic(["healing_grenade",nil,nil,nil],health:60)
        expectFalse(step(c,o).intents.contains(.selectSlot(3)))
        // An opponent in the open gets the M4 first, and the guard refuses a heal throw while one is there.
        (c,o)=medic(["healing_grenade",nil,nil,nil]);o.players=[enemy()]
        expectTrue(step(c,o).intents.contains(.fire))
        o.selectedSlot=3
        expectFalse(ActionGuard(profiles:c.profiles).permits(.throwAt(Point(0.5,0.47)),observation:o,now:0,aim:nil))
        // Nor anywhere nobody of your team is.
        o.players=[];o.health=100
        expectFalse(ActionGuard(profiles:c.profiles).permits(.throwAt(Point(0.7,0.5)),observation:o,now:0,aim:nil))
        expectTrue(ActionGuard(profiles:c.profiles).permits(.throwAt(Point(0.55,0.5)),observation:o,now:0,aim:nil))
        // A grenade in hand is never clicked while the readout shows rounds.
        o.gunInHand=true
        expectFalse(ActionGuard(profiles:c.profiles).permits(.throwAt(Point(0.55,0.5)),observation:o,now:0,aim:nil))
    }
    @Test func testAHealingGrenadeLandsAtALowTeammatesFeet() throws {
        var (c,o)=medic(["healing_grenade",nil,nil,nil],health:100)
        o.players=[teammate(Point(0.62,0.55),health:30)]
        expectEqual(step(c,o).reason,"Select Healing Grenade to heal Chris_Hansen")
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.3;let throwing=step(c,o)
        let spot=try #require(thrown(throwing))
        expectEqual(throwing.reason,"Healing Grenade at Chris_Hansen's feet: health 30")
        #expect(spot.distance(to:Point(0.62,0.55),aspect:o.aspect) < 1e-9)
        expectTrue(ActionGuard(profiles:c.profiles).permits(.throwAt(spot),observation:o,now:0.3,aim:nil))
        #expect(c.healCircle == nil) // Thrown for them, not for you.
        // No second one while their circle heals them.
        o.timestamp=0.45;_=step(c,o);o.timestamp=0.6;o.selectedSlot=2
        expectFalse(step(c,o).intents.contains(.selectSlot(3)))
        // A teammate with health left, or out of throwing reach, gets none.
        for (position,health) in [(Point(0.62,0.55),80.0),(Point(0.95,0.5),30.0)] {
            (c,o)=medic(["healing_grenade",nil,nil,nil],health:100);o.players=[teammate(position,health:health)]
            expectFalse(step(c,o).intents.contains(.selectSlot(3)))
        }
        // Low beside you, when you are low too: halfway between, so the circle takes you both.
        (c,o)=medic(["healing_grenade",nil,nil,nil]);o.players=[teammate(Point(0.56,0.5),health:40)]
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o);o.timestamp=0.3
        let shared=try #require(thrown(step(c,o)))
        #expect(abs(shared.x-0.53)<1e-9 && abs(shared.y-0.5)<1e-9)
    }
    @Test func testTheHealingGunHealsALowTeammateUntilNearlyFull() {
        var (c,o)=medic(["special:epic:healing_gun",nil,nil,nil],health:100)
        var mate=teammate(Point(0.62,0.5),health:30);o.players=[mate]
        let guardrail=ActionGuard(profiles:c.profiles)
        expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(3)])
        o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        o.timestamp=0.4;let shot=step(c,o)
        expectEqual(shot.intents,[.aim(Point(0.62,0.5)),.fireHealing]);expectEqual(shot.reason,"Epic Healing Gun at Chris_Hansen: health 30")
        expectTrue(guardrail.permits(.fireHealing,observation:o,now:0.4,aim:Point(0.62,0.5)))
        // One round at a time.
        o.timestamp=0.5;expectEqual(step(c,o).intents,[.releaseAll,.aim(Point(0.62,0.5))])
        mate.health=42;o.players=[mate];o.timestamp=0.95;expectTrue(step(c,o).intents.contains(.fireHealing))
        // Within a round of full health it stops, and the M4 comes back.
        mate.health=90;o.players=[mate];o.timestamp=1.5;expectEqual(step(c,o).reason,"Healed Chris_Hansen with the Epic Healing Gun")
        o.timestamp=1.6;expectEqual(step(c,o).intents,[.releaseAll,.selectSlot(2)])
    }
    @Test func testHealingGunRoundsThatHealNobodyEndTheHeal() {
        var (c,o)=medic(["special:epic:healing_gun",nil,nil,nil],health:100)
        o.players=[teammate(Point(0.62,0.5),health:30)]
        _=step(c,o);o.timestamp=0.05;o.selectedSlot=3;_=step(c,o)
        var shots=0
        for k in 0..<10 { o.timestamp=0.4+0.3*Double(k);if step(c,o).intents.contains(.fireHealing) { shots += 1 } }
        // The teammate's health never rose: three rounds over 1.6 s, then it gives up and leaves them alone for a while.
        expectEqual(shots,3)
        o.timestamp=3.5;o.selectedSlot=2
        expectFalse(step(c,o).intents.contains(.selectSlot(3)))
    }
    @Test func testTheHealingGunNeverFiresPastAnyoneElseOrThroughCover() {
        var (c,o)=medic(["special:epic:healing_gun",nil,nil,nil],health:100)
        o.selectedSlot=3
        let mate=teammate(Point(0.7,0.5),health:30),guardrail=ActionGuard(profiles:c.profiles)
        expectTrue(guardrail.permits(.fireHealing,observation:o.with(players:[mate]),now:0,aim:mate.position))
        // Another player on the line would take the round, perhaps an opponent.
        o.players=[mate,.init(id:3,position:Point(0.6,0.5),affiliation:.unknown,confirmed:false)]
        expectFalse(guardrail.permits(.fireHealing,observation:o,now:0,aim:mate.position))
        expectFalse(step(c,o).intents.contains(.fireHealing))
        // Trees and rocks stop rounds too.
        o.players=[mate];o.obstacles=[.init(.tree,bounds:.init(0.6,0.45,0.03,0.1))]
        expectFalse(guardrail.permits(.fireHealing,observation:o,now:0,aim:mate.position))
        // Never with an opponent in the open, nor at one.
        o.obstacles=[];var foe=enemy();foe.position=Point(0.5,0.3);o.players=[mate,foe]
        expectFalse(guardrail.permits(.fireHealing,observation:o,now:0,aim:mate.position))
        o.players=[enemy()];expectFalse(guardrail.permits(.fireHealing,observation:o,now:0,aim:Point(0.7,0.5)))
    }
    @Test func testTheHealingGunBouncesSquareOffAWallBackToYou() {
        var (c,o)=medic(["special:epic:healing_gun",nil,nil,nil])
        // A wall 0.08 view widths to your right, running up and down; you stand still.
        o.obstacles=[.init(.wall,bounds:.init(0.58,0.3,0.02,0.4))];o.ownVelocity=Point()
        assertRelease(step(c,o)) // Only in a safe gap, like a potion.
        o.timestamp=2.1;expectEqual(step(c,o).reason,"Select Epic Healing Gun to heal you off a wall")
        expectEqual(c.healingItem,"Epic Healing Gun") // The app asks you to stand still.
        o.timestamp=2.15;o.selectedSlot=3;_=step(c,o)
        o.timestamp=2.5;let shot=step(c,o)
        expectEqual(shot.intents,[.aim(Point(0.58,0.5)),.fireHealing]);expectEqual(shot.reason,"Epic Healing Gun off the wall to heal you: health 30")
        expectTrue(ActionGuard(profiles:c.profiles).permits(.fireHealing,observation:o,now:2.5,aim:Point(0.58,0.5)))
        // Walking, the round would come back to where you were: it waits for you to stand still.
        o.ownVelocity=Point(0.1,0);o.timestamp=3.0;let moving=step(c,o)
        expectEqual(moving.reason,"Stand still: the Epic Healing Gun bounces off the wall back to you");expectFalse(moving.intents.contains(.fireHealing))
        expectFalse(ActionGuard(profiles:c.profiles).permits(.fireHealing,observation:o,now:3.0,aim:Point(0.58,0.5)))
        // Standing still again, with the first round's 12 health back.
        o.ownVelocity=Point();o.health=42;o.timestamp=3.1;expectTrue(step(c,o).intents.contains(.fireHealing))
        o.health=89;o.timestamp=3.7;expectEqual(step(c,o).reason,"Healed with the Epic Healing Gun")
    }
    @Test func testABounceNeedsAFlatWallSquareToTheShot() {
        var o=observation();o.ownVelocity=Point()
        // A wall's corner: rays beside the shot miss it.
        o.obstacles=[.init(.wall,bounds:.init(0.58,0.49,0.02,0.02))];#expect(Policy.bounceTarget(o) == nil)
        // A slanted wall, a staircase of cells nearer on one side than the other.
        o.obstacles=[.init(.wall,bounds:.init(0.56,0.4,0.06,0.2),maskCells:(0..<10).map { k in Rect(0.56+0.004*Double(k),0.4+0.02*Double(k),0.02,0.02) })]
        #expect(Policy.bounceTarget(o) == nil)
        // Inside the gun's muzzle, or too far for the round to come back.
        o.obstacles=[.init(.wall,bounds:.init(0.53,0.3,0.02,0.4))];#expect(Policy.bounceTarget(o) == nil)
        o.obstacles=[.init(.wall,bounds:.init(0.7,0.3,0.02,0.4))];#expect(Policy.bounceTarget(o) == nil)
        // A tree in front of the wall would take the round.
        o.obstacles=[.init(.wall,bounds:.init(0.58,0.3,0.02,0.4)),.init(.tree,bounds:.init(0.54,0.48,0.02,0.04))];#expect(Policy.bounceTarget(o) == nil)
        // A wall above you, running left and right, does; so does the nearer of two.
        o.obstacles=[.init(.wall,bounds:.init(0.3,0.36,0.4,0.02)),.init(.wall,bounds:.init(0.6,0.3,0.02,0.4))]
        let up=Policy.bounceTarget(o)
        #expect(up.map { abs($0.x-0.5)<1e-9 && abs($0.y-0.38)<1e-9 } == true)
    }
    @Test func testTheHealingGunNeverFightsOrFinishesACombo() {
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation()
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"special:epic:healing_gun",totalAmmo:8),.init(3,count:0),.init(4,count:0),.init(5,count:0),.init(6,count:0)]
        o.players=[enemy()]
        let d=step(c,o)
        expectFalse(d.intents.contains(.fire));expectFalse(d.intents.contains(.fireHealing))
        let guardrail=ActionGuard(profiles:c.profiles)
        for intent in [InputIntent.fire,.fireAtPull,.fireHealing] { expectFalse(guardrail.permits(intent,observation:o,now:0,aim:Point(0.7,0.5))) }
        // With a Reverse Impulse, an opponent in the open still gets the M4, not a pull into healing rounds.
        let (combo,fight)=comboFight(["reverse_impulse_grenade","special:epic:healing_gun",nil,nil])
        expectTrue(step(combo,fight).intents.contains(.fire))
        // It is never picked up for you either.
        var (looter,offer)=kitted(nil,nil);offer.prompt=HUDText.prompt(lines:["Healing Weapon","E","Epic Unique"],confidence:1,catalog:.standard,key:"E")
        expectEqual(step(looter,offer).reason,"Not picking up Epic Healing Gun: launchers and special weapons stay manual")
    }
    @Test func testTheHealingGunTakesAHealSlotButNeverMakesWay() {
        // An AR, the Healing Gun and three potions, as recorded: the missing SMG takes the potion that helps least.
        let c=Coordinator(catalog:.standard);c.features.idleWeapon=false
        var o=observation();o.shield=100
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:legendary:ar15",ammo:30,reserveAmmo:90),.init(3,itemID:"special:epic:healing_gun",totalAmmo:8),
                     .init(4,itemID:"small_shield"),.init(5,itemID:"medkit"),.init(6,itemID:"hybrid_potion")]
        o.prompt=gunPrompt("Uzi","Common SMG")
        expectEqual(step(c,o).reason,"Select slot 4 to swap for Uzi")
        // With one potion and a utility item, the utility item goes; the Healing Gun stays either way.
        let d=Coordinator(catalog:.standard);d.features.idleWeapon=false
        o.inventory=[.init(1,itemID:"fists"),.init(2,itemID:"ar:legendary:ar15",ammo:30,reserveAmmo:90),.init(3,itemID:"special:epic:healing_gun",totalAmmo:8),
                     .init(4,itemID:"medkit"),.init(5,itemID:"sniper:rare:bolt_mk2",ammo:5,reserveAmmo:10),.init(6,itemID:"frag_grenade",count:3)]
        expectEqual(step(d,o).reason,"Select slot 6 to swap for Uzi")
    }
    @Test func testHealingItemsAreNamedFromTheirPrompts() {
        let catalog=ItemCatalog.standard
        func id(_ lines:[String])->String? { HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E")?.itemID }
        // As recorded: the panel calls the Healing Gun "Healing Weapon".
        expectEqual(id(["x2","Healing Grenade","E","Legendary Grenade"]),"healing_grenade")
        expectEqual(id(["Healing Weapon","E","Epic Unique"]),"special:epic:healing_gun")
        expectEqual(id(["Healing Gun","E","Epic Unique"]),"special:epic:healing_gun")
        expectEqual(id(["Healing Gun","E","Epic Healing"]),"special:epic:healing_gun")
        let gun=catalog.profile("special:epic:healing_gun")!,grenade=catalog.profile("healing_grenade")!
        expectTrue(Policy.isHealingGun(gun));expectEqual(gun.role,nil);expectEqual(gun.healthGain,12)
        expectTrue(Policy.isHealGrenade(grenade));expectTrue(Coordinator.isUtility(grenade))
        // About 20 health a second for 4.5 s, in a circle 0.118 view widths across its radius, as measured.
        expectEqual(grenade.healthGain/grenade.overTime,20);expectEqual(grenade.radius,0.118)
        expectFalse(Policy.isHealingGun(catalog.profile("special:mythic:crossbow")!))
    }
    @Test func testTeammateTagsKeepTheirRosterName() {
        var t=AffiliationTracker();let roster=["Chris_Hansen","SLK_2fps"]
        t.record(track:1,read:.text("Chris_Hanseh",0.9),roster:roster,time:0)
        expectEqual(t.name(track:1,time:0.1),"Chris_Hansen")
        t.record(track:2,read:.text("speedrun",0.9),roster:roster,time:0);t.record(track:2,read:.text("speedrun",0.9),roster:roster,time:0.5)
        expectEqual(t.name(track:2,time:0.6),nil) // An opponent has no roster name.
        expectEqual(t.name(track:1,time:20),nil) // Nor a tag not read for a long while.
    }
}

private extension Observation {
    func with(players: [PlayerTrack]) -> Observation { var o = self; o.players = players; return o }
}

private func expectEqual<T:Equatable>(_ actual:T,_ expected:T,_ message:String="",file:StaticString=#filePath,line:UInt=#line) {
    #expect(actual == expected, "\(message) Expected \(expected); got \(actual) at \(file):\(line)")
}
private func expectTrue(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { #expect(value, "at \(file):\(line)") }
private func expectFalse(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { #expect(!value, "at \(file):\(line)") }
private func expectGreater<T:Comparable>(_ actual:T,_ lower:T,file:StaticString=#filePath,line:UInt=#line) { #expect(actual > lower, "at \(file):\(line)") }
