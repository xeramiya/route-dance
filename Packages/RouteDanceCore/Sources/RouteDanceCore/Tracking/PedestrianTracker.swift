import Foundation
import simd

/// 地面座標での定速カルマンフィルタ。状態は [x, y, vx, vy]。
public struct GroundKalman: Sendable {
    public var x: SIMD4<Double>
    public var P: simd_double4x4
    /// 加速度のスペクトル密度（m²/s³）。歩行者の向きや速さの変化の大きさ。
    public var accelNoise: Double

    public init(position: Vec2, variance: Double, accelNoise: Double = 0.8) {
        x = SIMD4(position.x, position.y, 0, 0)
        P = simd_double4x4(diagonal: SIMD4(variance, variance, 1.0, 1.0))
        self.accelNoise = accelNoise
    }

    public var position: Vec2 { Vec2(x[0], x[1]) }
    public var velocity: Vec2 { Vec2(x[2], x[3]) }
    public var positionCovariance: simd_double2x2 {
        simd_double2x2(rows: [SIMD2(P[0][0], P[1][0]), SIMD2(P[0][1], P[1][1])])
    }

    public mutating func predict(dt: Double) {
        guard dt > 0 else { return }
        var F = matrix_identity_double4x4
        F[2][0] = dt  // 列優先: F[col][row]
        F[3][1] = dt
        x = F * x
        let q = accelNoise
        let dt2 = dt * dt, dt3 = dt2 * dt / 2, dt4 = dt2 * dt2 / 4
        var Q = simd_double4x4()
        Q[0][0] = dt4 * q; Q[1][1] = dt4 * q
        Q[2][0] = dt3 * q; Q[0][2] = dt3 * q
        Q[3][1] = dt3 * q; Q[1][3] = dt3 * q
        Q[2][2] = dt2 * q; Q[3][3] = dt2 * q
        P = F * P * F.transpose + Q
    }

    /// 自己位置の変化（前→現）を状態に適用する。
    public mutating func transform(_ t: Pose2D) {
        let p = t.apply(position)
        let v = t.applyVector(velocity)
        x = SIMD4(p.x, p.y, v.x, v.y)
        // 回転を共分散にも適用する。
        let c = cos(t.rotation), s = sin(t.rotation)
        // Vec2.rotated と同じ行列 [[c, s], [-s, c]]（行優先）
        var R = matrix_identity_double4x4
        R[0][0] = c; R[1][0] = s; R[0][1] = -s; R[1][1] = c
        R[2][2] = c; R[3][2] = s; R[2][3] = -s; R[3][3] = c
        P = R * P * R.transpose
    }

    /// 位置の観測で更新する。R は観測の共分散。
    public mutating func update(position z: Vec2, covariance R: simd_double2x2) {
        let innov = z - position
        let S = positionCovariance + R
        guard abs(S.determinant) > 1e-12 else { return }
        let Sinv = S.inverse
        // K = P Hᵀ S⁻¹（H は位置を取り出す 2x4）
        var K = [SIMD2<Double>](repeating: .zero, count: 4)  // 行 i の 1x2
        for i in 0..<4 {
            let ph = SIMD2(P[0][i], P[1][i])  // P の (i, 0), (i, 1)
            K[i] = SIMD2(ph.x * Sinv[0][0] + ph.y * Sinv[0][1], ph.x * Sinv[1][0] + ph.y * Sinv[1][1])
        }
        for i in 0..<4 {
            x[i] += K[i].x * innov.x + K[i].y * innov.y
        }
        // P = (I - K H) P
        var newP = P
        for i in 0..<4 {
            for j in 0..<4 {
                newP[j][i] = P[j][i] - (K[i].x * P[j][0] + K[i].y * P[j][1])
            }
        }
        P = newP
    }

    /// 観測とのマハラノビス距離の2乗。
    public func mahalanobis2(_ z: Vec2, covariance R: simd_double2x2) -> Double {
        let S = positionCovariance + R
        guard abs(S.determinant) > 1e-12 else { return .infinity }
        let d = z - position
        return simd_dot(d, S.inverse * d)
    }
}

public struct Track: Sendable, Identifiable {
    public enum State: String, Sendable { case tentative, confirmed, lost }

    public let id: Int
    public var filter: GroundKalman
    public var state: State
    public var lastDetection: PersonDetection?
    public var hits: Int
    public var age: Double
    public var timeSinceUpdate: Double
    /// 直近の観測位置の履歴（現フレームの座標系、デバッグ表示用）。
    public var history: [TimedPoint]

    public var position: Vec2 { filter.position }
    public var velocity: Vec2 { filter.velocity }
}

/// ByteTrack方式の多人数追跡（地面座標）。
public struct PedestrianTracker: Sendable {
    public struct Config: Sendable {
        public var highScore = 0.5
        public var lowScore = 0.15
        /// 割り当てを許すマハラノビス距離の2乗（χ²の自由度2で99%は9.21）。
        public var gate = 9.21
        public var iouWeight = 2.0
        public var confirmHits = 3
        public var maxLostTime = 1.0
        public var maxTentativeTime = 0.4
        /// 速度の上限（m/s）。走っている人を含めた目安。
        public var maxSpeed = 3.5
        public var historyLength = 3.0
        public init() {}
    }

    public var config: Config
    public private(set) var tracks: [Track] = []
    private var nextID = 1
    private var lastTime: Double?

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        tracks.removeAll()
        lastTime = nil
    }

    /// 1フレーム分の更新。
    /// - Parameters:
    ///   - egoDelta: 前フレームから現フレームへの地面座標の変換（自己位置推定の結果）。
    ///   - persons: 現フレームで位置推定できた人物。
    @discardableResult
    public mutating func update(persons: [LocalizedPerson], egoDelta: Pose2D, at t: Double) -> [Track] {
        let dt = lastTime.map { max(0, t - $0) } ?? 0
        lastTime = t

        for i in tracks.indices {
            tracks[i].filter.transform(egoDelta)
            tracks[i].history = tracks[i].history.map { TimedPoint(t: $0.t, p: egoDelta.apply($0.p)) }
            tracks[i].filter.predict(dt: dt)
            tracks[i].age += dt
            tracks[i].timeSinceUpdate += dt
        }

        let high = persons.indices.filter { persons[$0].detection.confidence >= config.highScore }
        let low = persons.indices.filter {
            persons[$0].detection.confidence < config.highScore && persons[$0].detection.confidence >= config.lowScore
        }

        // 1段目: 確定・見失い中のトラックと高スコア検出。
        var unmatchedTracks = Array(tracks.indices)
        var unmatchedHigh = high
        let first = associate(trackIdx: unmatchedTracks, detIdx: unmatchedHigh, persons: persons)
        for (ti, di) in first {
            apply(person: persons[di], to: ti, at: t)
        }
        unmatchedTracks.removeAll { ti in first.contains { $0.0 == ti } }
        unmatchedHigh.removeAll { di in first.contains { $0.1 == di } }

        // 2段目: 残りの確定トラックと低スコア検出。
        let confirmedLeft = unmatchedTracks.filter { tracks[$0].state != .tentative }
        let second = associate(trackIdx: confirmedLeft, detIdx: low, persons: persons)
        for (ti, di) in second {
            apply(person: persons[di], to: ti, at: t)
        }
        unmatchedTracks.removeAll { ti in second.contains { $0.0 == ti } }

        for ti in unmatchedTracks where tracks[ti].state == .confirmed {
            tracks[ti].state = .lost
        }

        // 新規トラック（高スコアのみ）。
        for di in unmatchedHigh {
            let p = persons[di]
            var f = GroundKalman(position: p.position, variance: max(p.rangeVariance, p.lateralVariance))
            f.P[2][2] = 1.0
            f.P[3][3] = 1.0
            tracks.append(Track(
                id: nextID, filter: f, state: .tentative, lastDetection: p.detection,
                hits: 1, age: 0, timeSinceUpdate: 0, history: [TimedPoint(t: t, p: p.position)]
            ))
            nextID += 1
        }

        // 削除と速度の上限。
        tracks.removeAll { tr in
            (tr.state == .tentative && tr.timeSinceUpdate > config.maxTentativeTime)
                || tr.timeSinceUpdate > config.maxLostTime
        }
        for i in tracks.indices {
            let v = tracks[i].filter.velocity
            if v.length > config.maxSpeed {
                let c = v.normalized * config.maxSpeed
                tracks[i].filter.x[2] = c.x
                tracks[i].filter.x[3] = c.y
            }
        }
        return tracks
    }

    /// 予測や計画に使うトラック（確定済みで、見失って間もないもの）。
    public var activeTracks: [Track] {
        tracks.filter { $0.state == .confirmed || ($0.state == .lost && $0.timeSinceUpdate < 0.5) }
    }

    private mutating func apply(person p: LocalizedPerson, to ti: Int, at t: Double) {
        let R = observationCovariance(p)
        tracks[ti].filter.update(position: p.position, covariance: R)
        tracks[ti].lastDetection = p.detection
        tracks[ti].hits += 1
        tracks[ti].timeSinceUpdate = 0
        if tracks[ti].state == .tentative, tracks[ti].hits >= config.confirmHits {
            tracks[ti].state = .confirmed
        } else if tracks[ti].state == .lost {
            tracks[ti].state = .confirmed
        }
        tracks[ti].history.append(TimedPoint(t: t, p: p.position))
        tracks[ti].history.removeAll { t - $0.t > config.historyLength }
    }

    /// 距離方向と横方向の分散から、地面座標の共分散を作る。
    func observationCovariance(_ p: LocalizedPerson) -> simd_double2x2 {
        let r = p.position.normalized
        guard r != .zero else {
            return simd_double2x2(diagonal: SIMD2(p.rangeVariance, p.rangeVariance))
        }
        let l = Vec2(r.y, -r.x)
        let a = p.rangeVariance, b = p.lateralVariance
        // R = a r rᵀ + b l lᵀ
        let m00 = a * r.x * r.x + b * l.x * l.x
        let m01 = a * r.x * r.y + b * l.x * l.y
        let m11 = a * r.y * r.y + b * l.y * l.y
        return simd_double2x2(rows: [SIMD2(m00, m01), SIMD2(m01, m11)])
    }

    private func associate(trackIdx: [Int], detIdx: [Int], persons: [LocalizedPerson]) -> [(Int, Int)] {
        guard !trackIdx.isEmpty, !detIdx.isEmpty else { return [] }
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: detIdx.count), count: trackIdx.count)
        for (a, ti) in trackIdx.enumerated() {
            let tr = tracks[ti]
            for (b, di) in detIdx.enumerated() {
                let p = persons[di]
                let m2 = tr.filter.mahalanobis2(p.position, covariance: observationCovariance(p))
                guard m2 < config.gate else { continue }
                let iou = tr.lastDetection.map { $0.iou(p.detection) } ?? 0
                cost[a][b] = m2 / config.gate + config.iouWeight * (1 - iou) * 0.5
            }
        }
        return hungarianAssignment(cost, threshold: 1 + config.iouWeight * 0.5 + 1e-9)
            .map { (trackIdx[$0.row], detIdx[$0.col]) }
    }
}
