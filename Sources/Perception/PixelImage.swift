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

    /// Which points of a `columns` × `rows` grid over `rect` show interface text: bright, unsaturated pixels. Rows above
    /// `split` (a fraction of the height; the item name, white) need luminance 215 and saturation up to 60. Rows below
    /// (the subtitle, light gray) need luminance 150, saturation up to 30 and a dark glyph outline within about three
    /// pixels: a pale floor seen through a translucent panel is as bright as the subtitle, but has no outline. The map
    /// scrolling behind the panel while you walk therefore leaves the mask alone, and only new text changes it.
    public func textMask(_ rect: PixelRect, columns: Int, rows: Int, split: Double = 0.53) -> [UInt8] {
        guard rect.width >= 1, rect.height >= 1, columns > 0, rows > 0 else { return [] }
        var mask = [UInt8](repeating: 0, count: columns * rows)
        let reach = max(2, Int((rect.width / Double(columns)).rounded()))
        func outlined(_ x: Int, _ y: Int) -> Bool {
            for d in 1...reach where pixel(min(width - 1, x + d), y).luminance <= 90 || pixel(max(0, x - d), y).luminance <= 90
                || pixel(x, min(height - 1, y + d)).luminance <= 90 || pixel(x, max(0, y - d)).luminance <= 90 { return true }
            return false
        }
        for row in 0..<rows {
            let fy = (Double(row) + 0.5) / Double(rows)
            let name = fy < split
            for column in 0..<columns {
                let x = min(width - 1, max(0, Int(rect.x + rect.width * (Double(column) + 0.5) / Double(columns))))
                let y = min(height - 1, max(0, Int(rect.y + rect.height * fy)))
                let c = pixel(x, y)
                let text = name ? c.luminance >= 215 && c.saturation <= 60 : c.luminance >= 150 && c.saturation <= 30 && outlined(x, y)
                if text { mask[row * columns + column] = 1 }
            }
        }
        return mask
    }

    /// A standalone copy of a region scaled up by `scale` on a border of `padding` pixels in `fill`: Vision misses most
    /// single digits at their native size on the HUD.
    public func cgImage(_ rect: PixelRect, scale: Int, padding: Int, fill: RGB) -> CGImage? {
        guard scale >= 1, let source = cgImage(rect), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = source.width * scale + 2 * padding, h = source.height * scale + 2 * padding
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255, blue: CGFloat(fill.b) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: padding, y: padding, width: source.width * scale, height: source.height * scale))
        return context.makeImage()
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

/// Overlap (intersection over union) of two text masks of `columns` per row, at the best vertical offset of up to
/// `maxShift` rows: the prompt panel's found position jitters by a few pixels when its edges sit on busy ground.
public func textMaskSimilarity(_ a: [UInt8], _ b: [UInt8], columns: Int, maxShift: Int = 4) -> Double {
    guard a.count == b.count, columns > 0, !a.isEmpty, a.count % columns == 0 else { return 0 }
    let rows = a.count / columns
    let countA = a.reduce(0) { $0 + Int($1) }, countB = b.reduce(0) { $0 + Int($1) }
    if countA == 0 || countB == 0 { return countA == countB ? 1 : 0 }
    var best = 0.0
    for shift in -min(maxShift, rows - 1)...min(maxShift, rows - 1) {
        var both = 0
        for row in max(0, -shift)..<min(rows, rows - shift) {
            let ra = row * columns, rb = (row + shift) * columns
            for column in 0..<columns where a[ra + column] != 0 && b[rb + column] != 0 { both += 1 }
        }
        best = max(best, Double(both) / Double(countA + countB - both))
    }
    return best
}

/// Prompt text masks: 128 × 32 samples, the same text at an overlap of at least 0.8. On 24 recorded matches this kept
/// 88% of same-text frame pairs 0.2 s apart (the luminance fingerprint kept 30% while walking). On a pale indoor floor,
/// "M4 / Rare AR" and "Bolt Mk. II Sniper / Rare Sniper" overlap 0.25; without the outline rule the floor made it 0.83.
public enum PromptMask {
    public static let columns = 128, rows = 32
    public static let sameText = 0.8
    public static func matches(_ a: [UInt8], _ b: [UInt8]) -> Bool { textMaskSimilarity(a, b, columns: columns) >= sameText }
}
