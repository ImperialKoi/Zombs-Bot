import Testing
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import AssistantCore
@testable import Perception

/// HUD crops cut at native resolution from recorded matches, composited back at their original
/// positions on a gray frame: 3840×1736 (Solo) and 2880×1376 (Duo, with a teammate roster row).
private struct FixtureFrame: Decodable {
    struct Part: Decodable { var file: String; var x: Int; var y: Int }
    var width: Int; var height: Int; var parts: [Part]
}

private func fixtureDirectory() throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
}

private func frame(_ name: String) throws -> PixelImage {
    let dir = try fixtureDirectory()
    let manifest = try JSONDecoder().decode([String: FixtureFrame].self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))
    let spec = try #require(manifest[name])
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: spec.width, height: spec.height, bitsPerComponent: 8, bytesPerRow: spec.width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
    for part in spec.parts {
        let source = try #require(CGImageSourceCreateWithURL(dir.appendingPathComponent(part.file) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Core Graphics draws from the bottom left.
        context.draw(image, in: CGRect(x: part.x, y: spec.height - part.y - image.height, width: image.width, height: image.height))
    }
    let composed = try #require(context.makeImage())
    return try #require(PixelImage(cgImage: composed))
}

private func read(_ name: String) throws -> HUDSnapshot {
    let image = try frame(name)
    let layout = try #require(HUDLayout.detect(in: image))
    return HUDReader.read(image, layout: layout)
}

struct PerceptionTests {
    // MARK: Rounds in flight
    /// The sighting within 12 pixels of (`x`, `y`) on a frame `width` × `height`.
    private func sighting(_ found: [BulletSighting], _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> BulletSighting? {
        found.first { abs($0.position.x * width - x) < 12 && abs($0.position.y * height - y) < 12 }
    }
    @Test func testRoundsAreFoundWithTheirAmmunitionAndWayOfFlight() throws {
        let detector = BulletDetector()
        // An opponent's sniper round flying left at you over grass; its trail fades out behind it, to the right.
        let large = detector.detect(try frame("rounds-large"))
        let sniper = try #require(sighting(large, 3397, 795, 3840, 1736))
        #expect(sniper.ammo == .large); #expect(sniper.oriented); #expect(sniper.direction.x < -0.95)
        #expect((sniper.tail?.x ?? 0) * 3840 > 3440)
        #expect(large.count == 1)
        // On snow: your AR round flying right, and an SMG round flying left.
        let snow = detector.detect(try frame("rounds-snow"))
        let ar = try #require(sighting(snow, 2846, 989, 3840, 1736))
        #expect(ar.ammo == .medium); #expect(ar.direction.x > 0.9)
        let smg = try #require(sighting(snow, 2251, 1149, 3840, 1736))
        #expect(smg.ammo == .small); #expect(smg.direction.x < -0.9)
        // Three SMG rounds of a burst flying up, a little to the left, on a recording 2,880 pixels wide, each with its trail.
        let clip = detector.detect(try frame("rounds-clip"))
        for (x, y) in [(814.0, 290.0), (1026.0, 395.0), (1251.0, 522.0)] {
            let round = try #require(sighting(clip, x, y, 2880, 1376))
            #expect(round.ammo == .small); #expect(round.direction.x < 0 && round.direction.y < -0.8); #expect(round.tail != nil)
        }
    }
    @Test func testRoundsAreNotFoundOnTheHUDOrPlainGround() throws {
        let detector = BulletDetector()
        let image = try frame("rounds-large")
        #expect(detector.detect(image, excluding: [PixelRect(3300, 700, 300, 200)]).isEmpty)
        #expect(detector.detect(try frame("a-010611")).allSatisfy { $0.ammo != nil })
    }

    @Test func testFindsTheHUDAtBothRecordedResolutions() throws {
        let solo = try #require(HUDLayout.detect(in: try frame("a-010611")))
        #expect(abs(solo.unit - 142) <= 2)
        #expect(abs(solo.originX - 2868) <= 2 && abs(solo.originY - 1500) <= 3)
        let duo = try #require(HUDLayout.detect(in: try frame("b-004539")))
        #expect(abs(duo.unit - 110) <= 2)
    }

    @Test func testReadsVitalsSelectionRarityAndEmptySlots() throws {
        let full = try read("a-010611")
        #expect(full.alive)
        #expect(full.health == 100 && full.shield == 100 && full.vitalsConfidence == 1)
        #expect(full.selectedSlot == 2)
        #expect(full.slots[1].rarity == .mythic && full.slots[2].rarity == .epic)
        #expect(full.slots[0].lightTile && full.slots[3].lightTile)
        #expect(!full.slots[4].occupied)
        let hurt = try read("a-006323")
        #expect(abs((hurt.health ?? 0) - 84) <= 1 && abs((hurt.shield ?? 0) - 60) <= 1)
        #expect(hurt.selectedSlot == 4)
        #expect(!hurt.slots[5].occupied)
        let duo = try read("b-004539")
        #expect(duo.health == 100 && abs((duo.shield ?? 0) - 91) <= 1)
        #expect(duo.selectedSlot == 2 && duo.slots[1].rarity == .legendary)
    }

    @Test func testPromptPanelAndTeamRoster() throws {
        #expect(try read("a-006323").promptVisible)
        #expect(try read("a-001235").promptVisible)
        #expect(try read("b-004539").promptVisible)
        #expect(!(try read("a-010611").promptVisible))
        #expect(try read("b-004539").rosterRows == 1)
        #expect(try read("a-010611").rosterRows == 0)
    }

    @Test func testRosterBarsGiveEachTeammatesHealthAndShield() throws {
        #expect(try read("b-004539").roster == [RosterVitals(row: 0, down: false, health: 100, shield: 100)])
        let hurt = try #require(try read("c-003153").roster.first)
        #expect(!hurt.down && abs(hurt.health - 29.6) <= 1.5 && abs(hurt.shield - 49.3) <= 1.5)
        // Knocked down: the health bar turns red while they bleed out.
        #expect(try read("c-002842").roster.first?.down == true)
        // Three teammates over the storm, whose orange shows through the empty shield bars, and a teammate's map pin over
        // the bottom row's full health bar.
        let squad = try read("d-000548").roster
        #expect(squad.map(\.row) == [0, 1, 2] && squad.allSatisfy { !$0.down && $0.shield == 0 })
        #expect(zip(squad.map(\.health), [100, 48.2, 34.4]).allSatisfy { abs($0 - $1) <= 1.5 })
    }

    @Test func testATeammateCountsAsDownUntilTheirBarHasStayedGreen() throws {
        let engine = PerceptionEngine(artifacts: nil, settings: PerceptionSettings(mode: .duo), library: IconLibrary(entries: []),
                                      text: TextReader(synchronous: true))
        let down = try frame("c-002842"), up = try frame("c-003153")
        #expect(engine.process(image: down, ciImage: nil, timestamp: 0).observation.squad.first?.down == true)
        // A revive starting flashes the bar green for a frame.
        #expect(engine.process(image: up, ciImage: nil, timestamp: 0.4).observation.squad.first?.down == true)
        let later = try #require(engine.process(image: up, ciImage: nil, timestamp: 1.5).observation.squad.first)
        #expect(!later.down && abs(later.health - 29.6) <= 1.5 && later.name == "Chris_Hansen")
    }

    func promptOf(_ name: String) throws -> InteractionPrompt? {
        let image = try frame(name)
        let layout = try #require(HUDLayout.detect(in: image))
        let crop = try #require(image.cgImage(layout.prompt))
        return HUDText.prompt(lines: TextReader.recognize(crop).map(\.text), confidence: 1, catalog: .standard, key: "E")
    }
    @Test func testTextRecognitionReadsPromptsAndAmmunition() throws {
        let gun = try #require(try promptOf("a-001235"))
        #expect(gun.kind == .weapon && gun.itemID == "ar:rare:m4" && gun.name == "M4")
        let potion = try #require(try promptOf("a-006323"))
        #expect(potion.itemID == "hybrid_potion")
        let vehicle = try #require(try promptOf("b-004539"))
        #expect(vehicle.kind == .other && !vehicle.isItem)
        let ammoFrame = try frame("a-010611")
        let ammoLayout = try #require(HUDLayout.detect(in: ammoFrame))
        let crop = try #require(ammoFrame.cgImage(ammoLayout.readout))
        let ammo = try #require(HUDText.ammunition(TextReader.recognize(crop).map(\.text).joined(separator: " ")))
        #expect(ammo.loaded == 90 && ammo.reserve == 1042)
    }

    // MARK: Detector input

    @Test func testManifestDescribesSquareAndWideInputs() throws {
        let fields = #"{"modelFile":"zombs.mlpackage","modelSHA256":"","inputSize":960,"labels":["tree"],"detectorThreshold":0.5,"maskThreshold":0.5}"#
        let square = try JSONDecoder().decode(ModelManifest.self, from: Data(fields.utf8))
        #expect(square.inputPixels.width == 960 && square.inputPixels.height == 960)
        let wide = try JSONDecoder().decode(ModelManifest.self, from: Data(fields.replacingOccurrences(of: #""inputSize":960"#, with: #""inputSize":960,"inputHeight":768"#).utf8))
        #expect(wide.inputPixels.width == 960 && wide.inputPixels.height == 768)
    }

    @Test func testPreviewIsTheFramePartOfTheModelInput() throws {
        // A 3840 × 1736 frame in a 960 × 768 input: 434 rows of frame between 167 rows of gray above and below.
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        #expect(CVPixelBufferCreate(nil, 960, 768, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<768 { for x in 0..<960 {
            let p = base + y * stride + x * 4, inFrame = (167..<601).contains(y)
            p[0] = inFrame ? 10 : 114; p[1] = inFrame ? 20 : 114; p[2] = inFrame ? 200 : 114; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let image = try #require(ModelInput(buffer: buffer, content: CGRect(x: 0, y: 167, width: 960, height: 434)).cgImage())
        #expect(image.width == 960 && image.height == 434)
        let pixels = try #require(PixelImage(cgImage: image))
        #expect(pixels.pixel(0, 0) == RGB(200, 20, 10) && pixels.pixel(959, 433) == RGB(200, 20, 10))
    }

    // MARK: Players

    @Test func testSoloNeverSwitchesToTeamRules() throws {
        // b-004539 is a Duo frame with a teammate roster row.
        let image = try frame("b-004539")
        let solo = PerceptionEngine(artifacts: nil, settings: PerceptionSettings(mode: .solo), library: IconLibrary(entries: []), text: TextReader(synchronous: true))
        let warning = "Solo is selected, but a teammate roster is showing"
        for t in [0.0, 1.0] { #expect(!solo.process(image: image, ciImage: nil, timestamp: t).observation.teamMode) }
        #expect(!solo.process(image: image, ciImage: nil, timestamp: 1.5).problems.contains { $0.hasPrefix(warning) })
        let later = solo.process(image: image, ciImage: nil, timestamp: 2.5)
        #expect(!later.observation.teamMode && later.problems.contains { $0.hasPrefix(warning) })
        let duo = PerceptionEngine(artifacts: nil, settings: PerceptionSettings(mode: .duo), library: IconLibrary(entries: []), text: TextReader(synchronous: true))
        let team = duo.process(image: image, ciImage: nil, timestamp: 0)
        #expect(team.observation.teamMode && !team.problems.contains { $0.hasPrefix(warning) })
    }

    @Test func testOnePersonReportedTwiceIsOnePlayer() {
        var strong=Detection(label:"player",confidence:0.9,bounds:Rect(0.6,0.4,0.03,0.06))
        var weak=Detection(label:"player",confidence:0.5,bounds:Rect(0.601,0.401,0.03,0.06))
        let other=Detection(label:"player",confidence:0.7,bounds:Rect(0.3,0.4,0.03,0.06))
        let tree=Detection(label:"tree",confidence:0.6,bounds:Rect(0.6,0.4,0.03,0.06))
        strong.id=1; weak.id=2
        let merged=PerceptionEngine.mergingDuplicatePlayers([weak,tree,strong,other])
        #expect(merged.filter { $0.label=="player" }.map(\.confidence)==[0.9,0.7])
        #expect(merged.contains { $0.label=="tree" })
    }

    @Test func testNothingSolidOrHostileIsWhereYouStand() {
        let onYou = Rect(0.485, 0.47, 0.03, 0.06), nearby = Rect(0.53, 0.42, 0.03, 0.06)
        let kept = PerceptionEngine.excludingYourself(["chest", "wall", "door", "tree", "self_player"].map { Detection(label: $0, confidence: 0.8, bounds: onYou) }
                                                      + [Detection(label: "chest", confidence: 0.8, bounds: nearby), Detection(label: "self_player", confidence: 0.8, bounds: nearby)],
                                                      aspect: 2.2)
        #expect(kept.map(\.label) == ["tree", "chest", "player"]) // A real crate beside you still blocks; another character is a player.
    }

    @Test func testMissedPlayerStaysBrieflyAtItsPredictedPosition() {
        let tracker=SceneTracker()
        for k in 0...4 {
            let found=tracker.update([Detection(label:"player",confidence:0.8,bounds:Rect(0.6+0.005*Double(k),0.4,0.03,0.06))],at:0.05*Double(k),aspect:2)
            #expect(found.count==1 && !found[0].predicted)
        }
        let missed=tracker.update([],at:0.25,aspect:2)
        #expect(missed.count==1 && missed[0].predicted && missed[0].confirmed)
        #expect(missed.first.map { $0.bounds.center.x>0.63 && abs($0.bounds.width-0.03)<1e-9 } == true)
        #expect(tracker.update([],at:0.55,aspect:2).isEmpty)
    }

    // MARK: Inventory identity

    func icon(_ seed: Int, hue: Int = 3) -> IconFingerprint {
        var outline = (0..<256).map { Float(($0 * 37 + seed * 101) % 17 < 5 ? 1 : 0) }
        let norm = outline.reduce(0) { $0 + $1 * $1 }.squareRoot(); outline = outline.map { $0 / norm }
        var colors = [Float](repeating: 0, count: 14); colors[hue] = 1
        return IconFingerprint(outline: outline, colors: colors)
    }
    func snapshot(_ occupied: [Int: (IconFingerprint, Rarity?)], selected: Int? = nil) -> HUDSnapshot {
        let layout = HUDLayout(width: 3840, height: 1736, unit: 142, originX: 2868, originY: 1500, pitch: 155.4)
        let slots = (1...6).map { index -> SlotReading in
            if index == 1 { return SlotReading(index: 1, occupied: true, tile: nil, rarity: nil, lightTile: true, selectionScore: 0, icon: icon(99), number: []) }
            guard let (fingerprint, rarity) = occupied[index] else {
                return SlotReading(index: index, occupied: false, tile: nil, rarity: nil, lightTile: false, selectionScore: 0, icon: nil, number: [])
            }
            return SlotReading(index: index, occupied: true, tile: nil, rarity: rarity, lightTile: rarity == nil, selectionScore: 0, icon: fingerprint, number: [])
        }
        return HUDSnapshot(layout: layout, alive: true, health: 100, shield: 0, vitalsConfidence: 1, slots: slots, selectedSlot: selected,
                           selectedConfidence: selected == nil ? 0 : 1, promptVisible: false, promptRect: nil, promptFingerprint: [], readoutFingerprint: [],
                           reserveFingerprints: [], rosterRows: 0)
    }
    let m4 = InteractionPrompt(name: "M4", subtitle: "Rare AR", kind: .weapon, itemID: "ar:rare:m4", weaponClass: .ar, rarity: .rare)

    @Test func testPickupTeachesTheIconAndLaterMatchesAnyRarity() {
        let library = IconLibrary(entries: [])
        let tracker = InventoryTracker(library: library)
        _ = tracker.update(snapshot([:]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0)
        _ = tracker.update(snapshot([:]), prompt: m4, readout: nil, counts: [:], reserves: [:], time: 0.2)
        let picked = tracker.update(snapshot([2: (icon(1), .rare)]), prompt: nil, readout: nil, counts: [2: 120], reserves: [:], time: 0.4)
        #expect(picked[1].itemID == "ar:rare:m4" && picked[1].totalAmmo == 120 && picked[1].label == "M4")
        _ = tracker.update(snapshot([2: (icon(1), .rare)]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.9)
        #expect(library.entries.count == 1)
        let later = InventoryTracker(library: library)
        let seen = later.update(snapshot([3: (icon(1), .epic)]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0)
        #expect(seen[2].itemID == "ar:epic:m4") // The icon names the gun at any rarity.
    }

    @Test func testSimultaneousChangesAreNotLabeledByThePrompt() {
        let library = IconLibrary(entries: [])
        let tracker = InventoryTracker(library: library)
        _ = tracker.update(snapshot([:]), prompt: m4, readout: nil, counts: [:], reserves: [:], time: 0)
        let both = tracker.update(snapshot([2: (icon(1), .rare), 3: (icon(2), nil)]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.2)
        #expect(both[1].itemID == nil && both[2].itemID == nil)
        _ = tracker.update(snapshot([2: (icon(1), .rare), 3: (icon(2), nil)]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.8)
        #expect(library.entries.isEmpty)
    }

    @Test func testRearrangedItemsKeepTheirIdentity() {
        let library = IconLibrary(entries: [])
        let tracker = InventoryTracker(library: library)
        _ = tracker.update(snapshot([:]), prompt: m4, readout: nil, counts: [:], reserves: [:], time: 0)
        _ = tracker.update(snapshot([2: (icon(1), .rare)]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.2)
        let moved = tracker.update(snapshot([5: (icon(1), .rare)]), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 2)
        #expect(moved[4].itemID == "ar:rare:m4" && moved[1].isKnownEmpty)
    }

    @Test func testUnknownSelectedWeaponIsPlacedByItsAmmunition() {
        let tracker = InventoryTracker(library: IconLibrary(entries: []))
        let slots = tracker.update(snapshot([3: (icon(5), .epic)], selected: 3), prompt: nil, readout: (5, 28),
                                   counts: [:], reserves: [0: 822, 1: 1042, 2: 28, 3: 95], time: 0)
        #expect(slots[2].itemID == "sniper:epic" && slots[2].confidence >= 0.98 && slots[2].ammo == 5)
    }

    /// The same icon as drawn on a selected tile: larger, with a highlight, so its outline matches only partly.
    func highlighted(_ base: IconFingerprint, _ seed: Int = 50) -> IconFingerprint {
        let other = icon(seed)
        var outline = zip(base.outline, other.outline).map { 0.55 * $0 + 0.45 * $1 }
        let norm = outline.reduce(0) { $0 + $1 * $1 }.squareRoot(); outline = outline.map { $0 / norm }
        return IconFingerprint(outline: outline, colors: base.colors)
    }
    let smallShield = ItemIdentity(kind: .healing, healID: "small_shield", name: "Small Shield")

    @Test func testSelectionHighlightKeepsTheSlotIdentityAndTeachesNothing() {
        let plain = icon(3, hue: 7), lit = highlighted(plain)
        #expect(plain.shapeSimilarity(lit) >= InventoryTracker.reselectedShape && plain.shapeSimilarity(lit) < 0.9)
        // A polluted library: the selected potion was once learned as a grenade.
        let library = IconLibrary(entries: [IconEntry(identity: smallShield, fingerprint: plain, samples: 3),
                                            IconEntry(identity: ItemIdentity(kind: .throwable, name: "Frag Grenade"), fingerprint: lit, samples: 1)])
        let tracker = InventoryTracker(library: library)
        let unselected = tracker.update(snapshot([3: (plain, nil)], selected: 2), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0)
        #expect(unselected[2].itemID == "small_shield")
        let selected = tracker.update(snapshot([3: (lit, nil)], selected: 3), prompt: m4, readout: nil, counts: [:], reserves: [:], time: 0.2)
        #expect(selected[2].itemID == "small_shield") // Not a grenade, and not the M4 on the ground.
        let back = tracker.update(snapshot([3: (plain, nil)], selected: 2), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.4)
        #expect(back[2].itemID == "small_shield")
        _ = tracker.update(snapshot([3: (plain, nil)], selected: 2), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 1.2)
        #expect(library.entries.count == 2 && tracker.learned.isEmpty)
        // An unknown item that only gains the selection right after a prompt is not named by that prompt either.
        let fresh = InventoryTracker(library: IconLibrary(entries: []))
        _ = fresh.update(snapshot([4: (icon(8), nil)], selected: 2), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0)
        let named = fresh.update(snapshot([4: (highlighted(icon(8)), nil)], selected: 4), prompt: m4, readout: nil, counts: [:], reserves: [:], time: 0.2)
        _ = fresh.update(snapshot([4: (highlighted(icon(8)), nil)], selected: 4), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.9)
        #expect(named[3].itemID == nil && fresh.learned.isEmpty)
    }

    @Test func testAmmunitionReadoutOverrulesAConsumableOnTheSelectedSlot() {
        let gun = icon(11, hue: 2)
        let library = IconLibrary(entries: [IconEntry(identity: ItemIdentity(kind: .healing, healID: "large_shield", name: "Big Shield"), fingerprint: gun, samples: 1)])
        let tracker = InventoryTracker(library: library)
        let reserves = [0: 822, 1: 1042, 2: 348, 3: 95]
        let first = tracker.update(snapshot([4: (gun, .legendary)], selected: 4), prompt: nil, readout: (6, 348), counts: [:], reserves: reserves, time: 0)
        #expect(first[3].itemID == "large_shield") // One readout is not enough.
        let later = tracker.update(snapshot([4: (gun, .legendary)], selected: 4), prompt: nil, readout: (6, 348), counts: [:], reserves: reserves, time: 0.5)
        #expect(later[3].itemID == "sniper:legendary" && later[3].ammo == 6) // Placed by its ammunition instead.
    }

    @Test func testConsumableHintNamesTheSelectedSlot() {
        let tracker = InventoryTracker(library: IconLibrary(entries: []))
        let unknown = tracker.update(snapshot([3: (icon(4), nil)], selected: 3), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0)
        #expect(unknown[2].itemID == nil)
        let named = tracker.update(snapshot([3: (icon(4), nil)], selected: 3), prompt: nil, readout: nil, counts: [:], reserves: [:], time: 0.1, held: smallShield)
        #expect(named[2].itemID == "small_shield" && tracker.source(of: 3) == .hint)
        // An ammunition readout wins over a stale hint.
        let gun = tracker.update(snapshot([4: (icon(6), .rare)], selected: 4), prompt: nil, readout: (20, 90), counts: [:], reserves: [:], time: 0.2, held: smallShield)
        #expect(gun[3].itemID != "small_shield")
    }

    /// A 200 × 60 image: rows 0–29 the name band, 30–59 the subtitle band, both on a pale floor (luminance about 165).
    func panel(subtitle box: (x: Int, w: Int)?, floor: UInt8 = 165) -> PixelImage {
        let w = 200, h = 60
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            var v = floor
            if let box, y >= 38 && y < 52 && x >= box.x - 3 && x < box.x + box.w + 3 {
                // Light-gray subtitle glyphs with a dark outline, as the game draws them.
                v = (y >= 41 && y < 49 && x >= box.x && x < box.x + box.w) ? 185 : 30
            }
            let i = (y * w + x) * 4; bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return PixelImage(cgImage: context.makeImage()!)!
    }
    @Test func testPaleFloorBehindThePanelIsNotText() {
        let rect = PixelRect(0, 0, 200, 60)
        let empty = panel(subtitle: nil).textMask(rect, columns: 64, rows: 16)
        #expect(empty.allSatisfy { $0 == 0 }) // The floor is as bright as subtitle text, but has no outline.
        let a = panel(subtitle: (20, 60)).textMask(rect, columns: 64, rows: 16)
        let b = panel(subtitle: (110, 60)).textMask(rect, columns: 64, rows: 16)
        #expect(a.contains(1) && textMaskSimilarity(a, b, columns: 64) < 0.2)
        #expect(textMaskSimilarity(a, panel(subtitle: (20, 60), floor: 150).textMask(rect, columns: 64, rows: 16), columns: 64) == 1)
    }

    @Test func testPromptTextMasksIgnoreRowJitterButNotNewText() {
        let columns = 8
        func mask(_ rows: [String]) -> [UInt8] { rows.flatMap { $0.map { $0 == "#" ? UInt8(1) : 0 } } }
        let text = mask(["........", ".##.#...", ".#..##..", "........", "..###...", "........"])
        let lower = mask(["........", "........", ".##.#...", ".#..##..", "........", "..###..."])
        let other = mask(["........", ".#..##..", ".##.#...", "........", "...###..", "........"])
        #expect(textMaskSimilarity(text, text, columns: columns) == 1)
        #expect(textMaskSimilarity(text, lower, columns: columns) == 1)
        #expect(textMaskSimilarity(text, other, columns: columns) < PromptMask.sameText)
        #expect(textMaskSimilarity(mask(["........"]), mask(["........"]), columns: columns) == 1)
        #expect(textMaskSimilarity(text, mask(Array(repeating: "........", count: 6)), columns: columns) == 0)
    }

    @Test func testIconLibraryRefusesToRelabelAKnownIcon() {
        let library = IconLibrary(entries: [])
        #expect(library.learn(ItemIdentity(kind: .weapon, weaponClass: .ar, name: "M4"), icon(1)))
        #expect(!library.learn(ItemIdentity(kind: .weapon, weaponClass: .shotgun, name: "Pump"), icon(1)))
        #expect(library.match(icon(1))?.identity.weaponClass == .ar)
        #expect(library.match(icon(7)) == nil)
    }

    @Test func testIconLibraryLeavesOutAGunNameItCannotTellApart() {
        let m4 = ItemIdentity(kind: .weapon, weaponClass: .ar, name: "M4"), ak = ItemIdentity(kind: .weapon, weaponClass: .ar, name: "AK")
        // Two rifles whose icons match equally well: the class is certain, the gun is not, so it counts as an average rifle.
        let tied = IconLibrary(entries: [IconEntry(identity: m4, fingerprint: icon(1), samples: 1), IconEntry(identity: ak, fingerprint: icon(1), samples: 1)])
        let match = tied.match(icon(1))
        #expect(match?.identity.weaponClass == .ar && match?.identity.name == "")
        #expect(match?.identity.itemID(rarity: .rare) == "ar:rare")
        // The same gun learned under an OCR look-alike spelling is still one gun.
        let cyrillic = ItemIdentity(kind: .weapon, weaponClass: .ar, name: "АК")
        let spelled = IconLibrary(entries: [IconEntry(identity: ak, fingerprint: icon(1), samples: 1), IconEntry(identity: cyrillic, fingerprint: icon(1), samples: 1)])
        #expect(spelled.match(icon(1))?.identity.itemID(rarity: .epic) == "ar:epic:ak")
        // A clear winner keeps its name.
        let clear = IconLibrary(entries: [IconEntry(identity: m4, fingerprint: icon(1), samples: 1), IconEntry(identity: ak, fingerprint: icon(2), samples: 1)])
        #expect(clear.match(icon(1))?.identity.name == "M4")
    }
    @Test func testIconLibraryNeverTakesOneGrenadeForAnother() {
        let rev = ItemIdentity(kind: .throwable, name: "Reverse Impulse"), frag = ItemIdentity(kind: .throwable, name: "Frag Grenade")
        #expect(rev.itemID(rarity: nil) == "reverse_impulse_grenade" && frag.itemID(rarity: nil) == "frag_grenade")
        // Two grenades whose icons match equally well: a throwable, but not which one, so it is never thrown.
        let tied = IconLibrary(entries: [IconEntry(identity: rev, fingerprint: icon(1), samples: 1), IconEntry(identity: frag, fingerprint: icon(1), samples: 1)])
        let match = tied.match(icon(1))
        #expect(match?.identity.kind == .throwable && match?.identity.name == "")
        #expect(match?.identity.itemID(rarity: nil) == ItemCatalog.throwableID)
        // Nor is one grenade's icon learned under another grenade's name.
        let library = IconLibrary(entries: [IconEntry(identity: frag, fingerprint: icon(1), samples: 1)])
        #expect(!library.learn(rev, icon(1)))
        #expect(library.match(icon(1))?.identity.name == "Frag Grenade")
    }
}
