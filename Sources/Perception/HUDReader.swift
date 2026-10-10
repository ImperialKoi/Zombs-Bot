import CoreGraphics
import Foundation
import AssistantCore

/// A color-independent icon description: where the dark outlines are, plus the icon's colors.
public struct IconFingerprint: Codable, Equatable, Sendable {
    /// 16×16 outline density, L2-normalized.
    public var outline: [Float]
    /// Hue histogram of the icon's colored pixels (12 hues, white, gray), L1-normalized.
    public var colors: [Float]
    public init(outline: [Float], colors: [Float]) { self.outline = outline; self.colors = colors }
    public static let gridSize = 16
    /// Outline shape only: weapons keep their outline across rarities.
    public func shapeSimilarity(_ other: IconFingerprint) -> Double {
        guard outline.count == other.outline.count else { return 0 }
        var dot: Float = 0
        for i in outline.indices { dot += outline[i] * other.outline[i] }
        return Double(dot)
    }
    public func colorSimilarity(_ other: IconFingerprint) -> Double {
        guard colors.count == other.colors.count else { return 0 }
        var overlap: Float = 0
        for i in colors.indices { overlap += min(colors[i], other.colors[i]) }
        return Double(overlap)
    }
}

public struct SlotReading: Equatable, Sendable {
    public var index: Int
    public var occupied: Bool
    public var tile: RGB?
    /// nil for light-gray tiles: melee, consumables, throwables and common weapons.
    public var rarity: Rarity?
    public var lightTile: Bool
    public var selectionScore: Double
    public var icon: IconFingerprint?
    /// Fingerprint of the printed count, to notice when it changes.
    public var number: [UInt8]
}

public struct HUDSnapshot: Sendable {
    public var layout: HUDLayout
    public var alive: Bool
    public var health: Double?
    public var shield: Double?
    public var vitalsConfidence: Double
    public var slots: [SlotReading]
    public var selectedSlot: Int?
    public var selectedConfidence: Double
    public var promptVisible: Bool
    /// Where the panel was found: its expected place, shifted vertically when the game area is cropped slightly off.
    public var promptRect: PixelRect?
    public var promptFingerprint: [UInt8]
    public var readoutFingerprint: [UInt8]
    public var reserveFingerprints: [[UInt8]]
    /// Teammate roster rows showing a health bar.
    public var rosterRows: Int
}

/// Per-frame pixel measurements of the HUD. No text recognition happens here.
public enum HUDReader {
    public static func read(_ image: PixelImage, layout: HUDLayout) -> HUDSnapshot {
        let alive = layout.anchorVisible(in: image)
        var snapshot = HUDSnapshot(layout: layout, alive: alive, health: nil, shield: nil, vitalsConfidence: 0, slots: [],
                                   selectedSlot: nil, selectedConfidence: 0, promptVisible: false, promptRect: nil, promptFingerprint: [],
                                   readoutFingerprint: [], reserveFingerprints: [], rosterRows: 0)
        guard alive else { return snapshot }
        let health = bar(image, layout: layout, rows: layout.healthRows)
        let shield = bar(image, layout: layout, rows: layout.shieldRows)
        snapshot.health = health?.value; snapshot.shield = shield?.value
        snapshot.vitalsConfidence = (health?.consistent == true && shield?.consistent == true) ? 1 : 0
        snapshot.slots = (1...6).map { slot(image, layout: layout, index: $0) }
        let ranked = snapshot.slots.sorted { $0.selectionScore > $1.selectionScore }
        if let best = ranked.first, best.selectionScore >= 0.7, ranked.dropFirst().allSatisfy({ $0.selectionScore <= best.selectionScore - 0.35 }) {
            snapshot.selectedSlot = best.index; snapshot.selectedConfidence = 1
        }
        if let shift = promptShift(image, layout: layout) {
            snapshot.promptVisible = true
            snapshot.promptRect = PixelRect(layout.prompt.x, layout.prompt.y + shift, layout.prompt.width, layout.prompt.height)
            let text = layout.promptText
            snapshot.promptFingerprint = image.fingerprint(PixelRect(text.x, text.y + shift, text.width, text.height), columns: 24, rows: 6)
        }
        snapshot.readoutFingerprint = image.fingerprint(layout.readout, columns: 20, rows: 4)
        snapshot.reserveFingerprints = (0..<4).map { image.fingerprint(layout.reserveCounter($0), columns: 8, rows: 3) }
        snapshot.rosterRows = rosterRows(image, layout: layout)
        return snapshot
    }

    // MARK: Vitals

    /// Fill colors: green or red/salmon health, purple shield. The unfilled track is the darkened map.
    @inline(__always) static func isFill(_ c: RGB) -> Bool { c.saturation >= 60 && c.maxChannel >= 150 }

    /// Fill length along each sampled row, below the label text. The fill starts at the track's
    /// left edge; the map beside the bar can share its color, so the edge is anchored, not searched.
    static func bar(_ image: PixelImage, layout: HUDLayout, rows: [Double]) -> (value: Double, consistent: Bool)? {
        var values: [Double] = []
        let u = layout.unit
        let probe = Int(0.45 * u), floor = Int(0.385 * u)
        for y in rows.map({ Int($0) }) where y > 0 && y < image.height {
            let reference = image.pixel(probe, y)
            guard isFill(reference) else { values.append(0); continue }
            var left = probe
            while left - 1 >= floor && image.pixel(left - 1, y).distance(reference) <= 30 { left -= 1 }
            var end = probe, gap = 0, x = probe
            let limit = min(image.width - 1, left + Int(layout.barLength * 1.04))
            while x < limit {
                x += 1
                if image.pixel(x, y).distance(reference) <= 30 { end = x; gap = 0 } else { gap += 1; if gap > 3 { break } }
            }
            values.append(min(100, max(0, Double(end - left + 1) / layout.barLength * 100)))
        }
        guard values.count >= 3 else { return nil }
        // Rows near the label text can break early; the middle readings must agree.
        let sorted = values.sorted(), middle = sorted[sorted.count / 2]
        let agreeing = values.filter { abs($0 - middle) <= 2.5 }.count
        // Full and empty bars read to within a point; report them exactly so a full bar never looks hurt.
        let snapped = middle >= 98.5 ? 100 : middle <= 1.5 ? 0 : middle
        return (snapped, agreeing * 2 > values.count)
    }

    // MARK: Inventory

    enum TileClass: Equatable { case light, rarity(Rarity) }

    static func hue(_ c: RGB) -> Double {
        let maxC = Double(c.maxChannel), minC = Double(min(c.r, c.g, c.b)), d = maxC - minC
        guard d > 0 else { return 0 }
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        var h: Double
        if maxC == r { h = 60 * ((g - b) / d) } else if maxC == g { h = 60 * ((b - r) / d) + 120 } else { h = 60 * ((r - g) / d) + 240 }
        if h < 0 { h += 360 }
        return h
    }
    /// Opaque tile colors: light gray, or the rarity hue.
    static func classify(_ c: RGB) -> TileClass? {
        if c.distance(HUDGeometry.tileColor) <= 22 { return .light }
        // The same gray, dimmed while the slot is hovered or the item cannot be used.
        if c.saturation <= 25 && c.distance(RGB(172, 174, 161)) <= 18 { return .light }
        guard c.maxChannel >= 150, c.saturation >= 80 else { return nil }
        switch hue(c) {
        case 345..., ..<20: return .rarity(.mythic)
        case 30..<70: return .rarity(.legendary)
        case 80..<150: return .rarity(.uncommon)
        case 180..<235: return .rarity(.rare)
        case 245..<300: return .rarity(.epic)
        default: return nil
        }
    }

    static func slot(_ image: PixelImage, layout: HUDLayout, index: Int) -> SlotReading {
        let s = layout.slot(index), u = layout.unit
        var reading = SlotReading(index: index, occupied: false, tile: nil, rarity: nil, lightTile: false, selectionScore: 0, icon: nil, number: [])
        // Corner patches, away from the lock (top left of slot 1) and the count (bottom right).
        var votes: [(TileClass, RGB)] = []
        for (fx, fy) in [(0.86, 0.12), (0.12, 0.88), (0.86, 0.5), (0.12, 0.5)] where !(index == 1 && fx < 0.5 && fy < 0.3) {
            var samples: [RGB] = []
            for dy in -1...1 { for dx in -1...1 {
                samples.append(image.pixel(s.minX + (fx + Double(dx) * 0.025) * u, s.minY + (fy + Double(dy) * 0.025) * u))
            } }
            let median = RGB(samples.map(\.r).sorted()[4], samples.map(\.g).sorted()[4], samples.map(\.b).sorted()[4])
            guard samples.filter({ $0.distance(median) <= 24 }).count >= 7, let kind = classify(median) else { continue }
            votes.append((kind, median))
        }
        guard let (kind, color) = votes.first(where: { vote in votes.filter { $0.0 == vote.0 }.count >= 2 }) else { return reading }
        let icon = iconFingerprint(image, slot: s, unit: u, tile: color, index: index)
        guard icon.darkFraction >= 0.012 else { return reading }
        reading.occupied = true; reading.tile = color; reading.icon = icon.fingerprint
        if case .rarity(let r) = kind { reading.rarity = r } else { reading.lightTile = true }
        reading.selectionScore = selectionScore(image, slot: s, unit: u, border: color.lightened(0.75))
        reading.number = image.fingerprint(layout.slotNumber(index), columns: 10, rows: 4)
        return reading
    }

    /// The selected slot has a thin border just outside the tile: the tile color lightened about 75% toward white.
    /// A light map behind the HUD can match that color, but not as a thin band.
    static func selectionScore(_ image: PixelImage, slot s: PixelRect, unit u: Double, border: RGB) -> Double {
        var hits = 0, total = 0
        func sample(_ side: Int, _ t: Double, _ d: Double) -> RGB {
            switch side {
            case 0: return image.pixel(s.minX + t * u, s.minY - d * u)
            case 1: return image.pixel(s.minX + t * u, s.maxY + d * u)
            case 2: return image.pixel(s.minX - d * u, s.minY + t * u)
            default: return image.pixel(s.maxX + d * u, s.minY + t * u)
            }
        }
        for t in stride(from: 0.2, through: 0.8, by: 0.1) {
            for side in 0..<4 {
                total += 1
                // Real borders match the prediction within a few levels; snow and pale floors do not.
                let inner = [0.012, 0.022, 0.032].contains { sample(side, t, $0).distance(border) <= 12 }
                let beyond = sample(side, t, 0.08).distance(border) <= 14
                if inner && !beyond { hits += 1 }
            }
        }
        return Double(hits) / Double(total)
    }

    static func iconFingerprint(_ image: PixelImage, slot s: PixelRect, unit u: Double, tile: RGB, index: Int) -> (fingerprint: IconFingerprint, darkFraction: Double) {
        let n = IconFingerprint.gridSize, sub = 4
        var outline = [Float](repeating: 0, count: n * n), colors = [Float](repeating: 0, count: 14)
        var dark = 0, samples = 0
        let span = 0.8 * u, origin = 0.1 * u
        for row in 0..<n { for column in 0..<n {
            let fx = Double(column) / Double(n), fy = Double(row) / Double(n)
            // Skip the printed count and slot 1's lock; neither belongs to the item's icon.
            if fx >= 0.5 && fy >= 0.62 { continue }
            if index == 1 && fx < 0.2 && fy < 0.2 { continue }
            var cellDark = 0
            for sy in 0..<sub { for sx in 0..<sub {
                let x = s.minX + origin + span * (Double(column) + (Double(sx) + 0.5) / Double(sub)) / Double(n)
                let y = s.minY + origin + span * (Double(row) + (Double(sy) + 0.5) / Double(sub)) / Double(n)
                let c = image.pixel(x, y)
                samples += 1
                if c.maxChannel <= 80 { cellDark += 1; continue }
                guard c.distance(tile) > 30 else { continue }
                if c.saturation < 35 { colors[c.luminance >= 200 ? 12 : 13] += 1 }
                else { colors[min(11, Int(hue(c) / 30))] += 1 }
            } }
            dark += cellDark
            outline[row * n + column] = Float(cellDark) / Float(sub * sub)
        } }
        let norm = outline.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { outline = outline.map { $0 / norm } }
        let total = colors.reduce(0, +)
        if total > 0 { colors = colors.map { $0 / total } }
        return (IconFingerprint(outline: outline, colors: colors), samples > 0 ? Double(dark) / Double(samples) : 0)
    }

    // MARK: Prompt and roster

    /// The interaction panel darkens what is behind it to about 0.68 of its brightness. It sits a fixed
    /// distance below the game's center, so a game area cropped a few points off moves it; search nearby.
    static func promptShift(_ image: PixelImage, layout: HUDLayout) -> Double? {
        let u = layout.unit, p = layout.prompt
        let x0 = p.minX + 0.02 * u, x1 = layout.promptKey.minX - 0.08 * u
        func score(_ shift: Double) -> Int {
            var dark = 0
            for (inside, outside) in [(p.minY + shift + 0.05 * u, p.minY + shift - 0.07 * u), (p.maxY + shift - 0.05 * u, p.maxY + shift + 0.07 * u)] {
                for t in stride(from: 0.05, through: 0.95, by: 0.06) {
                    let x = x0 + (x1 - x0) * t
                    let ratio = Double(image.pixel(x, inside).luminance + 1) / Double(image.pixel(x, outside).luminance + 1)
                    if (0.4...0.85).contains(ratio) { dark += 1 }
                }
            }
            return dark
        }
        let total = 2 * Int((0.95 - 0.05) / 0.06 + 1)
        if score(0) * 4 >= total * 3 { return 0 }
        var best: (shift: Double, score: Int) = (0, 0)
        for shift in stride(from: -0.3 * u, through: 0.3 * u, by: max(1, 0.02 * u)) {
            let s = score(shift)
            if s > best.score { best = (shift, s) }
        }
        return best.score * 4 >= total * 3 ? best.shift : nil
    }

    /// Roster rows above your name show each teammate's small health bar: a thin colored band starting at
    /// the roster's left edge. Returns the highest row with a bar, so a dead teammate's gray row below a
    /// living one is still covered. Map objects behind the HUD are thick, so they fail the thinness test.
    static func rosterRows(_ image: PixelImage, layout: HUDLayout) -> Int {
        var rows = 0
        let u = layout.unit
        for row in 0..<3 {
            let y = layout.rosterHealthRow(row)
            guard y > 0.1 * u, y < Double(image.height) - 0.1 * u else { continue }
            let reference = image.pixel(0.47 * u, y)
            guard isFill(reference) else { continue }
            var left = 0.47 * u
            while left - 1 >= 0.33 * u && image.pixel(left - 1, y).distance(reference) <= 30 { left -= 1 }
            guard left <= 0.43 * u else { continue }
            var run = 0, thin = 0, samples = 0
            for x in stride(from: left, to: left + 0.6 * u, by: max(1, u / 60)) {
                samples += 1
                guard image.pixel(x, y).distance(reference) <= 30 else { continue }
                run += 1
                if image.pixel(x, y - 0.17 * u).distance(reference) > 30 && image.pixel(x, y + 0.17 * u).distance(reference) > 30 { thin += 1 }
            }
            if run * 10 >= samples * 6 && thin * 10 >= run * 8 { rows = row + 1 }
        }
        return rows
    }
}
