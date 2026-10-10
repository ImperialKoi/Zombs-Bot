import Foundation
import AssistantCore

/// HUD offsets in units of the inventory tile size, measured on 3840×1736 and 2880×1376 recordings.
/// The HUD scales with √(width × height) and is anchored to the viewport corners.
enum HUDGeometry {
    static let unitPerRootArea = 0.0553
    static let rightMargin = 0.373
    /// From slot 1's left edge to the viewport's right edge.
    static let inventorySpan = 6.83
    static let bottomMargin = 0.675
    static let pitchRange = 1.06...1.13
    static let healthRow = 0.48, healthSpread = 0.02
    static let shieldRow = 1.0, shieldSpread = 0.012
    static let barStart = 0.30...0.56
    static let barLength = 4.36
    static let readoutX = 2.9...4.5, readoutFromBottom = 1.38...1.80
    static let promptX = -1.70...1.70, promptTextX = -1.62...1.05, promptY = 2.01...2.81
    static let keyX = 1.16...1.66
    static let reservePitch = 1.204, reserveAboveSlots = 0.20...0.63
    static let rosterPitch = 0.945, rosterNameFromBottom = 2.72...3.06, rosterHealthFromBottom = 2.36
    static let tileColor = RGB(205, 207, 194)
}

/// Pixel geometry of the HUD for one viewport size.
public struct HUDLayout: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Inventory tile size in pixels; every HUD offset scales with it.
    public var unit: Double
    /// Top-left corner of slot 1, which always holds your melee weapon.
    public var originX: Double
    public var originY: Double
    public var pitch: Double

    public init(width: Int, height: Int, unit: Double, originX: Double, originY: Double, pitch: Double) {
        self.width = width; self.height = height; self.unit = unit; self.originX = originX; self.originY = originY; self.pitch = pitch
    }
    var W: Double { Double(width) }
    var H: Double { Double(height) }

    public func slot(_ index: Int) -> PixelRect {
        PixelRect(originX + Double(index - 1) * pitch, originY, unit, unit)
    }
    /// The printed count at a slot's bottom right.
    public func slotNumber(_ index: Int) -> PixelRect {
        let s = slot(index)
        return PixelRect(s.x + 0.45 * unit, s.y + 0.62 * unit, 0.53 * unit, 0.35 * unit)
    }
    public var healthRows: [Double] {
        let y: Double = H - HUDGeometry.healthRow * unit
        let d: Double = HUDGeometry.healthSpread * unit
        return [y - d, y - d / 2, y, y + d / 2, y + d]
    }
    public var shieldRows: [Double] {
        let y: Double = H - HUDGeometry.shieldRow * unit
        let d: Double = HUDGeometry.shieldSpread * unit
        return [y - d, y - d / 2, y, y + d / 2, y + d]
    }
    public var barStart: ClosedRange<Double> { (HUDGeometry.barStart.lowerBound * unit)...(HUDGeometry.barStart.upperBound * unit) }
    public var barLength: Double { HUDGeometry.barLength * unit }
    /// The selected weapon's "loaded / reserve" readout.
    public var readout: PixelRect {
        let x = HUDGeometry.readoutX, y = HUDGeometry.readoutFromBottom
        return PixelRect(x.lowerBound * unit, H - y.upperBound * unit, (x.upperBound - x.lowerBound) * unit, (y.upperBound - y.lowerBound) * unit)
    }
    private func centered(_ x: ClosedRange<Double>, _ y: ClosedRange<Double>) -> PixelRect {
        PixelRect(W / 2 + x.lowerBound * unit, H / 2 + y.lowerBound * unit, (x.upperBound - x.lowerBound) * unit, (y.upperBound - y.lowerBound) * unit)
    }
    /// The interaction panel, including its key box.
    public var prompt: PixelRect { centered(HUDGeometry.promptX, HUDGeometry.promptY) }
    /// The panel's name and subtitle text.
    public var promptText: PixelRect {
        let y = HUDGeometry.promptY
        return centered(HUDGeometry.promptTextX, (y.lowerBound + 0.04)...(y.upperBound - 0.04))
    }
    public var promptKey: PixelRect { centered(HUDGeometry.keyX, HUDGeometry.promptY) }
    /// Reserve counters above the slots: small, medium, large and shotgun ammunition.
    public func reserveCounter(_ index: Int) -> PixelRect {
        let right: Double = slot(6).maxX - Double(3 - index) * HUDGeometry.reservePitch * unit
        let span = HUDGeometry.reserveAboveSlots
        // The count is printed in the right part of each counter.
        return PixelRect(right - 0.62 * unit, originY - span.upperBound * unit, 0.6 * unit, (span.upperBound - span.lowerBound) * unit)
    }
    public func rosterName(_ row: Int) -> PixelRect {
        let span = HUDGeometry.rosterNameFromBottom
        let shift: Double = Double(row) * HUDGeometry.rosterPitch
        return PixelRect(0.5 * unit, H - (span.upperBound + shift) * unit, 2.5 * unit, (span.upperBound - span.lowerBound) * unit)
    }
    public func rosterHealthRow(_ row: Int) -> Double {
        H - (HUDGeometry.rosterHealthFromBottom + Double(row) * HUDGeometry.rosterPitch) * unit
    }
    /// All roster names, for one text read.
    public var roster: PixelRect {
        let top = rosterName(2), bottom = rosterName(0)
        return PixelRect(top.x, top.y, top.width, bottom.maxY - top.y)
    }
    public func normalized(_ r: PixelRect) -> Rect {
        Rect(max(0, r.x / W), max(0, r.y / H), min(1, r.width / W), min(1, r.height / H))
    }
    /// Opaque HUD where detections are ignored.
    public func exclusions(rosterRows: Int, prompt panel: PixelRect?) -> [PixelRect] {
        let u = unit
        var rects = [
            PixelRect(W - 3.0 * u, 0, 3.0 * u, 3.6 * u),                      // Minimap and match stats.
            PixelRect(0, 0, 1.7 * u, 0.8 * u),                                 // Settings, sound, fullscreen.
            PixelRect(0, H - 1.9 * u, 5.0 * u, 1.9 * u),                       // Name, ammunition, vitals.
            PixelRect(originX - 0.15 * u, originY - 0.7 * u, W - originX + 0.15 * u, H - originY + 0.7 * u),
        ]
        if rosterRows > 0 {
            let top: Double = rosterName(rosterRows - 1).y - 0.1 * u
            rects.append(PixelRect(0, top, 3.1 * u, H - top))
        }
        if let panel { rects.append(panel) }
        return rects
    }

    static func isTile(_ c: RGB) -> Bool { c.distance(HUDGeometry.tileColor) <= 17 }
    /// Strict tile color for edges, so blended selection-border pixels do not count.
    static func isTileEdge(_ c: RGB) -> Bool { c.distance(HUDGeometry.tileColor) <= 11 }

    /// Slot 1 holds your melee weapon (fists or a knife skin) and shows a small white lock at its top left.
    static func lockVisible(_ tile: PixelRect, unit u: Double, in image: PixelImage) -> Bool {
        var light = 0, samples = 0
        for fy in stride(from: 0.03, through: 0.22, by: 0.01) { for fx in stride(from: 0.04, through: 0.24, by: 0.01) {
            samples += 1
            let c = image.pixel(tile.x + fx * u, tile.y + fy * u)
            if c.luminance >= 228 && c.saturation <= 30 { light += 1 }
        } }
        return light * 25 >= samples
    }

    /// The melee tile's inner border band, which icons leave uncovered: present whenever the inventory is on screen.
    public func anchorVisible(in image: PixelImage) -> Bool {
        let s = slot(1)
        var hits = 0, total = 0
        for t in stride(from: 0.3, through: 0.8, by: 0.1) {
            for (fx, fy) in [(t, 0.05), (t, 0.95), (0.05, t), (0.95, t)] {
                total += 1
                if Self.isTile(image.pixel(s.x + fx * unit, s.y + fy * unit)) { hits += 1 }
            }
        }
        return hits * 4 >= total * 3
    }

    /// Finds the inventory by its first tile, which always holds your locked melee weapon, and derives the rest of the HUD.
    public static func detect(in image: PixelImage) -> HUDLayout? {
        let W = Double(image.width), H = Double(image.height)
        guard W >= 320, H >= 200 else { return nil }
        let u0: Double = HUDGeometry.unitPerRootArea * (W * H).squareRoot()
        let x0: Double = max(0, W - 10.8 * u0), x1: Double = max(x0 + 1, W - 4.8 * u0)
        let y0: Double = max(0, H - 2.6 * u0), y1: Double = max(y0 + 1, H - 0.25 * u0)
        let step: Double = max(1, (u0 / 36).rounded())
        let columns = Int((x1 - x0) / step), rows = Int((y1 - y0) / step)
        guard columns > 4, rows > 4 else { return nil }
        var mask = [Bool](repeating: false, count: columns * rows)
        for r in 0..<rows { for c in 0..<columns {
            let px: Double = x0 + Double(c) * step, py: Double = y0 + Double(r) * step
            mask[r * columns + c] = isTile(image.pixel(px, py))
        } }
        var seen = [Bool](repeating: false, count: mask.count)
        var candidates: [PixelRect] = []
        let neighbors = [(0, 1), (0, -1), (1, 0), (-1, 0)]
        for start in mask.indices where mask[start] && !seen[start] {
            var stack = [start], count = 0
            var minC = columns, maxC = 0, minR = rows, maxR = 0
            seen[start] = true
            while let i = stack.popLast() {
                count += 1
                let r = i / columns, c = i % columns
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for (dr, dc) in neighbors {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                    let j = nr * columns + nc
                    if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            let bw: Double = Double(maxC - minC + 1) * step, bh: Double = Double(maxR - minR + 1) * step
            let filled: Double = Double(count) * step * step
            guard bw >= 0.7 * u0, bw <= 1.35 * u0, abs(bw - bh) <= 0.15 * bw, filled >= 0.4 * bw * bh else { continue }
            candidates.append(PixelRect(x0 + Double(minC) * step, y0 + Double(minR) * step, bw, bh))
        }
        for box in candidates.sorted(by: { $0.x < $1.x }) {
            guard let tile = refine(box, in: image, step: step) else { continue }
            // The span to the right edge fixes the scale more precisely than one tile's edges,
            // which a selection border can widen by a pixel or two.
            let u: Double = (W - tile.x) / HUDGeometry.inventorySpan
            guard abs(tile.width - u) <= 0.06 * u, abs(tile.height - u) <= 0.08 * u else { continue }
            let pitch: Double = (W - HUDGeometry.rightMargin * u - u - tile.x) / 5
            let expectedTop: Double = H - (HUDGeometry.bottomMargin + 1) * u
            guard HUDGeometry.pitchRange.contains(pitch / u), abs(tile.y - expectedTop) <= 0.2 * u, lockVisible(tile, unit: u, in: image) else { continue }
            let top = abs(tile.y - expectedTop) <= 0.03 * u ? tile.y : expectedTop
            let layout = HUDLayout(width: image.width, height: image.height, unit: u, originX: tile.x, originY: top, pitch: pitch)
            if layout.anchorVisible(in: image) { return layout }
        }
        return nil
    }

    /// Exact tile edges around a coarse box: the outermost rows and columns that are mostly tile color.
    static func refine(_ box: PixelRect, in image: PixelImage, step: Double) -> PixelRect? {
        let rowRange = Int(box.y + 0.25 * box.height)..<Int(box.y + 0.75 * box.height)
        let columnRange = Int(box.x + 0.25 * box.width)..<Int(box.x + 0.75 * box.width)
        func columnFraction(_ x: Int) -> Double {
            var hits = 0, n = 0
            let cx = min(image.width - 1, max(0, x))
            for y in stride(from: rowRange.lowerBound, to: rowRange.upperBound, by: 2) {
                n += 1; if isTileEdge(image.pixel(cx, min(image.height - 1, max(0, y)))) { hits += 1 }
            }
            return n > 0 ? Double(hits) / Double(n) : 0
        }
        func rowFraction(_ y: Int) -> Double {
            var hits = 0, n = 0
            let cy = min(image.height - 1, max(0, y))
            for x in stride(from: columnRange.lowerBound, to: columnRange.upperBound, by: 2) {
                n += 1; if isTileEdge(image.pixel(min(image.width - 1, max(0, x)), cy)) { hits += 1 }
            }
            return n > 0 ? Double(hits) / Double(n) : 0
        }
        // Walk each edge outward while the next line is still tile, then inward past anything that is not.
        let limit = Int(box.width * 0.3) + Int(step) + 3
        var left = Int(box.x), right = Int(box.maxX) - 1, upper = Int(box.y), lower = Int(box.maxY) - 1
        var n = 0
        while n < limit && columnFraction(left - 1) >= 0.35 { left -= 1; n += 1 }
        n = 0; while n < limit && columnFraction(left) < 0.35 { left += 1; n += 1 }
        n = 0; while n < limit && columnFraction(right + 1) >= 0.35 { right += 1; n += 1 }
        n = 0; while n < limit && columnFraction(right) < 0.35 { right -= 1; n += 1 }
        n = 0; while n < limit && rowFraction(upper - 1) >= 0.5 { upper -= 1; n += 1 }
        n = 0; while n < limit && rowFraction(upper) < 0.5 { upper += 1; n += 1 }
        n = 0; while n < limit && rowFraction(lower + 1) >= 0.5 { lower += 1; n += 1 }
        n = 0; while n < limit && rowFraction(lower) < 0.5 { lower -= 1; n += 1 }
        guard right > left, lower > upper else { return nil }
        return PixelRect(Double(left), Double(upper), Double(right - left + 1), Double(lower - upper + 1))
    }
}
