import Foundation

/// 地面上の対応点（前フレームの地面座標 → 現フレームの地面座標）から、フレーム間の剛体変換を推定する。
///
/// 画像だけで自己位置を求める（ライブ映像と動画を同じ処理にするため）。
/// 対応点は、地面マスク上の特徴点をオプティカルフローで追跡し、それぞれのフレームの地面へ投影して作る。
public enum GroundOdometry {
    public struct Correspondence: Sendable {
        public var previous: Vec2
        public var current: Vec2
        public init(previous: Vec2, current: Vec2) {
            self.previous = previous
            self.current = current
        }
    }

    public struct Result: Sendable {
        /// 前フレームの座標を現フレームの座標へ移す変換。
        public var transform: Pose2D
        public var inlierCount: Int
        public var inlierRatio: Double
        public var rmsError: Double
    }

    public struct Config: Sendable {
        public var iterations = 120
        /// インライア判定の距離（m）。遠い点ほど誤差が大きいので、距離に比例した成分も持つ。
        public var inlierBase = 0.05
        public var inlierPerMeter = 0.03
        public var minInliers = 8
        /// フレーム間で許す最大の並進（m）と回転（ラジアン）。
        public var maxTranslation = 0.6
        public var maxRotation = 0.5
        public init() {}
    }

    public static func estimate(
        _ pairs: [Correspondence],
        rotationHint: Double? = nil,
        config: Config = Config(),
        seed: UInt64 = 1
    ) -> Result? {
        let n = pairs.count
        guard n >= max(2, config.minInliers) else { return nil }
        var rng = SeededRandom(seed: seed)
        var bestInliers: [Int] = []

        func isInlier(_ pair: Correspondence, _ t: Pose2D) -> Bool {
            let err = (t.apply(pair.previous) - pair.current).length
            return err < config.inlierBase + config.inlierPerMeter * pair.current.length
        }

        for iter in 0..<config.iterations {
            let model: Pose2D?
            if let hint = rotationHint, iter % 2 == 0 {
                // 回転が分かっている（ジャイロ）なら1点で並進を決められる。
                let p = pairs[Int.random(in: 0..<n, using: &rng)]
                model = Pose2D(rotation: hint, translation: p.current - p.previous.rotated(by: hint))
            } else {
                let i = Int.random(in: 0..<n, using: &rng)
                var j = Int.random(in: 0..<n, using: &rng)
                if i == j { j = (j + 1) % n }
                model = procrustes([pairs[i], pairs[j]])
            }
            guard let m = model, plausible(m, config) else { continue }
            var inliers: [Int] = []
            inliers.reserveCapacity(n)
            for k in 0..<n where isInlier(pairs[k], m) {
                inliers.append(k)
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        guard bestInliers.count >= config.minInliers else { return nil }

        // インライアで最小二乗。もう一度インライアを取り直して再推定する。
        var subset = bestInliers.map { pairs[$0] }
        guard var t = procrustes(subset) else { return nil }
        let refined = pairs.filter { isInlier($0, t) }
        if refined.count >= config.minInliers, let t2 = procrustes(refined) {
            t = t2
            subset = refined
        }
        guard plausible(t, config) else { return nil }
        var sq = 0.0
        for p in subset { sq += (t.apply(p.previous) - p.current).lengthSquared }
        return Result(
            transform: t,
            inlierCount: subset.count,
            inlierRatio: Double(subset.count) / Double(n),
            rmsError: sqrt(sq / Double(subset.count))
        )
    }

    static func plausible(_ t: Pose2D, _ c: Config) -> Bool {
        t.translation.length <= c.maxTranslation && abs(wrapAngle(t.rotation)) <= c.maxRotation
    }

    /// 2D剛体の最小二乗（Kabsch / Procrustes）。遠い点ほど誤差が大きいので距離で重みを下げる。
    static func procrustes(_ pairs: [Correspondence]) -> Pose2D? {
        guard pairs.count >= 2 else { return nil }
        var wsum = 0.0
        var mp = Vec2.zero, mc = Vec2.zero
        var weights: [Double] = []
        weights.reserveCapacity(pairs.count)
        for p in pairs {
            let w = 1 / (1 + 0.2 * p.current.lengthSquared)
            weights.append(w)
            wsum += w
            mp += w * p.previous
            mc += w * p.current
        }
        guard wsum > 0 else { return nil }
        mp /= wsum
        mc /= wsum
        var sdot = 0.0, scross = 0.0
        for (k, p) in pairs.enumerated() {
            let a = p.previous - mp, b = p.current - mc
            sdot += weights[k] * a.dot(b)
            scross += weights[k] * a.cross(b)
        }
        guard abs(sdot) + abs(scross) > 1e-12 else { return nil }
        // a を反時計回りに φ 回すと b に重なる。heading の回転（右回り正）は -φ。
        let phi = atan2(scross, sdot)
        let rot = -phi
        return Pose2D(rotation: rot, translation: mc - mp.rotated(by: rot))
    }
}

/// フレーム間の変換を積み上げて、ユーザーの速度と累積姿勢を求める。
public struct EgoMotionEstimator: Sendable {
    public struct State: Sendable {
        /// 現フレームの地面座標系でのユーザー速度（m/s）。y が前方。
        public var velocity: Vec2
        public var speed: Double
        /// 起動からの累積移動距離（m）。
        public var distance: Double
        /// 最後に自己位置推定が成功してからの経過時間（秒）。
        public var timeSinceLastFix: Double
        public var isTracking: Bool
        /// 前フレームからの経過時間（秒）。
        public var lastFrameInterval: Double
    }

    public var window: Double
    private var history: [(t: Double, toCurrent: Pose2D)] = []
    private var lastTime: Double?
    private var lastFixTime: Double?
    private var distance = 0.0
    private var speedSmoother = ExponentialSmoother(tau: 0.6)

    public init(window: Double = 1.2) {
        self.window = window
    }

    public mutating func reset() {
        history.removeAll()
        lastTime = nil
        lastFixTime = nil
        distance = 0
        speedSmoother.reset()
    }

    /// フレーム間の変換（前→現）を追加する。推定に失敗したフレームは nil を渡す（等速を仮定して補う）。
    public mutating func update(_ delta: Pose2D?, at t: Double) -> State {
        let dt = lastTime.map { max(1e-3, t - $0) } ?? 0
        lastTime = t
        var step = delta
        if step == nil, dt > 0, let v = currentVelocity(), (lastFixTime.map { t - $0 } ?? .infinity) < 1.0 {
            // 等速で外挿する（ユーザーは前方へ v で進むので、世界は -v だけ動く）。
            step = Pose2D(rotation: 0, translation: -v * dt)
        }
        if delta != nil { lastFixTime = t }
        let s = step ?? .identity
        history = history.map { ($0.t, $0.toCurrent.then(s)) }
        history.append((t, .identity))
        history.removeAll { t - $0.t > window }
        if delta != nil { distance += s.translation.length }

        let v = currentVelocity() ?? .zero
        let speed = speedSmoother.update(v.length, at: t)
        return State(
            velocity: v,
            speed: speed,
            distance: distance,
            timeSinceLastFix: lastFixTime.map { t - $0 } ?? .infinity,
            isTracking: (lastFixTime.map { t - $0 } ?? .infinity) < 0.5,
            lastFrameInterval: dt
        )
    }

    /// 窓の先頭時点でのユーザー位置（現在の座標系）から速度を求める。
    private func currentVelocity() -> Vec2? {
        guard let first = history.first, let lt = lastTime, lt - first.t > 0.2 else { return nil }
        // 過去のユーザー位置（その時点の原点）を現在の座標系へ移したもの。
        let past = first.toCurrent.apply(.zero)
        return (Vec2.zero - past) / (lt - first.t)
    }
}
