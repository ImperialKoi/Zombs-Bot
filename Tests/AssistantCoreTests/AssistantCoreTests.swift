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
        return o
    }
    func engine(combat:Bool=true,loot:Bool=true,healing:Bool=true)->Coordinator {
        let c=Coordinator(profiles:profiles()); c.features.combat=combat; c.features.loot=loot; c.features.healing=healing; return c
    }
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
    @Test func testCombatDoesNotWaitOutSettlingPeriods() {
        let c=engine();var o=observation();o.prompt=itemPrompt("Med Kit","med")
        expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=1.3;expectEqual(step(c,o).reason,"Pickup not confirmed; no repeated interact press")
        o.timestamp=1.4;expectEqual(step(c,o).reason,"Waiting for the game to settle")
        o.timestamp=1.45;o.prompt=nil;o.players=[enemy()];expectTrue(step(c,o).intents.contains(.fire))
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
                    let aim=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:age))
                    let flight=aim.distance(to:o.player,aspect:aspect)/weapon.projectileSpeed
                    let future=target.position+velocity*(age+flight)
                    #expect(aim.distance(to:future,aspect:aspect)<1e-10)
                }
            }
        }
    }
    @Test func testLongLeadIsAcceptedByInputGuard() throws {
        var weapon=profiles()[0];weapon.projectileSpeed=0.4
        let c=Coordinator(profiles:[weapon]), guardrail=ActionGuard(profiles:[weapon.id:weapon])
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
        let equalSpeed=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0))
        #expect(abs(equalSpeed.x-0.6)<1e-10)
        target=enemy(Point(-0.8,0))
        let fastApproach=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0))
        #expect(abs(fastApproach.x-(0.5+0.2/3))<1e-10)
        for velocity in [Point(0.4,0),Point(0.8,0),Point(0,1),Point(.nan,0),Point(.greatestFiniteMagnitude,0)] {
            target=enemy(velocity)
            #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0)==nil)
        }
        target=enemy(Point(0.3,0)) // Future intersection would be outside the viewport.
        #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0)==nil)
        target=enemy(Point(0.2,0));weapon.maxRange=0.3 // Present position in range, intercept beyond range.
        #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0)==nil)
        o.players=[target]
        #expect(!Coordinator(profiles:[weapon]).step(o,now:0).intents.contains(.fire))
    }
    @Test func testUncalibratedSpeedOnlyCompensatesFrameAge() throws {
        let o=observation();let target=enemy(Point(0.2,0.1))
        var weapon=profiles()[0];weapon.projectileSpeed=0
        let aim=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0.1))
        #expect(aim.distance(to:Point(0.72,0.51))<1e-10)
        #expect(Targeting.aim(at:target,in:o,weapon:weapon,now:0.2)==nil)
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
    @Test func testPickupIsSinglePressUntilInventoryChanges() {
        let c=engine();var o=observation();o.selectedSlot=3;o.prompt=itemPrompt("Med Kit","med")
        expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        o.timestamp=0.1;assertRelease(step(c,o));o.timestamp=1.3;assertRelease(step(c,o));o.timestamp=2.2
        expectFalse(step(c,o).intents.contains(.pickup("Med Kit")))
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
        o.timestamp=0.3;o.selectedSlot=2
        expectTrue(step(c,o).intents.contains(.pickup("SCAR")))
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
        o.timestamp=2.7;o.shield=25;o.inventory[2].count=1;expectEqual(step(c,o).reason,"Healing confirmed")
        o.timestamp=2.95;expectTrue(step(c,o).intents.contains(.useConsumable)) // Shields are not full yet.
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
    @Test func testConsumedItemReleasesWhileBenefitIsDelayed() {
        let c=engine();var o=observation();o.health=20;o.inventory[2] = .init(3,itemID:"med");o.selectedSlot=3
        _=step(c,o);o.timestamp=2.1;_=step(c,o)
        o.timestamp=2.4;o.inventory[2] = .init(3,count:0)
        expectEqual(step(c,o).reason,"Consumable spent; waiting for health or shield confirmation")
        o.timestamp=2.6;o.health=70
        expectEqual(step(c,o).reason,"Healing confirmed")
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

    // MARK: Prompt text
    @Test func testPromptParserIdentifiesItemsAndRejectsEverythingElse() throws {
        let catalog=ItemCatalog.standard
        let gun=try #require(HUDText.prompt(lines:["M4","Rare AR","E"],confidence:1,catalog:catalog,key:"E"))
        expectEqual(gun.kind,.weapon);expectEqual(gun.itemID,"ar:rare");expectEqual(gun.name,"M4")
        let pump=try #require(HUDText.prompt(lines:["Pump Shotgun","Legendary Shotgun"],confidence:1,catalog:catalog))
        expectEqual(pump.itemID,"shotgun:legendary")
        let potion=try #require(HUDText.prompt(lines:["Hybrid Potion","x2","Healing","E"],confidence:1,catalog:catalog,key:"E"))
        expectEqual(potion.itemID,"hybrid_potion");expectEqual(potion.count,2)
        let appended=try #require(HUDText.prompt(lines:["Bandage x5","Healing"],confidence:1,catalog:catalog))
        expectEqual(appended.itemID,"bandage");expectEqual(appended.count,5)
        for lines in [["Gold Chest","Interact","E"],["Hoverboard","Exit Vehicle","E"],["Door","Open"],["Chris_Hansen","Revive"],["Mystery","Rare Gizmo"]] {
            let p=try #require(HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E"))
            expectEqual(p.kind,.other);expectFalse(p.isItem)
        }
        expectFalse(HUDText.prompt(lines:["M4","Rare AR","F"],confidence:1,catalog:catalog,key:"E")?.isItem ?? true)
        expectTrue(HUDText.prompt(lines:["M4"],confidence:1,catalog:catalog)==nil)
        let unknownHeal=try #require(HUDText.prompt(lines:["Mystery Brew","Healing"],confidence:1,catalog:catalog))
        expectEqual(unknownHeal.kind,.healing);expectFalse(unknownHeal.isItem)
        // Recorded misreads: Cyrillic look-alikes and stray symbols.
        expectEqual(HUDText.prompt(lines:["MP5","E","Еріс SMG"],confidence:1,catalog:catalog,key:"E")?.itemID,"smg:epic")
        expectEqual(HUDText.prompt(lines:["MP5","Epіc SMG"],confidence:1,catalog:catalog)?.itemID,"smg:epic")
        expectEqual(HUDText.prompt(lines:["SCAR","Uncommon AR •"],confidence:1,catalog:catalog)?.itemID,"ar:uncommon")
        expectEqual(HUDText.prompt(lines:["Pump Shotgun","&Common Shotgun"],confidence:1,catalog:catalog)?.itemID,"shotgun:common")
        expectEqual(HUDText.prompt(lines:["Small Shield","x2","Potion"],confidence:1,catalog:catalog)?.itemID,"small_shield")
        expectEqual(HUDText.prompt(lines:["Big Shield","Potion"],confidence:1,catalog:catalog)?.itemID,"large_shield")
        expectEqual(HUDText.prompt(lines:["Frag Grenade","Common Grenade"],confidence:1,catalog:catalog)?.kind,.throwable)
        for lines in [["Hoverboard","Exir Vehicle"],["Door","•Close"],["Crate (Mystic)","Interact"],["x15","Small","Ammo"],["Katana","Mythic Melee"],["Bow","Legendary Unique"]] {
            expectFalse(HUDText.prompt(lines:lines,confidence:1,catalog:catalog)?.isItem ?? false)
        }
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
    @Test func testTrackerConfirmsAfterRepeatedDetections() {
        var tracker=PlayerMotionTracker();var states:[Bool]=[]
        for k in 0..<4 { states.append(tracker.update(time:Double(k)*0.05,aspect:1,sceneryShift:Point(),players:[Point(0.7,0.5)])[0].confirmed) }
        expectEqual(states,[false,false,true,true])
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
        let standing=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0.1))
        #expect(standing.distance(to:target.position+target.velocity*0.1)<1e-12)
        // An opponent running alongside you looks still on screen but does need a lead.
        target.velocity=Point(); target.motion = .init(groundVelocity:Point(0.15,0))
        let alongside=try #require(Targeting.aim(at:target,in:o,weapon:weapon,now:0.1))
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
        let firing=step(engine(),o)
        expectTrue(firing.intents.contains(.fire))
        let lead=try #require(firing.intents.compactMap { if case .aim(let p)=$0 { return p };return nil }.first)
        expectTrue(ActionGuard(profiles:c.profiles).permits(.fire,observation:o,now:0,aim:lead))
        let intercept=try #require(Targeting.intercept(target,in:o,weapon:profiles()[0],now:0))
        expectTrue(intercept.hitProbability>=Policy.minHitProbability && intercept.hitProbability<1)
    }
    @Test func testOpponentWithoutMotionEstimateIsNotEngaged() {
        var o=observation(); var target=enemy(); target.motion=nil; o.players=[target]
        let decision=step(engine(),o)
        expectEqual(decision.reason,"Opponent motion unknown"); expectFalse(decision.intents.contains(.fire))
        expectFalse(ActionGuard(profiles:engine().profiles).permits(.fire,observation:o,now:0,aim:target.position))
    }
}

private func expectEqual<T:Equatable>(_ actual:T,_ expected:T,_ message:String="",file:StaticString=#filePath,line:UInt=#line) {
    #expect(actual == expected, "\(message) Expected \(expected); got \(actual) at \(file):\(line)")
}
private func expectTrue(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { #expect(value, "at \(file):\(line)") }
private func expectFalse(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { #expect(!value, "at \(file):\(line)") }
private func expectGreater<T:Comparable>(_ actual:T,_ lower:T,file:StaticString=#filePath,line:UInt=#line) { #expect(actual > lower, "at \(file):\(line)") }
