import CoreImage
import Foundation
import RouteDanceCore

/// 入力フレーム。ライブでも動画でも同じ形にする。
public struct InputFrame: @unchecked Sendable {
    /// 正立した画像（画面に表示する向き）。
    public var image: CIImage
    /// 秒。単調増加であればよい（動画は表示時刻、ライブはキャプチャ時刻）。
    public var timestamp: Double
    /// ライブのみ: 重力（カメラ座標、下向き単位ベクトル）。
    public var gravity: SIMD3<Double>?
    /// 分かっていれば水平画角（ラジアン）。
    public var knownHorizontalFOV: Double?

    public init(image: CIImage, timestamp: Double, gravity: SIMD3<Double>? = nil, knownHorizontalFOV: Double? = nil) {
        self.image = image
        self.timestamp = timestamp
        self.gravity = gravity
        self.knownHorizontalFOV = knownHorizontalFOV
    }
}

/// 1フレームの処理結果（描画用）。
public struct ProcessedFrame: @unchecked Sendable {
    public var image: CIImage
    public var snapshot: NavigationSnapshot
    public var depth: DepthMap?
    public var flowTracks: [(SIMD2<Double>, SIMD2<Double>)]
    public var stats: PipelineStats
}

public struct PipelineStats: Sendable {
    public var detectionMilliseconds: Double = 0
    public var depthMilliseconds: Double = 0
    public var flowMilliseconds: Double = 0
    public var coreMilliseconds: Double = 0
    public var totalMilliseconds: Double = 0
    public var depthAge: Double = .infinity
    public var detectorName = ""
    public var depthAvailable = false
    public var flowPoints = 0
}

/// 知覚（検出・深度・オプティカルフロー）と NavigationCore をつなぐ。
///
/// 深度推定は重い（iPhoneで約55ms）ので、別タスクで約5Hzに間引いて走らせ、終わった結果を次のフレームで使う。
public actor FrameProcessor {
    public struct Config: Sendable {
        public var depthInterval = 0.2
        public var flowWidth = 240
        public var maxFlowPoints = 150
        public init() {}
    }

    public var config: Config
    private var core = NavigationCore()
    private let detector: any PersonDetector
    private var depthEstimators: [Bool: DepthEstimator] = [:]
    private let loadDepth: @Sendable (Bool) throws -> DepthEstimator
    /// 入力のアスペクト比（幅/高さ）に最も近いモデルを読む。nil なら縦横だけで選ぶ。
    private let loadDepthForAspect: (@Sendable (Double) throws -> DepthEstimator)?
    private var depthTask: Task<DepthEstimator.Output?, Never>?
    private var pendingDepth: (output: DepthEstimator.Output, width: Int, height: Int)?
    private var lastDepthStart = -Double.infinity
    private var latestDepth: DepthMap?
    private var lastDepthMs = 0.0
    private var depthError: String?

    private let flow = SparseOpticalFlow()
    private var previousPyramid: [GrayImage]?
    private var previousFeatures: [SIMD2<Float>] = []
    private var flowScale = 1.0
    private var lastSnapshot: NavigationSnapshot?
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init(
        config: Config = Config(),
        detector: any PersonDetector = VisionPersonDetector(),
        loadDepth: @escaping @Sendable (Bool) throws -> DepthEstimator = { try DepthEstimator.bundled(portrait: $0) },
        loadDepthForAspect: (@Sendable (Double) throws -> DepthEstimator)? = { try DepthEstimator.bundled(aspect: $0) }
    ) {
        self.config = config
        self.detector = detector
        self.loadDepth = loadDepth
        self.loadDepthForAspect = loadDepthForAspect
    }

    public func reset() {
        core.reset()
        depthTask?.cancel()
        depthTask = nil
        pendingDepth = nil
        latestDepth = nil
        previousPyramid = nil
        previousFeatures = []
        lastSnapshot = nil
        lastDepthStart = -.infinity
    }

    public var depthStatus: String? { depthError }

    public func process(_ frame: InputFrame) async -> ProcessedFrame {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var stats = PipelineStats()
        stats.detectorName = detector.name
        let image = frame.image
        let w = Int(image.extent.width), h = Int(image.extent.height)

        // 深度: 終わっていれば取り込み、間隔が空いていれば次を始める。
        var newDepth: DepthMap?
        if let p = pendingDepth {
            newDepth = DepthEstimator.fullFrameSampler(p.output, imageWidth: p.width, imageHeight: p.height)
            latestDepth = newDepth
            lastDepthMs = p.output.inferenceMilliseconds
            pendingDepth = nil
        }
        if depthTask == nil, frame.timestamp - lastDepthStart >= config.depthInterval {
            startDepth(image: image, timestamp: frame.timestamp, fov: frame.knownHorizontalFOV, width: w, height: h)
        }
        stats.depthMilliseconds = lastDepthMs
        stats.depthAvailable = latestDepth != nil
        stats.depthAge = latestDepth.map { frame.timestamp - $0.timestamp } ?? .infinity

        // 人物検出（毎フレーム）
        let td = DispatchTime.now().uptimeNanoseconds
        let detections = (try? await detector.detect(image)) ?? []
        stats.detectionMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - td) / 1e6

        // オプティカルフロー（地面上の点）
        let tf = DispatchTime.now().uptimeNanoseconds
        let pairs = trackFlow(image: image, detections: detections, width: w, height: h)
        stats.flowMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - tf) / 1e6
        stats.flowPoints = pairs.count

        let tc = DispatchTime.now().uptimeNanoseconds
        let input = PerceptionInput(
            timestamp: frame.timestamp, imageWidth: w, imageHeight: h, depth: newDepth, detections: detections,
            flowPairs: pairs.map { (previous: $0.0, current: $0.1) },
            gravity: frame.gravity, knownHorizontalFOV: frame.knownHorizontalFOV
        )
        let snapshot = core.process(input)
        lastSnapshot = snapshot
        stats.coreMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - tc) / 1e6
        stats.totalMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ProcessedFrame(image: image, snapshot: snapshot, depth: latestDepth, flowTracks: pairs, stats: stats)
    }

    private func startDepth(image: CIImage, timestamp: Double, fov: Double?, width: Int, height: Int) {
        let portrait = height >= width
        let cached = depthEstimators[portrait]
        let load = loadDepth
        let loadAspect = loadDepthForAspect
        let aspect = Double(width) / Double(height)
        lastDepthStart = timestamp
        // モデルの読み込み（初回は数秒）と推論は actor の外で行い、フレーム処理を止めない。
        let task = Task.detached(priority: .userInitiated) { () -> (DepthEstimator?, DepthEstimator.Output?, String?) in
            let estimator: DepthEstimator
            if let cached {
                estimator = cached
            } else {
                do {
                    estimator = try (try? loadAspect?(aspect)) ?? load(portrait)
                } catch {
                    return (nil, nil, "深度モデルを読み込めません: \(error)")
                }
            }
            do {
                return (estimator, try estimator.estimate(image, timestamp: timestamp, knownHorizontalFOV: fov), nil)
            } catch {
                return (estimator, nil, "深度推定に失敗: \(error)")
            }
        }
        depthTask = Task { await task.value.1 }
        Task {
            let (estimator, out, error) = await task.value
            self.finishDepth(out, estimator: estimator, portrait: portrait, error: error, width: width, height: height)
        }
    }

    private func finishDepth(_ out: DepthEstimator.Output?, estimator: DepthEstimator?, portrait: Bool, error: String?, width: Int, height: Int) {
        depthTask = nil
        if let estimator { depthEstimators[portrait] = estimator }
        if let error {
            depthError = error
            if estimator == nil { lastDepthStart = .infinity }  // 読み込めないモデルは再試行しない
        } else {
            depthError = nil
        }
        if let out { pendingDepth = (out, width, height) }
    }

    /// 縮小したグレー画像で Lucas-Kanade を行い、元画像のピクセル座標の対応を返す。
    private func trackFlow(image: CIImage, detections: [PersonDetection], width: Int, height: Int) -> [(SIMD2<Double>, SIMD2<Double>)] {
        let fw = config.flowWidth
        let scale = Double(fw) / Double(width)
        let fh = Int(Double(height) * scale)
        guard let gray = renderGray(image, width: fw, height: fh) else { return [] }
        let pyr = flow.pyramid(gray)
        defer { previousPyramid = pyr }

        var pairs: [(SIMD2<Double>, SIMD2<Double>)] = []
        var survivors: [SIMD2<Float>] = []
        if let prev = previousPyramid, prev[0].width == fw, prev[0].height == fh, !previousFeatures.isEmpty {
            let tracked = flow.track(points: previousFeatures, prev: prev, next: pyr)
            for (p, q) in zip(previousFeatures, tracked) {
                guard let q else { continue }
                pairs.append((SIMD2(Double(p.x), Double(p.y)) / scale, SIMD2(Double(q.x), Double(q.y)) / scale))
                survivors.append(q)
            }
        }

        // 次のフレーム用に特徴点を選び直す（地平線より下、人物の枠の外）。
        let horizon = lastSnapshot?.geometry.horizonY.map { $0 * scale } ?? Double(fh) * 0.4
        let minY = Int(max(horizon + 6, Double(fh) * 0.3))
        let boxes = detections.map { d in
            (d.minX * scale - 4, d.minY * scale - 4, d.maxX * scale + 4, d.maxY * scale + 4)
        }
        previousFeatures = flow.selectFeatures(in: gray, spacing: 10, maxCount: config.maxFlowPoints) { x, y in
            guard y >= minY else { return false }
            let fx = Double(x), fy = Double(y)
            return !boxes.contains { fx >= $0.0 && fx <= $0.2 && fy >= $0.1 && fy <= $0.3 }
        }
        return pairs
    }

    private func renderGray(_ image: CIImage, width: Int, height: Int) -> GrayImage? {
        let sx = Double(width) / image.extent.width, sy = Double(height) / image.extent.height
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { p in
            context.render(
                scaled, toBitmap: p.baseAddress!, rowBytes: width,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
            )
        }
        // CoreImage の原点は左下なので、行を上下反転して左上原点にする。
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let src = (height - 1 - y) * width
            for x in 0..<width { px[y * width + x] = Float(bytes[src + x]) / 255 }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }
}
