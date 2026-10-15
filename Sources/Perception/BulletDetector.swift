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
    /// Runs of outline samples along a row, joined into outlines by a union-find over their indices. A parent never comes
    /// after its run, so an outline's root is its first run; that run also gathers the outline's extent, size and last run,
    /// and `next` chains the outline's runs in reading order.
    private struct Run { var y, x0, x1, parent, next, left, right, count, last: Int32 }
    /// One row's outline samples, a byte each, and the runs, kept across frames so the scan allocates nothing once they
    /// have grown. It runs on every frame beside the Core ML detector, on a machine that also runs the game.
    private var flags = UnsafeMutablePointer<UInt8>.allocate(capacity: 64), flagCapacity = 64
    private var runs = UnsafeMutablePointer<Run>.allocate(capacity: 1 << 15), runCapacity = 1 << 15
    public init() {}
    deinit { flags.deallocate(); runs.deallocate() }

    private static func root(_ runs: UnsafeMutablePointer<Run>, _ i: Int) -> Int {
        var i = i
        while Int(runs[i].parent) != i { runs[i].parent = runs[Int(runs[i].parent)].parent; i = Int(runs[i].parent) }
        return i
    }

    /// The rounds in `image`, a viewport frame, away from the HUD rectangles in `excluding` (pixels).
    public func detect(_ image: PixelImage, excluding areas: [PixelRect] = []) -> [BulletSighting] {
        let width = image.width, height = image.height
        let s = max(1, Int((Double(width) / 1920).rounded()))
        let gw = width / s, gh = height / s
        guard gw > 8, gh > 8 else { return [] }
        // Outline samples, every `s` pixels, as runs along each row joined to the runs they touch in the row above. A
        // sample is dark when (r·77 + g·150 + b·29) / 256 < 80. The loop over a row stays simple, two 16-bit loads per
        // pixel and 16-bit math (the sum is at most 65,280), so the compiler vectorizes it; its bytes are packed 64 to
        // a word, whose bit changes start and end the runs. Bytes past the row stay 0, so the last word ends any run.
        let words = gw / 64 + 1
        if flagCapacity < words * 64 { flags.deallocate(); flagCapacity = words * 64; flags = .allocate(capacity: flagCapacity) }
        let flags = flags, limit = UInt16(Self.outline) << 8
        (flags + gw).initialize(repeating: 0, count: words * 64 - gw)
        let (w0, w2): (UInt16, UInt16) = image.bgra ? (29, 77) : (77, 29)
        @inline(__always) func scan(_ p: UnsafeRawPointer, _ step: Int) {
            for x in 0..<gw {
                let lo = p.load(fromByteOffset: x &* step, as: UInt16.self), hi = p.load(fromByteOffset: x &* step &+ 2, as: UInt16.self)
                flags[x] = (lo & 0xFF) &* w0 &+ (lo &>> 8) &* 150 &+ (hi & 0xFF) &* w2 < limit ? 1 : 0
            }
        }
        let base = UnsafeRawPointer(image.base), row = image.bytesPerRow
        var n = 0, previous = 0..<0
        for gy in 0..<gh {
            let p = base + gy * s * row
            switch s { case 1: scan(p, 4); case 2: scan(p, 8); default: scan(p, 4 * s) }
            if n + (gw + 1) / 2 > runCapacity {
                let grown = UnsafeMutablePointer<Run>.allocate(capacity: 2 * (n + gw))
                grown.initialize(from: runs, count: n); runs.deallocate(); runs = grown; runCapacity = 2 * (n + gw)
            }
            let r = runs, first = n, f = UnsafeRawPointer(flags)
            var start: Int32 = 0, carry: UInt64 = 0
            for k in 0..<words {
                var any: UInt64 = 0
                for j in 0..<8 { any |= f.load(fromByteOffset: k &* 64 &+ j &* 8, as: UInt64.self) }
                if any == 0 && carry == 0 { continue }
                var bits: UInt64 = 0
                for j in 0..<8 { bits |= ((f.load(fromByteOffset: k &* 64 &+ j &* 8, as: UInt64.self) &* 0x0102040810204080) >> 56) << UInt64(j &* 8) }
                var edges = bits ^ (bits << 1 | carry)
                carry = bits >> 63
                while edges != 0 {
                    let b = edges.trailingZeroBitCount, x = Int32(k &* 64 &+ b)
                    if bits >> UInt64(b) & 1 != 0 { start = x }
                    else { r[n] = Run(y: Int32(gy), x0: start, x1: x - 1, parent: Int32(n), next: -1, left: 0, right: 0, count: 0, last: 0); n += 1 }
                    edges &= edges &- 1
                }
            }
            // Runs overlapping or touching diagonally belong to one outline.
            var k = previous.lowerBound
            for i in first..<n {
                while k < previous.upperBound && r[k].x1 < r[i].x0 - 1 { k += 1 }
                var j = k
                while j < previous.upperBound && r[j].x0 <= r[i].x1 + 1 {
                    let a = Self.root(r, i), b = Self.root(r, j)
                    if a != b { r[max(a, b)].parent = Int32(min(a, b)) }
                    j += 1
                }
            }
            previous = first..<n
        }
        // Each outline's extent and size, at its root; only small ones are looked at closer, in the order of their first runs.
        let r = runs
        for i in 0..<n {
            let p = Int(r[i].parent), key = p == i ? i : Int(r[p].parent)
            r[i].parent = Int32(key)
            if key == i { r[i].left = r[i].x0; r[i].right = r[i].x1; r[i].count = r[i].x1 - r[i].x0 + 1; r[i].last = Int32(i); continue }
            r[key].left = min(r[key].left, r[i].x0); r[key].right = max(r[key].right, r[i].x1); r[key].count += r[i].x1 - r[i].x0 + 1
            r[Int(r[key].last)].next = Int32(i); r[key].last = Int32(i)
        }
        let maxSide = Int32(0.014 * Double(gw)) + 1, minSide = Int32(0.004 * Double(gw))
        var found: [BulletSighting] = []
        for key in 0..<n where r[key].parent == Int32(key) && r[key].count >= 8 {
            let side = max(r[key].right - r[key].left, r[Int(r[key].last)].y - r[key].y) + 1
            guard side >= minSide && side <= maxSide, let sighting = round(r, key, stride: s, image: image) else { continue }
            let px = sighting.position.x * Double(width), py = sighting.position.y * Double(height)
            if areas.contains(where: { $0.contains(px, py) }) { continue }
            found.append(sighting)
        }
        return found
    }

    /// The round an outline belongs to, if its shape and fill are a round's. The outline is the chain of runs from `key`,
    /// read sample by sample in reading order, as the sums below depend on their order.
    private func round(_ runs: UnsafeMutablePointer<Run>, _ key: Int, stride s: Int, image: PixelImage) -> BulletSighting? {
        @inline(__always) func samples(_ body: (Double, Double) -> Void) {
            var i = key
            while i >= 0 { let y = Double(runs[i].y); for x in runs[i].x0...runs[i].x1 { body(Double(x), y) }; i = Int(runs[i].next) }
        }
        // Its axis, from the outline's spread.
        var sx = 0.0, sy = 0.0
        samples { x, y in sx += x; sy += y }
        let n = Double(runs[key].count), mx = sx / n, my = sy / n
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        samples { x, y in
            let dx = x - mx, dy = y - my
            cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
        let u = Point(cos(angle), sin(angle))
        var lo = Double.infinity, hi = -Double.infinity, across = 0.0
        var wlo = Double.infinity, whi = -Double.infinity
        samples { x, y in
            let dx = x - mx, dy = y - my
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
        func trail(_ sign: Double) -> Int {
            var count = 0
            for k in 1...8 where trailed(sign * (0.5 * length + Double(k) * 0.45 * length)) { count += 1 }
            return count
        }
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
