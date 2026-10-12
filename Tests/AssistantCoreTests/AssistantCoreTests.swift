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
    func chestPrompt(_ name:String="Gold Chest",stable:Bool=true)->InteractionPrompt {
        InteractionPrompt(name:name,subtitle:"Interact",kind:.chest,stable:stable)
    }
    @Test func testChestIsOpenedWithOnePressAndNotPressedAgain() {
        let c=engine();var o=observation();o.prompt=chestPrompt()
        expectEqual(step(c,o).intents,[.releaseAll,.open("Gold Chest")])
        o.timestamp=0.1;expectEqual(step(c,o).reason,"Opening Gold Chest")
        o.timestamp=0.3;o.prompt=itemPrompt("Med Kit","med") // Opened: its loot is under you now.
        expectEqual(step(c,o).reason,"Chest prompt gone; Gold Chest opened or left behind")
        o.timestamp=0.7;expectTrue(step(c,o).intents.contains(.pickup("Med Kit")))
        // A chest that does not open is not pressed again for a while.
        let d=engine();o.timestamp=0;o.prompt=chestPrompt("Ammo Chest")
        expectTrue(step(d,o).intents.contains(.open("Ammo Chest")))
        o.timestamp=1.6;expectEqual(step(d,o).reason,"Ammo Chest did not open; not pressing again for 3 s")
        o.timestamp=3;expectFalse(step(d,o).intents.contains(.open("Ammo Chest")))
        o.timestamp=4.7;expectTrue(step(d,o).intents.contains(.open("Ammo Chest")))
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
        // A small game: holding the potion 2 s drinks one, and each drink adds 25/25 over the next 10 s.
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
        o.timestamp=5.2;o.prompt=itemPrompt("AWP","sniper",.weapon);expectEqual(step(c,o).reason,"Air Drop Chest opened or left behind")
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

    // MARK: Prompt misreads and the consumable in hand
    @Test func testPromptParserToleratesRecordedMisreads() throws {
        let catalog=ItemCatalog.standard
        func read(_ lines:[String])->InteractionPrompt? { HUDText.prompt(lines:lines,confidence:1,catalog:catalog,key:"E") }
        let badge=try #require(read(["XZ","Small Shield","E","Potion"]));expectEqual(badge.itemID,"small_shield");expectEqual(badge.count,2)
        expectEqual(read(["XI5","Bandage","Healing"])?.count,15)
        expectEqual(read(["SCAR","Eo","Rare AR"])?.itemID,"ar:rare")
        expectEqual(read(["MP5","E","Uncommon SMC"])?.itemID,"smg:uncommon")
        expectEqual(read(["SCAR","E","Rare ARO"])?.itemID,"ar:rare")
        expectEqual(read(["AWP","egendary Sniper"])?.itemID,"sniper:legendary")
        expectEqual(read(["Glock","Rafe Pistol"])?.itemID,"pistol:rare")
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
}

private func expectEqual<T:Equatable>(_ actual:T,_ expected:T,_ message:String="",file:StaticString=#filePath,line:UInt=#line) {
    #expect(actual == expected, "\(message) Expected \(expected); got \(actual) at \(file):\(line)")
}
private func expectTrue(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { #expect(value, "at \(file):\(line)") }
private func expectFalse(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { #expect(!value, "at \(file):\(line)") }
private func expectGreater<T:Comparable>(_ actual:T,_ lower:T,file:StaticString=#filePath,line:UInt=#line) { #expect(actual > lower, "at \(file):\(line)") }
