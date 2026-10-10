import Foundation
import CoreGraphics
import CoreMedia
import VideoToolbox

/// Where to crop the Chrome window and how large the encoded frames are.
public struct CaptureGeometry: Equatable, Sendable {
    /// Window-local points, top-left origin: everything below Chrome's tab strip and toolbar.
    public let sourceRect: CGRect
    public let width: Int
    public let height: Int
    public let scale: Double

    public static let maximumLongEdge = 3840

    public init?(windowSize: CGSize, topInset: Double, scale: Double) {
        let inset = min(max(0, topInset), Double(windowSize.height))
        let content = CGSize(width: windowSize.width, height: windowSize.height - inset)
        guard content.width >= 200, content.height >= 150, scale > 0 else { return nil }
        var w = Double(content.width) * scale, h = Double(content.height) * scale
        let longEdge = max(w, h)
        if longEdge > Double(Self.maximumLongEdge) {
            let factor = Double(Self.maximumLongEdge) / longEdge
            w *= factor; h *= factor
        }
        // Video encoders need even dimensions.
        width = Int(w) & ~1
        height = Int(h) & ~1
        sourceRect = CGRect(x: 0, y: inset, width: content.width, height: content.height)
        self.scale = scale
    }
}

public enum VideoEncoding {
    public static let fps = 30
    public static let bitsPerPixel = 0.08
    public static let bitrateRange = 4_000_000...24_000_000

    /// About 0.08 bits per pixel per frame: ~16 Mbps for 3840×1736 at 30 FPS.
    public static func bitrate(width: Int, height: Int, fps: Int = fps) -> Int {
        let target = Int((bitsPerPixel * Double(width) * Double(height) * Double(fps)).rounded())
        return min(max(target, bitrateRange.lowerBound), bitrateRange.upperBound)
    }

    /// Whether a hardware encoder exists for this codec and size; software encoding is never used.
    public static func hasHardwareEncoder(_ codec: CMVideoCodecType, width: Int, height: Int) -> Bool {
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        var encoderID: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height), codecType: codec,
                                                           encoderSpecification: specification, encoderIDOut: &encoderID,
                                                           supportedPropertiesOut: &properties) == noErr
    }

    /// HEVC when the hardware supports it, otherwise hardware H.264, otherwise nil.
    public static func preferredCodec(width: Int, height: Int) -> CMVideoCodecType? {
        [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264].first { hasHardwareEncoder($0, width: width, height: height) }
    }
}
