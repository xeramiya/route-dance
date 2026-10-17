import Foundation

/// 予測を計画の時間格子に並べ直したもの。衝突確率の計算を速くするため、平坦な配列で持つ。
public struct ForecastGrid: Sendable {
    public let dt: Double
    public let steps: Int
    public let people: [Person]
    /// 時刻 index i の重み。厳密な制約の区間（~hardHorizon）は 1、それ以降は指数で下がる（ソフト項の時間割引）。
    public let timeWeight: [Double]
    /// 厳密な制約を課す最後の時刻 index（この index まで含む）。
    public let hardSteps: Int

    public struct Person: Sendable {
        public var id: Int
        /// positions[k * (steps + 1) + i] = サンプル k の時刻 i·dt での位置。
        public var positions: [Vec2]
        public var weights: [Double]
        /// 等方の近似 σ（表示用・互換用）。
        public var sigma: [Double]
        /// 進行方向の σ_∥ と、それに直交する σ_⊥（時刻 i·dt）。
        public var sigmaAlong: [Double]
        public var sigmaCross: [Double]
        /// サンプルごとの進行方向（単位ベクトル）。ほぼ止まっているサンプルは .zero（等方として扱う）。
        public var sampleDirections: [Vec2]
        /// 時刻 i·dt での予測の信頼度（ホライズン N を過ぎると下がる）。
        public var trust: [Double]
        public var sampleCount: Int { weights.count }
        /// 全サンプル・全時刻を含む円（枝刈り用）。
        public var boundCenter: Vec2
        public var boundRadius: Double
    }

    /// - Parameters:
    ///   - horizonFalloff: N を過ぎてから信頼度が 1/e になるまでの秒数。
    ///   - hardHorizon: 厳密な制約を課す時間（秒）。
    ///   - softDecay: hardHorizon を過ぎてからリスクの重みが 1/e になるまでの秒数。
    public init(
        forecasts: [PedestrianForecast], dt: Double, duration: Double, horizonFalloff: Double = 0.7,
        hardHorizon: Double = 3.0, softDecay: Double = 2.0
    ) {
        self.dt = dt
        steps = max(1, Int((duration / dt).rounded()))
        let n = steps + 1
        hardSteps = min(steps, Int((hardHorizon / dt).rounded()))
        timeWeight = (0..<n).map { i in
            let t = Double(i) * dt
            return t <= hardHorizon + 1e-9 ? 1 : exp(-(t - hardHorizon) / softDecay)
        }
        let span = Double(steps) * dt
        people = forecasts.map { f in
            var pos: [Vec2] = []
            pos.reserveCapacity(f.samples.count * n)
            var perTime: [[Vec2]] = []
            for i in 0..<n { perTime.append(f.positions(at: Double(i) * dt)) }
            for k in 0..<f.samples.count {
                for i in 0..<n { pos.append(perTime[i][k]) }
            }
            let sigma = (0..<n).map { f.sigma(at: Double($0) * dt) }
            let along = (0..<n).map { max(f.sigmaAlong(at: Double($0) * dt), 0.03) }
            let cross = (0..<n).map { max(f.sigmaCross(at: Double($0) * dt), 0.03) }
            let trust = (0..<n).map { i -> Double in
                let t = Double(i) * dt
                return t <= f.horizon ? 1 : exp(-(t - f.horizon) / horizonFalloff)
            }
            // サンプルの進行方向: 全区間の変位の向き。ほぼ動かないサンプルは等方。
            var dirs: [Vec2] = []
            for k in 0..<f.samples.count {
                let disp = pos[k * n + n - 1] - pos[k * n]
                dirs.append(disp.length / max(span, 1e-6) > 0.12 ? disp.normalized : .zero)
            }
            var c = Vec2.zero
            for p in pos { c += p }
            c /= Double(max(pos.count, 1))
            var r = 0.0
            for p in pos { r = max(r, (p - c).length) }
            r += max(along.max() ?? 0, cross.max() ?? 0) * 3
            return Person(
                id: f.id, positions: pos, weights: f.weights, sigma: sigma, sigmaAlong: along, sigmaCross: cross,
                sampleDirections: dirs, trust: trust, boundCenter: c, boundRadius: r
            )
        }
    }
}

/// 経路全体のリスク。厳密な制約の区間（hard）と、時間割引つきの全区間（soft）に分けて持つ。
public struct PathRisk: Sendable {
    /// 人ごとの衝突確率。hard は厳密な制約の区間のみ、soft は全区間（hard 以降は時間割引）。
    public var perPersonHard: [Double]
    public var perPersonSoft: [Double]
    /// 全員に対する非衝突確率（人どうしは独立）。
    public var pSafeHard: Double
    public var pSafeSoft: Double
}

/// 衝突確率のモデル。
///
/// 他歩行者のサンプル k の位置 s_k(t) の周りに異方ガウスの不確かさを置き、ユーザーとの距離が R 未満になる確率を
/// Φ((R − d) / σ_eff) で近似する。σ_eff は、相手サンプルからユーザーへ向かうベクトルと相手の進行方向のなす角 φ で
/// σ_eff² = σ_∥² cos²φ + σ_⊥² sin²φ。
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

    /// サンプル k（時刻 index i）との衝突確率への寄与（信頼度・時間重みは含まない）。
    @inline(__always)
    private func contribution(_ person: ForecastGrid.Person, sample k: Int, index base: Int, i: Int, user x: Vec2) -> Double {
        let dv = x - person.positions[base + i]
        let d2 = dv.lengthSquared
        let d = d2.squareRoot()
        let b = person.sigmaCross[i]
        var s = b
        let dir = person.sampleDirections[k]
        if d2 > 1e-8, dir.x != 0 || dir.y != 0 {
            let dot = dv.dot(dir)
            let c2 = dot * dot / d2
            let a = person.sigmaAlong[i]
            s = (a * a * c2 + b * b * (1 - c2)).squareRoot()
        }
        return phi((radius - d) / s)
    }

    /// 時刻 index i に点 x にいるときの瞬間の衝突確率。
    /// - Parameter applyTimeWeight: true なら、厳密な制約の区間より先を時間割引する（速度プロファイルの最適化用）。
    public func pointRisk(_ x: Vec2, timeIndex i: Int, grid: ForecastGrid, applyTimeWeight: Bool = false) -> Double {
        var safe = 1.0
        let n = grid.steps + 1
        let ii = min(max(i, 0), grid.steps)
        let w = applyTimeWeight ? grid.timeWeight[ii] : 1
        for person in grid.people {
            if (x - person.boundCenter).length > person.boundRadius + radius { continue }
            var p = 0.0
            for k in 0..<person.sampleCount {
                p += person.weights[k] * contribution(person, sample: k, index: k * n, i: ii, user: x)
            }
            safe *= 1 - min(1, p * person.trust[ii] * w)
        }
        return 1 - safe
    }

    /// 軌道全体（時刻 index 0...m）のリスク。人ごと・サンプルごとに時刻方向の最大を取り、人どうしは独立とする。
    public func pathRisk(_ path: [Vec2], grid: ForecastGrid) -> PathRisk {
        let n = grid.steps + 1
        let m = min(path.count, n)
        let hardEnd = min(grid.hardSteps, m - 1)
        var safeHard = 1.0, safeSoft = 1.0
        var perHard: [Double] = [], perSoft: [Double] = []
        perHard.reserveCapacity(grid.people.count)
        perSoft.reserveCapacity(grid.people.count)
        for person in grid.people {
            // 枝刈り: 経路のどの点も束縛円から十分離れていれば 0。
            var near = false
            for x in path where (x - person.boundCenter).length <= person.boundRadius + radius {
                near = true
                break
            }
            guard near else {
                perHard.append(0)
                perSoft.append(0)
                continue
            }
            var pHard = 0.0, pSoft = 0.0
            for k in 0..<person.sampleCount {
                var worstHard = 0.0, worstSoft = 0.0
                let base = k * n
                for i in 0..<m {
                    let c = contribution(person, sample: k, index: base, i: i, user: path[i]) * person.trust[i]
                    if i <= hardEnd, c > worstHard { worstHard = c }
                    let cs = c * grid.timeWeight[i]
                    if cs > worstSoft { worstSoft = cs }
                }
                pHard += person.weights[k] * worstHard
                pSoft += person.weights[k] * worstSoft
            }
            pHard = min(1, pHard)
            pSoft = min(1, pSoft)
            perHard.append(pHard)
            perSoft.append(pSoft)
            safeHard *= 1 - pHard
            safeSoft *= 1 - pSoft
        }
        return PathRisk(perPersonHard: perHard, perPersonSoft: perSoft, pSafeHard: safeHard, pSafeSoft: safeSoft)
    }

    /// 軌道全体の非衝突確率（時間割引つきの全区間）。互換のための薄いラッパー。
    public func pathSafety(_ path: [Vec2], grid: ForecastGrid) -> (pSafe: Double, perPerson: [Double]) {
        let r = pathRisk(path, grid: grid)
        return (r.pSafeSoft, r.perPersonSoft)
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
