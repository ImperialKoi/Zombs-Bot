import CoreGraphics
import CoreImage
import Foundation
import AssistantCore

public struct PerceptionSettings: Sendable {
    public var mode: GameMode
    /// The interact key's name as printed in the prompt's key box.
    public var interactKey: String
    public var catalog: ItemCatalog
    public init(mode: GameMode = .solo, interactKey: String = "E", catalog: ItemCatalog = .standard) {
        self.mode = mode; self.interactKey = interactKey; self.catalog = catalog
    }
}

public struct PerceptionResult {
    public var observation: Observation
    public var detections: [Detection]
    public var hud: HUDSnapshot?
    public var promptLines: [String]
    public var readoutText: String?
    public var roster: [String]
    /// A valid detector is loaded. Outside a live match the coordinator still halts on the phase.
    public var recognitionReady: Bool
    public var problems: [String]
    public var hudMilliseconds: Double
    public var detectorMilliseconds: Double
    /// The frame as the detector saw it, when it ran on this frame; a cheap source for previews.
    public var detectorInput: ModelInput?
}

/// Turns one viewport frame into an observation. HUD values come from pixels; text is read
/// asynchronously and used only while it still matches the pixels on screen.
public final class PerceptionEngine {
    public let detector: SceneDetector?
    public let detectorProblem: String?
    public let text: TextReader
    public let inventory: InventoryTracker
    public var settings: PerceptionSettings
    public private(set) var layout: HUDLayout?
    private let tracker = SceneTracker()
    private var affiliation = AffiliationTracker()
    private var lastLayoutSearch = -Double.infinity
    private var lastAlive = -Double.infinity
    private var roster: [String] = []
    /// The roster names by row, where text recognition placed them, to find each teammate's health bar.
    private var rosterNames: [Int: String] = [:]
    /// When each roster row last showed a knocked-down teammate. A revive starting flashes their bar green for a frame.
    private var rosterDownAt: [Int: Double] = [:]
    /// A teammate counts as down until their bar has shown them up this long.
    static let reviveSettle = 1.0
    private var lastRosterRead = -Double.infinity
    private var promptPanel: (fingerprint: [UInt8], since: Double)?
    private var lastTagRead: [Int: Double] = [:]
    private var lastTagRequest: [Int: Double] = [:]
    private var lastSelection: (slot: Int, time: Double)?
    /// Since when a teammate roster has been visible without a break, to warn when Solo is selected.
    private var rosterSince: Double?

    public init(artifacts: URL?, settings: PerceptionSettings, library: IconLibrary, text: TextReader) {
        self.settings = settings; self.text = text
        inventory = InventoryTracker(library: library, catalog: settings.catalog)
        if let artifacts {
            do { detector = try SceneDetector(artifacts: artifacts); detectorProblem = nil }
            catch { detector = nil; detectorProblem = error.localizedDescription }
        } else { detector = nil; detectorProblem = "No detector installed" }
    }

    public func reset() {
        tracker.reset(); affiliation.reset(); inventory.reset(); text.reset()
        promptPanel = nil; lastTagRead = [:]; lastTagRequest = [:]; roster = []; rosterNames = [:]; rosterDownAt = [:]; rosterSince = nil
    }

    public func process(image: PixelImage, ciImage: CIImage?, timestamp t: Double) -> PerceptionResult {
        let started = ProcessInfo.processInfo.systemUptime
        var o = Observation(timestamp: t)
        o.mode = settings.mode
        o.aspect = Double(image.width) / Double(image.height)
        var problems: [String] = []
        if let detectorProblem { problems.append(detectorProblem) }

        if layout.map({ $0.width != image.width || $0.height != image.height }) ?? false { layout = nil }
        if layout == nil || !(layout!.anchorVisible(in: image)) && t - lastAlive > 3, text.synchronous || t - lastLayoutSearch >= 0.5 {
            lastLayoutSearch = t
            if let found = HUDLayout.detect(in: image) { layout = found }
        }
        var result = PerceptionResult(observation: o, detections: [], hud: nil, promptLines: [], readoutText: nil, roster: roster,
                                      recognitionReady: detector != nil, problems: problems, hudMilliseconds: 0, detectorMilliseconds: 0)
        guard let layout else {
            result.problems.append("HUD not found: start a match with the inventory visible")
            return result
        }
        var hud = HUDReader.read(image, layout: layout)
        for i in hud.roster.indices {
            let row = hud.roster[i].row
            if hud.roster[i].down { rosterDownAt[row] = t } else if t - (rosterDownAt[row] ?? -.infinity) < Self.reviveSettle { hud.roster[i].down = true }
        }
        result.hud = hud
        if hud.alive { lastAlive = t }
        let alive = t - lastAlive <= 0.3
        if !alive { promptPanel = nil }
        if !alive && t - lastAlive > 10 { roster = []; rosterNames = [:]; rosterDownAt = [:] } // A new match starts over.
        // Solo means solo: every other player is an enemy and no name tags are read. Map details behind the HUD look
        // like a teammate roster in about one solo frame in 200, for up to a second, which used to switch team rules on.
        o.teamMode = settings.mode != .solo
        rosterSince = hud.rosterRows > 0 ? (rosterSince ?? t) : nil
        if !o.teamMode, let since = rosterSince, t - since >= 2 {
            result.problems.append("Solo is selected, but a teammate roster is showing: every player is treated as an enemy. Choose Duo or Squad in Settings if you have teammates.")
        }
        if alive {
            o.phase = .alive; o.phaseConfidence = 1; o.playerConfidence = 1
            o.hudAreas = layout.noClick(rosterRows: hud.rosterRows).map(layout.normalized)
            o.health = hud.health; o.shield = hud.shield; o.hudConfidence = hud.vitalsConfidence
            o.selectedSlot = hud.selectedSlot; o.selectedSlotConfidence = hud.selectedConfidence
        } else {
            o.phase = .unknown
        }

        // Text: requested when its pixels change, used only while they still match. The prompt is matched by its text
        // mask, which the map scrolling behind the translucent panel does not change, so walking keeps the read valid.
        var prompt: InteractionPrompt?
        var held: ItemIdentity?
        if alive && hud.promptVisible {
            if promptPanel.map({ !PromptMask.matches($0.fingerprint, hud.promptFingerprint) }) ?? true {
                promptPanel = (hud.promptFingerprint, t)
            }
            let panel = hud.promptRect ?? layout.prompt
            // Read again whenever the text looks even slightly different, so a changed rarity word is not missed.
            text.request(.prompt, fingerprint: hud.promptFingerprint, time: t,
                         fresh: { textMaskSimilarity($0, $1, columns: PromptMask.columns) >= 0.95 }, retryEmpty: 1) { image.cgImage(panel) }
            if let read = text.current(.prompt, fingerprint: hud.promptFingerprint, matches: PromptMask.matches) {
                result.promptLines = read.lines.map(\.text)
                if let id = HUDText.heldConsumable(lines: result.promptLines, catalog: settings.catalog) {
                    // The panel describes the consumable in your hand; there is nothing to interact with. Only a read of
                    // these very pixels names a slot, never one left over from before a switch.
                    if textMaskSimilarity(read.fingerprint, hud.promptFingerprint, columns: PromptMask.columns) >= 0.95 {
                        o.heldConsumable = id
                        held = ItemIdentity(kind: .healing, healID: id, name: settings.catalog.heal(id: id)?.name ?? id)
                    }
                } else {
                    // Vision rates short words ("M4", "AK") and stray marks lower; judge the read by its words.
                    let words = read.lines.filter { $0.text.filter { $0.isLetter || $0.isNumber }.count >= 3 }
                    prompt = HUDText.prompt(lines: result.promptLines, confidence: words.map(\.confidence).min() ?? read.confidence,
                                            catalog: settings.catalog, key: settings.interactKey)
                    prompt?.stable = t - (promptPanel?.since ?? t) >= 0.15 || text.synchronous
                }
            }
        } else { promptPanel = nil }
        o.prompt = prompt
        o.promptVisible = alive && hud.promptVisible

        var readout: (loaded: Int, reserve: Int)?
        var counts: [Int: Int] = [:], reserves: [Int: Int] = [:]
        if alive {
            text.request(.readout, fingerprint: hud.readoutFingerprint, time: t) { image.cgImage(layout.readout) }
            if let read = text.current(.readout, fingerprint: hud.readoutFingerprint) {
                result.readoutText = read.text
                readout = HUDText.ammunition(read.text) ?? read.lines.lazy.compactMap { HUDText.ammunition($0.text) }.first
                o.gunInHand = readout != nil
            }
            for slot in hud.slots where slot.occupied && slot.index >= 2 {
                text.request(.slot(slot.index), fingerprint: slot.number, time: t) { image.cgImage(layout.slotNumber(slot.index)) }
                if let read = text.current(.slot(slot.index), fingerprint: slot.number) {
                    counts[slot.index] = HUDText.count(read.text.replacingOccurrences(of: " ", with: ""))
                }
            }
            for (index, fingerprint) in hud.reserveFingerprints.enumerated() {
                text.request(.reserve(index), fingerprint: fingerprint, time: t) { image.cgImage(layout.reserveCounter(index)) }
                if let read = text.current(.reserve(index), fingerprint: fingerprint), let value = HUDText.count(read.text) { reserves[index] = value }
            }
            if o.teamMode && (t - lastRosterRead >= 3 || roster.isEmpty && t - lastRosterRead >= 0.5) && hud.rosterRows > 0 {
                lastRosterRead = t
                text.request(.roster, fingerprint: image.fingerprint(layout.roster, columns: 16, rows: 6), time: t) { image.cgImage(layout.roster) }
            }
            if let read = text.result(.roster) {
                let lines = read.lines.map { ($0, $0.text.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)) }
                    .filter { HUDText.nameKey($0.1).count >= 3 }
                if !lines.isEmpty {
                    roster = lines.map(\.1)
                    // Each name's row, from where it was printed in the region read.
                    let region = layout.roster
                    var named: [Int: String] = [:]
                    for (line, name) in lines {
                        if let row = layout.rosterRow(nameAt: region.y + Double(line.box.midY) * region.height) { named[row] = name }
                    }
                    rosterNames = named
                }
            }
            if o.teamMode {
                o.squad = hud.roster.map { TeammateStatus(name: rosterNames[$0.row], down: $0.down, health: $0.health, shield: $0.shield) }
            }
            var resolved = hud
            if let slot = resolveSelection(hud, readout: readout, counts: counts, time: t) {
                resolved.selectedSlot = slot; resolved.selectedConfidence = 1
            }
            o.selectedSlot = resolved.selectedSlot; o.selectedSlotConfidence = resolved.selectedConfidence
            o.inventory = inventory.update(resolved, prompt: prompt, readout: readout, counts: counts, reserves: reserves, time: t, held: held,
                                           gunInHand: o.gunInHand)
        }
        result.roster = roster
        result.hudMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000

        // Scene objects.
        let detectStart = ProcessInfo.processInfo.systemUptime
        var detections: [Detection] = []
        if let detector, let ciImage, alive {
            do {
                let exclusions = layout.exclusions(rosterRows: hud.rosterRows, prompt: hud.promptRect).map(layout.normalized)
                let raw = try detector.predict(ciImage).filter { d in !exclusions.contains { $0.contains(d.bounds.center) } }
                result.detectorInput = detector.lastInput
                detections = tracker.update(Self.mergingDuplicatePlayers(Self.excludingYourself(raw, aspect: o.aspect)), at: t, aspect: o.aspect)
                o.sceneryShift = tracker.shift; o.ownVelocity = tracker.ownVelocity
            } catch {
                o.captureHealthy = false; result.problems.append(error.localizedDescription)
            }
        }
        result.detectorMilliseconds = (ProcessInfo.processInfo.systemUptime - detectStart) * 1000
        for d in detections {
            switch d.label {
            case "player":
                var player = PlayerTrack(id: d.id, position: d.bounds.center, velocity: d.velocity, confidence: d.confidence,
                                         affiliationConfidence: 0, motion: d.motion, confirmed: d.confirmed, predicted: d.predicted)
                if !o.teamMode { player.affiliation = .enemy; player.affiliationConfidence = 1 }
                else {
                    if !d.predicted { readNameTag(of: d, image: image, layout: layout, time: t) }
                    (player.affiliation, player.affiliationConfidence) = affiliation.affiliation(track: d.id, time: t)
                    // A teammate's health and shield come from the roster row with their name; a single row is theirs.
                    if let name = affiliation.name(track: d.id, time: t) {
                        player.name = name
                        let named = rosterNames.filter { HUDText.nameSimilarity($0.value, name) >= AffiliationTracker.teammateSimilarity }
                            .max { HUDText.nameSimilarity($0.value, name) < HUDText.nameSimilarity($1.value, name) }?.key
                        if let row = named ?? (hud.rosterRows == 1 ? 0 : nil), let vitals = hud.roster.first(where: { $0.row == row }), !vitals.down {
                            player.health = vitals.health; player.shield = vitals.shield
                        }
                    }
                }
                o.players.append(player)
            case "wall","rock","tree","door","chest","revive_target":
                let kind = ObstacleKind(rawValue: d.label) ?? .reviveTarget
                o.obstacles.append(Obstacle(kind, bounds: d.bounds, confidence: d.confidence, maskCells: d.maskCells))
            default: break
            }
        }
        suppressDecorations(&o)
        affiliation.prune(keeping: Set(o.players.map(\.id)), time: t)
        result.observation = o
        result.detections = detections
        result.recognitionReady = detector != nil && o.captureHealthy
        return result
    }

    /// You are always at the center; any other character is another player, whatever the model called it.
    static func excludingYourself(_ detections: [Detection], aspect: Double) -> [Detection] {
        let center = Point(0.5, 0.5)
        return detections.compactMap { d in
            // A wall, door or chest cannot be where you stand: one centered on you is your character misread,
            // and it would block every shot (about one frame in eight on recorded matches).
            if ["wall", "door", "chest"].contains(d.label) { return d.bounds.center.distance(to: center, aspect: aspect) <= 0.02 ? nil : d }
            guard d.label == "player" || d.label == "self_player" else { return d }
            if d.bounds.center.distance(to: center, aspect: aspect) <= 0.03 { return nil }
            var other = d; other.label = "player"; return other
        }
    }

    /// The detector can report one person as both `player` and `self_player`; once both are players, the
    /// weaker box would become a second, unconfirmed player standing in the line of fire.
    static func mergingDuplicatePlayers(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if d.label == "player" && kept.contains(where: { $0.label == "player" && SceneDetector.iou($0.bounds, d.bounds) > 0.5 }) { continue }
            kept.append(d)
        }
        return kept
    }

    /// Some maps place rows of character-like props (snowmen) that the detector takes for players.
    /// Opponents move; props stand still in tight groups. A motionless player with two motionless
    /// players close by is treated as unconfirmed: never a target or threat, though it still blocks the firing line.
    static let decorationRadius = 0.1
    static let decorationSpeed = 0.03
    func suppressDecorations(_ o: inout Observation) {
        func still(_ p: PlayerTrack) -> Bool {
            guard let v = p.motion?.groundVelocity else { return false }
            return Point().distance(to: v, aspect: o.aspect) < Self.decorationSpeed
        }
        let snapshot = o.players
        for i in o.players.indices where still(snapshot[i]) {
            let neighbors = snapshot.filter { $0.id != snapshot[i].id && still($0)
                && $0.position.distance(to: snapshot[i].position, aspect: o.aspect) <= Self.decorationRadius }
            if neighbors.count >= 2 { o.players[i].confirmed = false }
        }
    }

    /// The selection border is faint on snow and pale floors. Fall back to the slot whose printed total
    /// equals the readout's loaded plus reserve rounds, then to a recent confident selection that still
    /// scores highest.
    private func resolveSelection(_ hud: HUDSnapshot, readout: (loaded: Int, reserve: Int)?, counts: [Int: Int], time t: Double) -> Int? {
        if let slot = hud.selectedSlot, hud.selectedConfidence >= 0.98 { lastSelection = (slot, t); return slot }
        if let readout {
            let matches = counts.filter { $0.value == readout.loaded + readout.reserve }.map(\.key)
            if matches.count == 1 { lastSelection = (matches[0], t); return matches[0] }
        }
        let best = hud.slots.max { $0.selectionScore < $1.selectionScore }
        if let last = lastSelection, t - last.time <= 1.5, best?.index == last.slot, (best?.selectionScore ?? 0) >= 0.3 { return last.slot }
        return nil
    }

    /// Teammates show their roster name above their head. Reads are rate-limited per track.
    private func readNameTag(of d: Detection, image: PixelImage, layout: HUDLayout, time t: Double) {
        let id = d.id
        if let read = text.result(.nameTag(id)), read.time > (lastTagRead[id] ?? -.infinity) {
            lastTagRead[id] = read.time
            let legible = read.lines.filter { $0.confidence >= 0.3 && HUDText.nameKey($0.text).count >= 3 }
            if let best = legible.max(by: { $0.confidence < $1.confidence }) {
                affiliation.record(track: id, read: .text(best.text, best.confidence), roster: roster, time: t)
            } else {
                affiliation.record(track: id, read: .nothing(colored: coloredTag(above: d, image: image, layout: layout)), roster: roster, time: t)
            }
        }
        guard affiliation.needsRead(track: id, time: t), t - (lastTagRequest[id] ?? -.infinity) >= 0.35 else { return }
        lastTagRequest[id] = t
        let region = tagRegion(above: d, image: image, layout: layout)
        text.request(.nameTag(id), fingerprint: image.fingerprint(region, columns: 12, rows: 3) + [UInt8(truncatingIfNeeded: Int(t * 10))], time: t) {
            image.cgImage(region)
        }
    }

    func tagRegion(above d: Detection, image: PixelImage, layout: HUDLayout) -> PixelRect {
        let u = layout.unit
        let x: Double = d.bounds.center.x * Double(image.width), top: Double = d.bounds.y * Double(image.height)
        return PixelRect(x - 1.8 * u, top - 1.0 * u, 3.6 * u, 0.95 * u)
    }

    /// Saturated, bright text pixels where a teammate's colored name would be.
    func coloredTag(above d: Detection, image: PixelImage, layout: HUDLayout) -> Bool {
        let r = tagRegion(above: d, image: image, layout: layout)
        var colored = 0, total = 0
        for y in stride(from: r.minY, to: r.maxY, by: max(1, layout.unit / 40)) {
            for x in stride(from: r.minX, to: r.maxX, by: max(1, layout.unit / 40)) {
                total += 1
                let c = image.pixel(x, y)
                if c.saturation >= 100 && c.maxChannel >= 150 { colored += 1 }
            }
        }
        return total > 0 && colored * 200 >= total
    }
}
