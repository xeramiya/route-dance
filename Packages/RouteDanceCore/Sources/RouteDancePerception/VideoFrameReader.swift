import AVFoundation
import CoreImage
import CoreML
import Foundation

/// 動画ファイルを先頭から順に読み、正立した CIImage のフレームにする（iOS / macOS共通）。
public final class VideoFrameReader: @unchecked Sendable {
    public let asset: AVURLAsset
    public let naturalSize: CGSize
    public let nominalFrameRate: Float
    public let duration: Double
    /// メタデータから求めた水平画角（あれば）。
    public let horizontalFOV: Double?
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let transform: CGAffineTransform

    public enum ReaderError: Error { case noVideoTrack, cannotRead(Error?) }

    public init(url: URL, startTime: Double = 0) throws {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loaded: (AVAssetTrack, CGSize, CGAffineTransform, Float, CMTime)?
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let t = try? await track.load(.preferredTransform),
               let fps = try? await track.load(.nominalFrameRate),
               let d = try? await asset.load(.duration)
            {
                loaded = (track, size, t, fps, d)
            }
            sema.signal()
        }
        sema.wait()
        guard let (track, size, t, fps, d) = loaded else { throw ReaderError.noVideoTrack }
        naturalSize = size
        transform = t
        nominalFrameRate = fps
        duration = d.seconds
        horizontalFOV = nil
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ReaderError.cannotRead(error)
        }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        if startTime > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600), duration: .positiveInfinity)
        }
        reader.add(output)
        guard reader.startReading() else { throw ReaderError.cannotRead(reader.error) }
    }

    /// 次のフレーム。終わりなら nil。
    public func next() throws -> InputFrame? {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed { throw ReaderError.cannotRead(reader.error) }
            return nil
        }
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return try next() }
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return InputFrame(image: Self.upright(CIImage(cvPixelBuffer: pb), transform: transform), timestamp: t, knownHorizontalFOV: horizontalFOV)
    }

    /// preferredTransform を向き（EXIF orientation）に直して正立させる。
    static func upright(_ image: CIImage, transform t: CGAffineTransform) -> CIImage {
        let o: CGImagePropertyOrientation
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): o = .right  // 縦持ちで撮影（90°）
        case (0, -1, 1, 0): o = .left  // 270°
        case (-1, 0, 0, -1): o = .down  // 180°
        default: o = .up
        }
        let r = image.oriented(o)
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
    }
}

/// `.mlpackage` を `.mlmodelc` にコンパイルする（同期）。
public enum MLModelCompile {
    public static func compile(_ url: URL) throws -> URL {
        try MLModel.compileModel(at: url)
    }
}
