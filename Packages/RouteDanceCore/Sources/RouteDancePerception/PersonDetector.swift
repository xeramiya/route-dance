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
///
/// 実動画での実測（150フレーム、`upperBodyOnly` の false → true）で、1フレームあたりの検出数が
/// 0.89/0.04/0.49 → 1.45/0.63/2.24、0件のフレームが 47/130/90 → 12/66/5 になったため、既定は true。
public struct VisionPersonDetector: PersonDetector {
    public var name: String { "Vision" }
    /// 上半身だけでも結果を返してよいか（Vision の既定値と同じ true）。
    public var upperBodyOnly = true
    /// 画像中央（地平線付近）の帯を拡大して追加で検出し、遠くの小さな人を拾う。
    public var zoomedCenterPass = true
    /// 拡大パスを走らせる間隔（フレーム数）。1 なら毎フレーム。拡大パスは約6ms/回。
    public var zoomInterval = 2
    /// 拡大する領域（正規化、左上原点）。実動画で比較して選んだ値。
    public var zoomRegion = CGRect(x: 0.15, y: 0.25, width: 0.7, height: 0.35)
    public var zoomScale = 3.0
    /// 統合時に同一人物とみなす IoU のしきい値。
    public var mergeIoU = 0.5

    private let counter = FrameCounter()

    public init() {}

    public func detect(_ image: CIImage) async throws -> [PersonDetection] {
        let base = try await detect(image, upperBodyOnly: upperBodyOnly)
        guard zoomedCenterPass, counter.next() % max(1, zoomInterval) == 0 else { return base }
        let zoomed = (try? await detectZoomed(image)) ?? []
        return Self.merge(base, zoomed, iou: mergeIoU)
    }

    private func detect(_ image: CIImage, upperBodyOnly: Bool) async throws -> [PersonDetection] {
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

    /// 中央の帯を切り出して拡大し、検出した枠を元画像の座標へ戻す。
    private func detectZoomed(_ image: CIImage) async throws -> [PersonDetection] {
        let e = image.extent
        // 左上原点の領域（元画像のピクセル）。
        let rx = zoomRegion.minX * e.width, ry = zoomRegion.minY * e.height
        let rw = zoomRegion.width * e.width, rh = zoomRegion.height * e.height
        let ciRect = CGRect(x: e.minX + rx, y: e.minY + e.height - ry - rh, width: rw, height: rh)
        let zoomed = image
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            .transformed(by: CGAffineTransform(scaleX: zoomScale, y: zoomScale))
        let found = try await detect(zoomed, upperBodyOnly: true)
        let edge = 2.0 * zoomScale
        let zw = rw * zoomScale, zh = rh * zoomScale
        return found.compactMap { d in
            // 切り出し境界（画像の内側にあるもの）に接する枠は人物が途中で切れているので捨てる。
            if (ry > 0 && d.minY < edge) || (ry + rh < e.height && d.maxY > zh - edge) { return nil }
            if (rx > 0 && d.minX < edge) || (rx + rw < e.width && d.maxX > zw - edge) { return nil }
            var o = d
            o.minX = rx + d.minX / zoomScale
            o.maxX = rx + d.maxX / zoomScale
            o.minY = ry + d.minY / zoomScale
            o.maxY = ry + d.maxY / zoomScale
            return o
        }
    }

    /// 信頼度の高い順に採用し、既存の枠と IoU が高いものは重複として捨てる（NMS）。
    static func merge(_ a: [PersonDetection], _ b: [PersonDetection], iou: Double) -> [PersonDetection] {
        var out: [PersonDetection] = []
        for d in (a + b).sorted(by: { $0.confidence > $1.confidence }) where !out.contains(where: { $0.iou(d) > iou }) {
            out.append(d)
        }
        return out
    }
}

/// フレーム数を数える（`PersonDetector` は Sendable なので参照型で状態を持つ）。
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = -1
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}
