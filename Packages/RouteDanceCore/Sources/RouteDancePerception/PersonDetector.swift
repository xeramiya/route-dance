import CoreImage
import Foundation
import RouteDanceCore
import Vision

/// 人物検出の抽象化。将来YOLOX等に差し替えられるようにする。
public protocol PersonDetector: Sendable {
    var name: String { get }
    /// 正立した画像から人物の枠（ピクセル、左上原点）を返す。
    func detect(_ image: CIImage) async throws -> [PersonDetection]
}

/// Vision の `DetectHumanRectanglesRequest`（OS標準、iOS/macOS共通）。
public struct VisionPersonDetector: PersonDetector {
    public var name: String { "Vision" }
    public var upperBodyOnly = false

    public init() {}

    public func detect(_ image: CIImage) async throws -> [PersonDetection] {
        var request = DetectHumanRectanglesRequest()
        request.upperBodyOnly = upperBodyOnly
        let results = try await request.perform(on: image)
        let size = image.extent.size
        return results.map { obs in
            // Vision の正規化座標は左下原点。
            let r = obs.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            return PersonDetection(
                minX: r.minX, minY: r.minY, maxX: r.maxX, maxY: r.maxY,
                confidence: Double(obs.confidence), isUpperBodyOnly: obs.isUpperBodyOnly
            )
        }
    }
}
