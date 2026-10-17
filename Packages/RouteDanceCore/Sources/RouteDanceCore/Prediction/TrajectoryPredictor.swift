import Foundation

/// 他歩行者1人分の予測。重み付きのサンプル軌道の集合で表す（学習モデルのK個の未来とも同じ形）。
public struct PedestrianForecast: Sendable, Identifiable {
    public var id: Int
    /// 現在位置（地面座標）。
    public var position: Vec2
    public var velocity: Vec2
    /// 予測の時刻（秒、0 = 現在）。すべてのサンプルで共通。
    public var times: [Double]
    /// samples[k][i] は、サンプル k の時刻 times[i] での位置。
    public var samples: [[Vec2]]
    public var weights: [Double]
    /// 時刻 times[i] での位置の不確かさ（標準偏差、m）。サンプルの周りに加える。
    public var sigma: [Double]
    /// CPAベースの表示ホライズン N（秒）。
    public var horizon: Double
    /// ユーザーとの最接近時刻と距離（等速を仮定）。
    public var timeToClosestApproach: Double
    public var closestApproachDistance: Double

    /// 時刻 t での各サンプル位置（線形補間）。
    public func positions(at t: Double) -> [Vec2] {
        guard let last = times.last, !times.isEmpty else { return [] }
        let tt = min(max(t, 0), last)
        let step = times.count > 1 ? times[1] - times[0] : 1
        let f = tt / step
        let i0 = min(Int(f), times.count - 1)
        let i1 = min(i0 + 1, times.count - 1)
        let a = f - Double(i0)
        return samples.map { s in s[i0] * (1 - a) + s[i1] * a }
    }

    public func sigma(at t: Double) -> Double {
        guard !sigma.isEmpty else { return 0 }
        let step = times.count > 1 ? times[1] - times[0] : 1
        let i = min(max(Int((t / step).rounded()), 0), sigma.count - 1)
        return sigma[i]
    }
}

public protocol TrajectoryPredictor: Sendable {
    var name: String { get }
    /// - Parameters:
    ///   - tracks: 予測対象（地面座標）。
    ///   - userVelocity: ユーザーの速度（地面座標）。ホライズンの計算に使う。
    ///   - duration: サンプル軌道を何秒先まで作るか（計画のホライズン以上）。
    func predict(tracks: [Track], userVelocity: Vec2, duration: Double) -> [PedestrianForecast]
}

/// 最接近時刻(CPA)ベースの可変ホライズン。
///
/// 相対位置 p、相対速度 v について t_cpa = max(0, −p·v / |v|²) とし、
/// N = clamp(t_cpa + τ, N_min, N_max)。相対速度がほぼ0のときは N = clamp(d / max(v_user, v_floor), …)。
public struct CPAHorizon: Sendable {
    public var tau = 1.0
    public var minHorizon = 1.0
    public var maxHorizon = 6.0
    public var speedFloor = 0.5
    public var relativeSpeedEpsilon = 0.15

    public init() {}

    public struct Result: Sendable, Equatable {
        public var horizon: Double
        public var tCPA: Double
        public var dCPA: Double
    }

    public func evaluate(relativePosition p: Vec2, relativeVelocity v: Vec2, userSpeed: Double) -> Result {
        let v2 = v.lengthSquared
        let tCPA: Double
        if v2 < relativeSpeedEpsilon * relativeSpeedEpsilon {
            tCPA = p.length / max(userSpeed, speedFloor)
            return Result(horizon: clamp(tCPA), tCPA: tCPA, dCPA: p.length)
        }
        tCPA = max(0, -p.dot(v) / v2)
        let dCPA = (p + v * tCPA).length
        return Result(horizon: clamp(tCPA + tau), tCPA: tCPA, dCPA: dCPA)
    }

    private func clamp(_ x: Double) -> Double { min(max(x, minHorizon), maxHorizon) }
}

/// 等速度モデル（CVM）にサンプルを加えたもの。
///
/// Schöller et al. (RA-L 2020) の CVM-S と同じ考え方で、速度の向きと速さに摂動を加えたK本のサンプル軌道を作る。
/// 乱数は使わず、決定論的な格子（向き×速さ）で作るので、フレーム間で表示がちらつかない。
public struct ConstantVelocityPredictor: TrajectoryPredictor {
    public var name: String { "CVM-S" }
    public var dt = 0.2
    /// 向きの標準偏差（ラジアン）。止まりかけの人ほど向きが定まらないので速さで割り増す。
    public var headingStd = 0.25
    public var speedRelativeStd = 0.2
    /// 位置の不確かさ σ(t) = σ₀ + k·t。
    public var sigma0 = 0.15
    public var sigmaRate = 0.12
    /// これより遅い人は止まっているとみなす（m/s）。
    public var stationarySpeed = 0.25
    public var horizon = CPAHorizon()

    public init() {}

    // 向き3 × 速さ3 + 中央を厚めに。重みはガウスの格子点。
    private static let grid: [(dh: Double, ds: Double, w: Double)] = {
        let nodes: [(Double, Double)] = [(-1.2, 0.25), (0, 0.5), (1.2, 0.25)]
        var g: [(Double, Double, Double)] = []
        for (h, wh) in nodes {
            for (s, ws) in nodes {
                g.append((h, s, wh * ws))
            }
        }
        // 左右に大きく曲がる可能性（すれ違いで避ける動き）も少し含める。
        g.append((-2.5, 0, 0.03))
        g.append((2.5, 0, 0.03))
        let total = g.reduce(0) { $0 + $1.2 }
        return g.map { ($0.0, $0.1, $0.2 / total) }
    }()

    public func predict(tracks: [Track], userVelocity: Vec2, duration: Double) -> [PedestrianForecast] {
        let steps = max(1, Int((duration / dt).rounded(.up)))
        let times = (0...steps).map { Double($0) * dt }
        let userSpeed = userVelocity.length

        return tracks.map { tr in
            let p0 = tr.position
            let v0 = tr.velocity
            let speed = v0.length
            let h = horizon.evaluate(relativePosition: p0, relativeVelocity: v0 - userVelocity, userSpeed: userSpeed)

            var samples: [[Vec2]] = []
            var weights: [Double] = []
            if speed < stationarySpeed {
                // 止まっている人: 中心のみ。不確かさは σ(t) で表す（どちらに動き出すか分からない）。
                samples = [times.map { _ in p0 }]
                weights = [1]
            } else {
                let heading = v0.heading
                let hStd = min(headingStd * max(1, 0.8 / speed), 0.8)
                for g in Self.grid {
                    let vh = heading + g.dh * hStd
                    let vs = max(0, speed * (1 + g.ds * speedRelativeStd))
                    let v = Vec2.fromHeading(vh, length: vs)
                    samples.append(times.map { p0 + v * $0 })
                    weights.append(g.w)
                }
            }
            let sigma = times.map { sigma0 + sigmaRate * $0 + (speed < stationarySpeed ? 0.25 * $0 : 0) }
            return PedestrianForecast(
                id: tr.id, position: p0, velocity: v0, times: times, samples: samples, weights: weights,
                sigma: sigma, horizon: h.horizon, timeToClosestApproach: h.tCPA, closestApproachDistance: h.dCPA
            )
        }
    }
}
