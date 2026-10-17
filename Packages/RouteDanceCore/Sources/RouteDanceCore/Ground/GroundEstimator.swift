import Foundation
import simd

/// メトリック深度マップ（カメラ座標の点群）から地面平面をRANSACで推定し、時間方向に平滑化する。
public struct GroundEstimator: Sendable {
    public struct Config: Sendable {
        /// 平面からこの距離以内の点をインライアとみなす（m）。
        public var inlierThreshold: Double = 0.06
        public var iterations: Int = 150
        /// 有効なカメラ高さの範囲（m）。
        public var heightRange: ClosedRange<Double> = 0.9...2.0
        /// 法線が重力の事前推定からこの角度以内であること（ラジアン）。
        public var maxNormalDeviation: Double = 25 * .pi / 180
        /// インライア率がこれ未満なら棄却する。
        public var minInlierRatio: Double = 0.15
        /// 平滑化の時定数（秒）。
        public var normalTau: Double = 0.3
        public var heightTau: Double = 1.5
        /// 推定できないときのカメラ高さ。
        public var defaultHeight: Double = 1.45
        public var defaultPitch: Double = 10 * .pi / 180
        public init() {}
    }

    public struct Observation: Sendable {
        public var plane: GroundPlane
        public var inlierRatio: Double
        public var inlierCount: Int
    }

    public var config: Config
    public private(set) var current: GroundPlane
    public private(set) var lastObservation: Observation?
    public private(set) var isConverged = false
    private var heightSmoother: ExponentialSmoother
    private var smoothedNormal: SIMD3<Double>?
    private var lastNormalTime: Double?
    private var rng = SeededRandom(seed: 7)

    public init(config: Config = Config()) {
        self.config = config
        current = .pitched(config.defaultPitch, height: config.defaultHeight)
        heightSmoother = ExponentialSmoother(tau: config.heightTau)
    }

    public mutating func reset() {
        current = .pitched(config.defaultPitch, height: config.defaultHeight)
        heightSmoother.reset()
        smoothedNormal = nil
        lastNormalTime = nil
        isConverged = false
        lastObservation = nil
    }

    /// 重力方向（カメラ座標、下向き）が分かるとき（ライブのCoreMotion）に、法線の事前分布として使う。
    public var gravityPrior: SIMD3<Double>?

    /// 点群（カメラ座標、m）から地面を更新する。点は画面下半分などから事前に間引いておく。
    @discardableResult
    public mutating func update(points: [SIMD3<Double>], at t: Double) -> Observation? {
        guard let obs = fit(points) else { return nil }
        lastObservation = obs

        // 法線の平滑化（単位ベクトルの指数移動平均）。
        if let n0 = smoothedNormal, let lt = lastNormalTime {
            let a = 1 - exp(-max(0, t - lt) / config.normalTau)
            smoothedNormal = simd_normalize(n0 + a * (obs.plane.normal - n0))
        } else {
            smoothedNormal = obs.plane.normal
        }
        lastNormalTime = t
        let h = heightSmoother.update(obs.plane.height, at: t)
        current = GroundPlane(normal: smoothedNormal!, height: h)
        isConverged = true
        return obs
    }

    /// 深度が得られないフレームで、重力だけ分かる場合に法線を更新する。
    public mutating func update(gravity g: SIMD3<Double>, at t: Double) {
        gravityPrior = g
        guard !isConverged else { return }
        current = GroundPlane(normal: -g, height: current.height)
    }

    func priorNormal() -> SIMD3<Double> {
        if let g = gravityPrior { return -simd_normalize(g) }
        return smoothedNormal ?? current.normal
    }

    mutating func fit(_ points: [SIMD3<Double>]) -> Observation? {
        let n = points.count
        guard n >= 30 else { return nil }
        let prior = priorNormal()
        let cosMax = cos(config.maxNormalDeviation)
        var best: (normal: SIMD3<Double>, d: Double, count: Int)?

        for _ in 0..<config.iterations {
            let a = points[Int.random(in: 0..<n, using: &rng)]
            let b = points[Int.random(in: 0..<n, using: &rng)]
            let c = points[Int.random(in: 0..<n, using: &rng)]
            var normal = simd_cross(b - a, c - a)
            let len = simd_length(normal)
            guard len > 1e-6 else { continue }
            normal /= len
            if simd_dot(normal, prior) < 0 { normal = -normal }
            guard simd_dot(normal, prior) >= cosMax else { continue }
            let d = -simd_dot(normal, a)  // normal·X + d = 0, d はカメラ高さ
            guard config.heightRange.contains(d) else { continue }
            var count = 0
            for p in points where abs(simd_dot(normal, p) + d) < config.inlierThreshold {
                count += 1
            }
            if count > (best?.count ?? 0) {
                best = (normal, d, count)
            }
        }
        guard let b = best, Double(b.count) / Double(n) >= config.minInlierRatio else { return nil }

        // インライアで最小二乗の再推定（共分散の最小固有ベクトル）。
        let inliers = points.filter { abs(simd_dot(b.normal, $0) + b.d) < config.inlierThreshold }
        guard let refined = Self.leastSquaresPlane(inliers, hint: b.normal) else {
            return Observation(plane: GroundPlane(normal: b.normal, height: b.d), inlierRatio: Double(b.count) / Double(n), inlierCount: b.count)
        }
        guard config.heightRange.contains(refined.height) else { return nil }
        return Observation(plane: refined, inlierRatio: Double(inliers.count) / Double(n), inlierCount: inliers.count)
    }

    static func leastSquaresPlane(_ pts: [SIMD3<Double>], hint: SIMD3<Double>) -> GroundPlane? {
        guard pts.count >= 3 else { return nil }
        var mean = SIMD3<Double>.zero
        for p in pts { mean += p }
        mean /= Double(pts.count)
        var cov = simd_double3x3()
        for p in pts {
            let d = p - mean
            cov += simd_double3x3(rows: [d * d.x, d * d.y, d * d.z])
        }
        // 最小固有値の固有ベクトルを逆反復法で求める。
        let shifted = cov + simd_double3x3(diagonal: SIMD3(repeating: 1e-9))
        guard abs(shifted.determinant) > 1e-30 else { return nil }
        let inv = shifted.inverse
        var v = hint
        for _ in 0..<20 {
            v = simd_normalize(inv * v)
        }
        if simd_dot(v, hint) < 0 { v = -v }
        return GroundPlane(normal: v, height: -simd_dot(v, mean))
    }
}
