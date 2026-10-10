import Foundation

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
    public static func + (l: Self, r: Self) -> Self { .init(l.x + r.x, l.y + r.y) }
    public static func - (l: Self, r: Self) -> Self { .init(l.x - r.x, l.y - r.y) }
    public static func * (l: Self, r: Double) -> Self { .init(l.x * r, l.y * r) }
    public var length: Double { hypot(x, y) }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public var isInViewport: Bool { isFinite && (0...1).contains(x) && (0...1).contains(y) }
    public func distance(to other: Self, aspect: Double = 16.0 / 9.0) -> Double {
        hypot(x - other.x, (y - other.y) / aspect)
    }
}

/// Coordinates are normalized to the cropped game viewport, origin at top left.
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = Rect(0, 0, 1, 1)
    public var center: Point { Point(x + width / 2, y + height / 2) }
    public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.00001 && y + height <= 1.00001 }
    public func contains(_ p: Point, padding: Double = 0) -> Bool {
        p.x >= x - padding && p.x <= x + width + padding && p.y >= y - padding && p.y <= y + height + padding
    }
    public func intersectsSegment(from a: Point, to b: Point, padding: Double = 0) -> Bool {
        var lo = 0.0; var hi = 1.0
        let delta = b - a
        for (origin, direction, minValue, maxValue) in [(a.x, delta.x, x - padding, x + width + padding), (a.y, delta.y, y - padding, y + height + padding)] {
            if abs(direction) < 1e-9 {
                if origin < minValue || origin > maxValue { return false }
            } else {
                let t1 = (minValue - origin) / direction; let t2 = (maxValue - origin) / direction
                lo = max(lo, min(t1,t2)); hi = min(hi, max(t1,t2))
                if lo > hi { return false }
            }
        }
        return true
    }
}
