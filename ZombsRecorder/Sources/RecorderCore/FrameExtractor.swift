import Foundation
import AVFoundation
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

public struct ExtractedFrame: Codable, Equatable, Sendable {
    /// `images/%06d.jpg`, numbered by the frame's index in the whole recording (all parts).
    public var image: String
    public var index: Int
    public var part: Int
    /// Seconds from the match start; strictly increasing across parts.
    public var timestamp: Double
    public var width: Int
    public var height: Int
}

public enum FrameExtractor {
    /// Decode every part on the hardware decoder and save a JPEG at most every `1/fps` seconds.
    /// The JPEG encoder and quality match ZombsAssistant's SessionRecorder.
    public static func extract(recording folder: URL, manifest: RecordingManifest, to output: URL, fps: Double,
                               quality: Double = 0.95, emit: (ExtractedFrame) throws -> Void) async throws {
        guard fps > 0, fps <= 30 else { throw KaggleError.invalid("--fps must be in (0, 30]") }
        let images = output.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let step = 1 / fps
        var next = 0.0
        var last = -Double.infinity
        var index = 0
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        for (partIndex, part) in manifest.parts.enumerated() {
            let asset = AVURLAsset(url: folder.appendingPathComponent(part.file))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw KaggleError.invalid("\(part.file) has no video track")
            }
            let reader = try AVAssetReader(asset: asset)
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            trackOutput.alwaysCopiesSampleData = false
            reader.add(trackOutput)
            guard reader.startReading() else { throw reader.error ?? KaggleError.invalid("Cannot read \(part.file)") }
            var first: CMTime?
            while let buffer = trackOutput.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
                let presentation = CMSampleBufferGetPresentationTimeStamp(buffer)
                if first == nil { first = presentation }
                let time = part.startSeconds + (presentation - first!).seconds
                defer { index += 1 }
                guard time + 1e-6 >= next, time > last else { continue }
                // Snap to the sampling grid so a pause in capture is not followed by a burst of frames.
                next = (floor(time / step + 1e-6) + 1) * step
                last = time
                let name = String(format: "images/%06d.jpg", index)
                try writeJPEG(pixels, to: output.appendingPathComponent(name), quality: quality, colorSpace: sRGB)
                try emit(ExtractedFrame(image: name, index: index, part: partIndex, timestamp: time,
                                        width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
            }
            if reader.status == .failed { throw reader.error ?? KaggleError.invalid("Cannot decode \(part.file)") }
        }
    }

    static func writeJPEG(_ pixels: CVPixelBuffer, to url: URL, quality: Double, colorSpace: CGColorSpace) throws {
        var decoded: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &decoded) == noErr, let decoded else {
            throw KaggleError.invalid("Cannot convert a decoded frame")
        }
        // Capture was converted to sRGB before encoding; tag the pixels as such without converting them again.
        let image = decoded.copy(colorSpace: colorSpace) ?? decoded
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw KaggleError.invalid("Cannot create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw KaggleError.invalid("Cannot save \(url.lastPathComponent)") }
    }
}
