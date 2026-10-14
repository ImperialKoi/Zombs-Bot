import Foundation
import AssistantCore

/// Finds rounds in flight on one frame by their look. A round is a small capsule with a dark outline, colored by its
/// ammunition like the reserve counters' icons: a cream tip on a gray case for small rounds (SMGs, pistols), an orange tip
/// on a slim blue case for medium ones (ARs), a cream tip, a green band and a brown case for large ones (snipers, DMRs,
/// bows), and red for shells. A pale trail fades out behind it. On recordings 2,880 and 3,840 pixels wide, rounds are
/// 0.006 to 0.011 view widths long and 1.4 to 4.5 times as long as wide.
///
/// The frame is sampled about 1,920 times across for dark outline pixels. Small outlined shapes of a round's size and
/// proportions are kept when their fill, read at full resolution, matches an ammunition's colors. The tip says which way a
/// round flies; the trail, when it shows, confirms it and tells where it fades out. Look-alikes that stay put or move
/// slowly (ammunition boxes on the ground, names, red flowers) are told apart by `BulletTracker`, which needs a round's
/// speed. On 438 recorded frames, 72 of the 77 shapes with a trail were rounds.
public final class BulletDetector {
    /// Round length and length-to-width ratio, in view widths.
    static let length = 0.0045...0.012, proportions = 1.25...6.0
    /// Outline pixels are darker than this luminance; a round's fill is at least `fillLuminance`.
    static let outline = 80, fillLuminance = 70
    /// Runs of outline samples along a row, joined into outlines by a union-find over their labels.
    private struct Run { var y: Int32; var x0: Int32; var x1: Int32; var label: Int32 }
    private var runs: [Run] = []
    private var parent: [Int32] = []
    private var pixels: [Int32] = []
    public init() {}

    private func root(_ i: Int32) -> Int32 {
        var i = i
        while parent[Int(i)] != i { parent[Int(i)] = parent[Int(parent[Int(i)])]; i = parent[Int(i)] }
        return i
    }

    /// The rounds in `image`, a viewport frame, away from the HUD rectangles in `excluding` (pixels).
    public func detect(_ image: PixelImage, excluding areas: [PixelRect] = []) -> [BulletSighting] {
        let width = image.width, height = image.height
        let s = max(1, Int((Double(width) / 1920).rounded()))
        let gw = width / s, gh = height / s
        guard gw > 8, gh > 8 else { return [] }
        // Outline samples, every `s` pixels, as runs along each row joined to the runs they touch in the row above.
        runs.removeAll(keepingCapacity: true); parent.removeAll(keepingCapacity: true)
        let base = image.base, row = image.bytesPerRow
        let (ri, bi) = image.bgra ? (2, 0) : (0, 2)
        var previous = 0..<0
        for gy in 0..<gh {
            let p = base + gy * s * row
            let first = runs.count
            var start = -1
            for gx in 0...gw {
                var dark = false
                if gx < gw {
                    let q = p + gx * s * 4
                    dark = (Int(q[ri]) * 77 + Int(q[1]) * 150 + Int(q[bi]) * 29) >> 8 < Self.outline
                }
                if dark { if start < 0 { start = gx } }
                else if start >= 0 {
                    let label = Int32(parent.count)
                    parent.append(label)
                    runs.append(Run(y: Int32(gy), x0: Int32(start), x1: Int32(gx - 1), label: label))
                    start = -1
                }
            }
            // Runs overlapping or touching diagonally belong to one outline.
            var k = previous.lowerBound
            for i in first..<runs.count {
                while k < previous.upperBound && runs[k].x1 < runs[i].x0 - 1 { k += 1 }
                var j = k
                while j < previous.upperBound && runs[j].x0 <= runs[i].x1 + 1 {
                    let a = root(runs[i].label), b = root(runs[j].label)
                    if a != b { parent[Int(max(a, b))] = min(a, b) }
                    j += 1
                }
            }
            previous = first..<runs.count
        }
        // Each outline's extent and size; only small ones are looked at closer.
        let maxSide = Int32(0.014 * Double(gw)) + 1, minSide = Int32(0.004 * Double(gw))
        let n = runs.count
        var x0 = [Int32](repeating: .max, count: n), x1 = [Int32](repeating: .min, count: n)
        var y0 = [Int32](repeating: .max, count: n), y1 = [Int32](repeating: .min, count: n), count = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let r = runs[i], key = Int(root(r.label))
            x0[key] = min(x0[key], r.x0); x1[key] = max(x1[key], r.x1); y0[key] = min(y0[key], r.y); y1[key] = max(y1[key], r.y)
            count[key] += Int(r.x1 - r.x0 + 1)
        }
        let small = Set((0..<n).compactMap { key -> Int32? in
            guard count[key] >= 8 else { return nil }
            let side = max(x1[key] - x0[key], y1[key] - y0[key]) + 1
            return side >= minSide && side <= maxSide ? Int32(key) : nil
        })
        guard !small.isEmpty else { return [] }
        var members: [Int32: [Int]] = [:]
        for (i, r) in runs.enumerated() { let key = root(r.label); if small.contains(key) { members[key, default: []].append(i) } }
        var found: [BulletSighting] = []
        for key in small.sorted() {
            pixels.removeAll(keepingCapacity: true)
            for i in members[key] ?? [] { for x in runs[i].x0...runs[i].x1 { pixels.append(runs[i].y * Int32(gw) + x) } }
            guard let sighting = round(pixels, gridWidth: gw, stride: s, image: image) else { continue }
            let px = sighting.position.x * Double(width), py = sighting.position.y * Double(height)
            if areas.contains(where: { $0.contains(px, py) }) { continue }
            found.append(sighting)
        }
        return found
    }

    /// The round an outline belongs to, if its shape and fill are a round's.
    private func round(_ outline: [Int32], gridWidth gw: Int, stride s: Int, image: PixelImage) -> BulletSighting? {
        // Its axis, from the outline's spread.
        var sx = 0.0, sy = 0.0
        for i in outline { sx += Double(Int(i) % gw); sy += Double(Int(i) / gw) }
        let n = Double(outline.count), mx = sx / n, my = sy / n
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for i in outline {
            let dx = Double(Int(i) % gw) - mx, dy = Double(Int(i) / gw) - my
            cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
        let u = Point(cos(angle), sin(angle))
        var lo = Double.infinity, hi = -Double.infinity, across = 0.0
        var wlo = Double.infinity, whi = -Double.infinity
        for i in outline {
            let dx = Double(Int(i) % gw) - mx, dy = Double(Int(i) / gw) - my
            let a = dx * u.x + dy * u.y, p = -dx * u.y + dy * u.x
            lo = min(lo, a); hi = max(hi, a); wlo = min(wlo, p); whi = max(whi, p)
        }
        across = whi - wlo
        let width = Double(image.width)
        let length = (hi - lo) * Double(s), thickness = max(1, across) * Double(s)
        guard Self.length.contains(length / width), Self.proportions.contains(length / thickness) else { return nil }
        // Full-resolution pixels from the middle of the outline's extent, along (`a`) and across (`p`) its axis.
        let middle = (mx + u.x * (lo + hi) / 2, my + u.y * (lo + hi) / 2)
        let cx = middle.0 * Double(s), cy = middle.1 * Double(s)
        func at(_ a: Double, _ p: Double = 0) -> RGB? {
            let x = cx + u.x * a - u.y * p, y = cy + u.y * a + u.x * p
            guard x >= 0, y >= 0, x < width, y < Double(image.height) else { return nil }
            return image.pixel(x, y)
        }
        // The fill of each half: the median of the light samples along the axis.
        func fill(_ sign: Double) -> RGB? {
            let colors = (1...5).compactMap { k in at(sign * Double(k) * 0.08 * length) }.filter { $0.luminance >= Self.fillLuminance }
            guard colors.count >= 2 else { return nil }
            func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
            return RGB(median(colors.map(\.r)), median(colors.map(\.g)), median(colors.map(\.b)))
        }
        guard let forward = fill(1), let backward = fill(-1),
              let (ammo, tipForward) = Self.palette(forward, backward) else { return nil }
        // The trail: a pale line beyond one end, unlike the ground on both sides of it, which match.
        func trailed(_ a: Double) -> Bool {
            guard let on = at(a), let left = at(a, 1.5 * thickness), let right = at(a, -1.5 * thickness) else { return false }
            let side = RGB((left.r + right.r) / 2, (left.g + right.g) / 2, (left.b + right.b) / 2)
            return left.distance(right) <= 14 && on.distance(side) >= 16 && on.r + on.g + on.b >= side.r + side.g + side.b - 30
        }
        func trail(_ sign: Double) -> Int { (1...8).filter { trailed(sign * (0.5 * length + Double($0) * 0.45 * length)) }.count }
        let ahead = trail(1), behind = trail(-1)
        let sign: Double, oriented: Bool
        if let tipForward { sign = tipForward ? 1 : -1; oriented = true }
        else if ahead >= 3 && behind <= 1 { sign = -1; oriented = true }
        else if behind >= 3 && ahead <= 1 { sign = 1; oriented = true }
        else { sign = 1; oriented = false }
        // Where the trail fades out: followed back in steps of a round's length until it stops, at most a quarter view.
        var tail: Point?
        if (sign > 0 ? behind : ahead) >= 3 {
            var a = 0.5 * length, misses = 0, last = a
            while a < 0.25 * width, misses < 3 {
                a += 0.5 * length
                if trailed(-sign * a) { last = a; misses = 0 } else { misses += 1 }
            }
            tail = Point((cx - sign * u.x * last) / width, (cy - sign * u.y * last) / Double(image.height))
        }
        let trailAgrees = (sign > 0 ? behind : ahead) >= 3
        // Red is common on the map (flowers, roofs, lava): shells are only taken with their trail.
        if ammo == .shells && !trailAgrees { return nil }
        return BulletSighting(position: Point(cx / width, cy / Double(image.height)), direction: Point(sign * u.x, sign * u.y),
                              oriented: oriented, tail: tail, ammo: ammo, confidence: trailAgrees ? 0.9 : 0.5)
    }

    /// The ammunition whose colors a round's two halves show, and whether its tip is the `forward` half; nil when it is
    /// none of them. Shells are red all over, so their tip is not told.
    static func palette(_ forward: RGB, _ backward: RGB) -> (AmmoFamily, Bool?)? {
        func warm(_ c: RGB) -> Bool { c.r - c.b >= 45 && c.maxChannel >= 150 && c.r >= c.g - 10 }
        func gray(_ c: RGB) -> Bool { c.saturation <= 28 && (60...185).contains((c.r + c.g + c.b) / 3) }
        func blue(_ c: RGB) -> Bool { c.b >= c.r + 35 && c.b >= c.g + 10 }
        func brown(_ c: RGB) -> Bool { c.r - c.b >= 35 && c.r >= c.g && c.g >= c.b && c.maxChannel <= 175 }
        func red(_ c: RGB) -> Bool { c.r >= c.g + 70 && c.r >= c.b + 70 }
        for (tip, base, isForward) in [(forward, backward, true), (backward, forward, false)] where warm(tip) {
            if gray(base) { return (.small, isForward) }
            if blue(base) { return (.medium, isForward) }
            if brown(base) && tip.r + tip.g + tip.b > base.r + base.g + base.b + 60 { return (.large, isForward) }
        }
        if red(forward) || red(backward) { return (.shells, nil) }
        return nil
    }
}
