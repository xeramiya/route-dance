import CoreImage
import CoreML
import CoreVideo
import Foundation
import RouteDanceCore

/// MoGe-2 ViT-S（Core ML）による単眼メトリック深度推定。
///
/// 入力画像をモデルのアスペクト比に中央クロップしてから縮小する。出力の深度マップとカメラは
/// **元画像の全体**に対応するように、クロップ分を戻した PinholeCamera で返す（深度マップ自体はクロップ領域のみ）。
public final class DepthEstimator: @unchecked Sendable {
    public struct Output: Sendable {
        /// クロップ領域の深度。`camera` はこの深度マップの解像度での値。
        public var depth: DepthMap
        /// 元画像の解像度でのカメラ（推定した画角）。
        public var fullFrameCamera: PinholeCamera
        public var inferenceMilliseconds: Double
    }

    public enum LoadError: Error { case modelNotFound(String), unexpectedInput }

    private let model: MLModel
    public let inputWidth: Int
    public let inputHeight: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    /// - Parameter url: `.mlpackage` または コンパイル済みの `.mlmodelc`。
    public init(url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        model = try MLModel(contentsOf: compiled, configuration: config)
        guard let c = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw LoadError.unexpectedInput
        }
        inputWidth = c.pixelsWide
        inputHeight = c.pixelsHigh
    }

    /// バンドル内のモデルを探す。縦長なら `MoGe2S`、横長なら `MoGe2S_landscape`。
    public static func bundled(portrait: Bool, in bundle: Bundle = .main) throws -> DepthEstimator {
        let name = portrait ? "MoGe2S" : "MoGe2S_landscape"
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Models") {
                return try DepthEstimator(url: url)
            }
        }
        throw LoadError.modelNotFound(name)
    }

    /// バンドル内のモデルのうち、入力のアスペクト比（幅/高さ）に最も近いものを選ぶ。
    /// 超広角の縦持ち（9:16）を3:4のモデルに中央クロップすると上下が大きく切れるので、9:16 や 16:9 のモデルがあればそちらを使う。
    /// 見つからなければ `bundled(portrait:)` と同じモデルにフォールバックする。
    public static func bundled(aspect: Double, in bundle: Bundle = .main) throws -> DepthEstimator {
        // (名前, 幅/高さ)。3:4 と 4:3 は既存、9:16 と 16:9 は追加モデル。
        let candidates: [(String, Double)] = [
            ("MoGe2S_9x16", 9.0 / 16), ("MoGe2S", 3.0 / 4), ("MoGe2S_landscape", 4.0 / 3), ("MoGe2S_16x9", 16.0 / 9),
        ]
        for (name, _) in candidates.sorted(by: { abs(log($0.1 / aspect)) < abs(log($1.1 / aspect)) }) {
            if let url = modelURL(name, in: bundle) { return try DepthEstimator(url: url) }
        }
        return try bundled(portrait: aspect < 1, in: bundle)
    }

    private static func modelURL(_ name: String, in bundle: Bundle) -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Models") {
                return url
            }
        }
        return nil
    }

    /// 正立した画像（CIImage、原点は左下）から深度を推定する。
    public func estimate(_ image: CIImage, timestamp: Double, knownHorizontalFOV: Double? = nil) throws -> Output {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let extent = image.extent
        let crop = Self.centerCrop(extent.size, aspect: Double(inputWidth) / Double(inputHeight))
        let scale = Double(inputWidth) / crop.width
        let cropped = image
            .cropped(to: crop.offsetBy(dx: extent.minX, dy: extent.minY))
            .transformed(by: CGAffineTransform(translationX: -crop.minX - extent.minX, y: -crop.minY - extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let buffer = try makeBuffer()
        context.render(cropped, to: buffer, bounds: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight), colorSpace: CGColorSpaceCreateDeviceRGB())

        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let out = try model.prediction(from: input)
        guard let pts = out.featureValue(for: "points")?.multiArrayValue,
              let mask = out.featureValue(for: "mask")?.multiArrayValue,
              let scaleArr = out.featureValue(for: "metric_scale")?.multiArrayValue
        else { throw MoGePostprocessError.invalidShape }

        let w = inputWidth, h = inputHeight
        let points = Self.floats(pts)
        let maskValues = Self.floats(mask)
        let metric = Float(truncating: scaleArr[0])
        // 既知の画角は、クロップ後の画像に対する値へ換算する。
        let focal: MoGeFocalMode
        if let fov = knownHorizontalFOV {
            let fullFx = Double(extent.width) / 2 / tan(fov / 2)
            let cropFov = 2 * atan(crop.width / 2 / fullFx)
            focal = .knownHorizontalFOV(Float(cropFov))
        } else {
            focal = .estimate
        }
        let r = try MoGePostprocess.recover(points: points, mask: maskValues, metricScale: metric, width: w, height: h, focal: focal)
        let depth = DepthMap(r, timestamp: timestamp)
        // 元画像のカメラ: 焦点距離（ピクセル）は縮小率で戻し、主点は画像中心。
        let fx = depth.camera.fx / scale
        let full = PinholeCamera(
            fx: fx, fy: fx, cx: extent.width / 2, cy: extent.height / 2,
            width: Int(extent.width), height: Int(extent.height)
        )
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return Output(depth: depth, fullFrameCamera: full, inferenceMilliseconds: ms)
    }

    /// 深度マップ（クロップ領域）を元画像の座標で引けるようにする。
    public static func fullFrameSampler(_ o: Output, imageWidth: Int, imageHeight: Int) -> DepthMap {
        // クロップは中央なので、元画像の正規化座標 → クロップ内の正規化座標の変換を値に焼き込む。
        let crop = centerCrop(CGSize(width: imageWidth, height: imageHeight), aspect: Double(o.depth.width) / Double(o.depth.height))
        let w = o.depth.width, h = o.depth.height
        // 元画像の比率で、深度の解像度に合わせた格子を作る（外側は NaN）。
        let fw = Int((Double(w) * Double(imageWidth) / crop.width).rounded())
        let fh = Int((Double(h) * Double(imageHeight) / crop.height).rounded())
        let ox = (fw - w) / 2, oy = (fh - h) / 2
        var values = [Float](repeating: .nan, count: fw * fh)
        for y in 0..<h {
            for x in 0..<w {
                values[(y + oy) * fw + (x + ox)] = o.depth.values[y * w + x]
            }
        }
        let cam = o.fullFrameCamera.scaled(toWidth: fw, height: fh)
        return DepthMap(width: fw, height: fh, values: values, camera: cam, timestamp: o.depth.timestamp)
    }

    static func centerCrop(_ size: CGSize, aspect: Double) -> CGRect {
        let a = Double(size.width) / Double(size.height)
        if a > aspect {
            let w = Double(size.height) * aspect
            return CGRect(x: (Double(size.width) - w) / 2, y: 0, width: w, height: Double(size.height))
        } else {
            let h = Double(size.width) / aspect
            return CGRect(x: 0, y: (Double(size.height) - h) / 2, width: Double(size.width), height: h)
        }
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: inputWidth,
                kCVPixelBufferHeightKey as String: inputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var buf: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf) == kCVReturnSuccess, let buf else {
            throw MoGePostprocessError.invalidShape
        }
        return buf
    }

    /// MLMultiArray（FP32/FP16、ストライド付き）を連続した Float 配列にする。
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)
        if a.dataType == .float32 {
            return a.withUnsafeBufferPointer(ofType: Float.self) { p in
                MoGeRawOutput.repack(p.baseAddress!, shape: shape, strides: strides)
            }
        }
        var tmp = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { tmp[i] = a[i].floatValue }
        return tmp
    }
}
