import CoreGraphics
import CoreVideo
import Foundation

public struct RGB: Equatable, Sendable {
    public var r: Int, g: Int, b: Int
    public init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    @inline(__always) public func distance(_ o: RGB) -> Int { max(abs(r - o.r), abs(g - o.g), abs(b - o.b)) }
    @inline(__always) public var luminance: Int { (r * 299 + g * 587 + b * 114) / 1000 }
    @inline(__always) public var saturation: Int { max(r, g, b) - min(r, g, b) }
    @inline(__always) public var maxChannel: Int { max(r, g, b) }
    /// The color blended toward white by `amount`.
    public func lightened(_ amount: Double) -> RGB {
        RGB(r + Int(Double(255 - r) * amount), g + Int(Double(255 - g) * amount), b + Int(Double(255 - b) * amount))
    }
}

/// A rectangle in pixels. Perception keeps its arithmetic in Double; CGRect appears only at API boundaries.
public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px <= maxX && py >= y && py <= maxY }
}

/// Read-only 8-bit pixels of one viewport frame: a locked capture buffer (BGRA) or a decoded image (RGBA).
/// Frames are never converted whole; readers sample the pixels they need.
public final class PixelImage {
    public let width: Int
    public let height: Int
    let bytesPerRow: Int
    let base: UnsafePointer<UInt8>
    let bgra: Bool
    private let release: () -> Void

    public init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly); return nil
        }
        width = CVPixelBufferGetWidth(pixelBuffer); height = CVPixelBufferGetHeight(pixelBuffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        base = UnsafePointer(address.assumingMemoryBound(to: UInt8.self)); bgra = true
        release = { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    }

    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height, row = w * 4
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: row * h)
        guard let context = CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { data.deallocate(); return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        width = w; height = h; bytesPerRow = row; base = UnsafePointer(data); bgra = false
        release = { data.deallocate() }
    }

    deinit { release() }

    @inline(__always) public func pixel(_ x: Int, _ y: Int) -> RGB {
        let p = base + y * bytesPerRow + x * 4
        return bgra ? RGB(Int(p[2]), Int(p[1]), Int(p[0])) : RGB(Int(p[0]), Int(p[1]), Int(p[2]))
    }
    @inline(__always) public func pixel(_ x: Double, _ y: Double) -> RGB {
        pixel(min(width - 1, max(0, Int(x))), min(height - 1, max(0, Int(y))))
    }
    /// Mean luminance of each cell of a `columns` × `rows` grid over `rect`, sampled sparsely.
    /// Used to notice when a text region changes.
    public func fingerprint(_ rect: PixelRect, columns: Int, rows: Int) -> [UInt8] {
        let x0 = max(0, rect.minX), y0 = max(0, rect.minY)
        let x1 = min(Double(width), rect.maxX), y1 = min(Double(height), rect.maxY)
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return [] }
        var result = [UInt8](repeating: 0, count: columns * rows)
        let cw = (x1 - x0) / Double(columns), ch = (y1 - y0) / Double(rows)
        for row in 0..<rows { for column in 0..<columns {
            var sum = 0
            for sy in 0..<3 { for sx in 0..<3 {
                let fx = Double(column) + (Double(sx) + 0.5) / 3.0
                let fy = Double(row) + (Double(sy) + 0.5) / 3.0
                sum += pixel(x0 + cw * fx, y0 + ch * fy).luminance
            } }
            result[row * columns + column] = UInt8(sum / 9)
        } }
        return result
    }

    /// A standalone copy of a region, for text recognition or recording.
    public func cgImage(_ rect: PixelRect? = nil) -> CGImage? {
        let r = rect ?? PixelRect(0, 0, Double(width), Double(height))
        let x0 = max(0, Int(r.minX.rounded(.down))), y0 = max(0, Int(r.minY.rounded(.down)))
        let x1 = min(width, Int(r.maxX.rounded(.up))), y1 = min(height, Int(r.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = x1 - x0, h = y1 - y0, row = w * 4
        // Rows are copied as they are; the bitmap layout tells readers the channel order.
        var bytes = Data(count: row * h)
        bytes.withUnsafeMutableBytes { out in
            for y in 0..<h { memcpy(out.baseAddress! + y * row, base + (y0 + y) * bytesPerRow + x0 * 4, row) }
        }
        let layout = bgra ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: layout), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Fingerprints are equal when no cell changed by more than `tolerance` levels.
public func fingerprintsMatch(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 10) -> Bool {
    guard a.count == b.count, !a.isEmpty else { return false }
    for i in a.indices where abs(Int(a[i]) - Int(b[i])) > tolerance { return false }
    return true
}
