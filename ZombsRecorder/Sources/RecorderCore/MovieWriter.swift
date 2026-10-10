import Foundation
import AVFoundation
import VideoToolbox

public struct FinishedPart: Sendable, Equatable {
    public let index: Int
    public let file: String
    public let width: Int
    public let height: Int
    public let frames: Int
    public let startSeconds: Double
    public let durationSeconds: Double
}

/// One movie file. Captured pixel buffers go straight to the hardware encoder: no CPU conversion.
public final class MovieWriter {
    public let index: Int
    public let url: URL
    public let width: Int
    public let height: Int
    public let startSeconds: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    public private(set) var frames = 0
    private var first: CMTime?
    private var last: CMTime?

    public init(index: Int, url: URL, width: Int, height: Int, codec: CMVideoCodecType, startSeconds: Double) throws {
        self.index = index; self.url = url; self.width = width; self.height = height; self.startSeconds = startSeconds
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragments every 10 s keep the file readable if the app is killed mid-match.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoding.outputSettings(codec: codec, width: width, height: height))
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw KaggleError.invalid("Cannot configure the video encoder") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? KaggleError.invalid("Cannot start the video file") }
    }

    /// Whether the encoder would take a frame now; `append` drops the frame otherwise.
    public var isReady: Bool { input.isReadyForMoreMediaData }

    public func append(_ pixels: CVPixelBuffer, at time: CMTime) {
        if first == nil { writer.startSession(atSourceTime: time); first = time }
        // Drop rather than queue when the encoder is busy: recording must never back up into the game.
        guard writer.status == .writing, input.isReadyForMoreMediaData, last.map({ time > $0 }) ?? true else { return }
        if adaptor.append(pixels, withPresentationTime: time) { frames += 1; last = time }
    }

    public func finish() async -> FinishedPart? {
        guard let first, let last, frames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        input.markAsFinished()
        // End one frame after the last sample so the final frame is kept.
        writer.endSession(atSourceTime: last + CMTime(value: 1, timescale: CMTimeScale(VideoEncoding.fps)))
        await writer.finishWriting()
        if writer.status == .completed {
            return FinishedPart(index: index, file: url.lastPathComponent, width: width, height: height, frames: frames,
                                startSeconds: startSeconds, durationSeconds: (last - first).seconds)
        }
        // The fragments written so far are still a valid movie.
        guard let summary = await MovieSummary.read(url) else { return nil }
        return FinishedPart(index: index, file: url.lastPathComponent, width: summary.width, height: summary.height,
                            frames: summary.frames, startSeconds: startSeconds, durationSeconds: summary.duration)
    }
}

extension VideoEncoding {
    /// Hardware-only encoder settings: a software fallback would load the CPU during the match.
    public static func outputSettings(codec: CMVideoCodecType, width: Int, height: Int) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate(width: width, height: height),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == kCMVideoCodecType_H264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: codec == kCMVideoCodecType_HEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ]
    }
}
