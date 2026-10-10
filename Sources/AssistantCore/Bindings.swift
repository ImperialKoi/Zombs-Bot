import Foundation

public struct KeyBindings: Codable, Equatable, Sendable {
    public var interact: UInt16 = 14 // E
    public var reload: UInt16 = 15 // R
    public var slots: [UInt16] = [18,19,20,21,23,22] // 1...6
    public init() {}
    /// The product deliberately excludes movement, arrows, modifiers and system shortcuts.
    public static let allowed: Set<UInt16> = Set<UInt16>([0x0B,0x08,0x02,0x0E,0x03,0x05,0x04,0x22,0x26,0x28,0x25,0x2E,0x2D,0x1F,0x23,0x0C,0x0F,0x01,0x11,0x20,0x09,0x0D,0x07,0x10,0x06,18,19,20,21,23,22,26,28,25,29]).subtracting([0,1,2,13])
    public var isValid: Bool {
        let keys = [interact,reload] + slots
        return slots.count == 6 && Set(keys).count == 8 && keys.allSatisfy { Self.allowed.contains($0) }
    }
}

public struct PerformanceWindow: Sendable {
    private var samples: [(time: Double, latency: Double)] = []
    public init() {}
    public mutating func record(frameTime: Double, completedAt: Double) {
        guard frameTime.isFinite, completedAt.isFinite, completedAt >= frameTime else { return }
        samples.append((completedAt, completedAt - frameTime))
        samples.removeAll { completedAt - $0.time > 10 }
        if samples.count > 1000 { samples.removeFirst(samples.count - 1000) }
    }
    public var count: Int { samples.count }
    public var fps: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return Double(samples.count - 1) / (last.time - first.time)
    }
    public var p95: Double { let sorted = samples.map(\.latency).sorted(); return sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
    /// The release target: at least 20 updates per second with p95 latency under 100 ms.
    public var passes: Bool { passes(minimumFPS: 20) }
    /// The supervised beta accepts 15 updates per second; frame-age compensation covers the extra delay.
    public func passes(minimumFPS: Double) -> Bool { count >= 100 && fps >= minimumFPS && p95 <= 0.1 }
    public static let betaMinimumFPS = 15.0
}
