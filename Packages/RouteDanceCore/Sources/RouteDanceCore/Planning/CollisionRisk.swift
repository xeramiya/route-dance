import Foundation

/// 予測を計画の時間格子に並べ直したもの。衝突確率の計算を速くするため、平坦な配列で持つ。
public struct ForecastGrid: Sendable {
    public let dt: Double
    public let steps: Int
    public let people: [Person]

    public struct Person: Sendable {
        public var id: Int
        /// positions[k * (steps + 1) + i] = サンプル k の時刻 i·dt での位置。
        public var positions: [Vec2]
        public var weights: [Double]
        public var sigma: [Double]
        /// 時刻 i·dt での予測の信頼度（ホライズン N を過ぎると下がる）。
        public var trust: [Double]
        public var sampleCount: Int { weights.count }
        /// 全サンプル・全時刻を含む円（枝刈り用）。
        public var boundCenter: Vec2
        public var boundRadius: Double
    }

    /// - Parameter horizonFalloff: N を過ぎてから信頼度が 1/e になるまでの秒数。
    public init(forecasts: [PedestrianForecast], dt: Double, duration: Double, horizonFalloff: Double = 0.7) {
        self.dt = dt
        steps = max(1, Int((duration / dt).rounded()))
        let n = steps + 1
        people = forecasts.map { f in
            var pos: [Vec2] = []
            pos.reserveCapacity(f.samples.count * n)
            var perTime: [[Vec2]] = []
            for i in 0..<n { perTime.append(f.positions(at: Double(i) * dt)) }
            for k in 0..<f.samples.count {
                for i in 0..<n { pos.append(perTime[i][k]) }
            }
            let sigma = (0..<n).map { f.sigma(at: Double($0) * dt) }
            let trust = (0..<n).map { i -> Double in
                let t = Double(i) * dt
                return t <= f.horizon ? 1 : exp(-(t - f.horizon) / horizonFalloff)
            }
            var c = Vec2.zero
            for p in pos { c += p }
            c /= Double(max(pos.count, 1))
            var r = 0.0
            for p in pos { r = max(r, (p - c).length) }
            r += (sigma.max() ?? 0) * 3
            return Person(id: f.id, positions: pos, weights: f.weights, sigma: sigma, trust: trust, boundCenter: c, boundRadius: r)
        }
    }
}

/// 衝突確率のモデル。
///
/// 他歩行者のサンプル k の位置 s_k(t) の周りに等方ガウス N(0, σ(t)²) の不確かさを置き、
/// ユーザーとの距離が R 未満になる確率を Φ((R − d) / σ) で近似する。
public struct CollisionModel: Sendable {
    /// ユーザーと他歩行者の体の半径の和＋パーソナルスペース（m）。
    public var radius: Double

    public init(radius: Double = 0.6) {
        self.radius = radius
    }

    @inline(__always)
    func phi(_ z: Double) -> Double {
        // 標準正規分布の累積分布関数のロジスティック近似。
        1 / (1 + exp(-1.702 * z))
    }

    /// 時刻 index i に点 x にいるときの瞬間の衝突確率。
    public func pointRisk(_ x: Vec2, timeIndex i: Int, grid: ForecastGrid) -> Double {
        var safe = 1.0
        let n = grid.steps + 1
        let ii = min(max(i, 0), grid.steps)
        for person in grid.people {
            if (x - person.boundCenter).length > person.boundRadius + radius { continue }
            let s = person.sigma[ii]
            var p = 0.0
            for k in 0..<person.sampleCount {
                let d = (person.positions[k * n + ii] - x).length
                p += person.weights[k] * phi((radius - d) / s)
            }
            safe *= 1 - min(1, p * person.trust[ii])
        }
        return 1 - safe
    }

    /// 軌道全体（時刻 index 0...m）の非衝突確率。人ごと・サンプルごとに時刻方向の最大を取り、人どうしは独立とする。
    public func pathSafety(_ path: [Vec2], grid: ForecastGrid) -> (pSafe: Double, perPerson: [Double]) {
        let n = grid.steps + 1
        let m = min(path.count, n)
        var safe = 1.0
        var per: [Double] = []
        per.reserveCapacity(grid.people.count)
        for person in grid.people {
            // 枝刈り: 経路のどの点も束縛円から十分離れていれば 0。
            var near = false
            for x in path where (x - person.boundCenter).length <= person.boundRadius + radius {
                near = true
                break
            }
            guard near else {
                per.append(0)
                continue
            }
            var p = 0.0
            for k in 0..<person.sampleCount {
                var worst = 0.0
                let base = k * n
                for i in 0..<m {
                    let d = (person.positions[base + i] - path[i]).length
                    let c = phi((radius - d) / person.sigma[i]) * person.trust[i]
                    if c > worst { worst = c }
                }
                p += person.weights[k] * worst
            }
            p = min(1, p)
            per.append(p)
            safe *= 1 - p
        }
        return (safe, per)
    }
}

/// デバッグ表示用の「衝突しない確率」のヒートマップ。
///
/// 各セルに、ユーザーが現在の速度でそこへ着く時刻 t = |c| / v を割り当て、その時刻の瞬間の衝突確率を求める。
public struct RiskField: Sendable {
    public var origin: Vec2
    public var cellSize: Double
    public var columns: Int
    public var rows: Int
    /// safety[row * columns + col]（0 = 確実に衝突、1 = 安全）。
    public var safety: [Double]

    public func center(col: Int, row: Int) -> Vec2 {
        origin + Vec2((Double(col) + 0.5) * cellSize, (Double(row) + 0.5) * cellSize)
    }

    public static func compute(
        grid: ForecastGrid, model: CollisionModel, speed: Double,
        xRange: ClosedRange<Double> = -6...6, yRange: ClosedRange<Double> = 0...12, cellSize: Double = 0.4
    ) -> RiskField {
        let cols = Int(((xRange.upperBound - xRange.lowerBound) / cellSize).rounded())
        let rows = Int(((yRange.upperBound - yRange.lowerBound) / cellSize).rounded())
        var f = RiskField(origin: Vec2(xRange.lowerBound, yRange.lowerBound), cellSize: cellSize, columns: cols, rows: rows, safety: [])
        f.safety.reserveCapacity(cols * rows)
        let v = max(speed, 0.3)
        for r in 0..<rows {
            for c in 0..<cols {
                let p = f.center(col: c, row: r)
                let i = Int((p.length / v / grid.dt).rounded())
                f.safety.append(i > grid.steps ? 1 : 1 - model.pointRisk(p, timeIndex: i, grid: grid))
            }
        }
        return f
    }
}
