import Foundation

/// 推奨経路。
public struct PlannedPath: Sendable {
    /// 時刻 i·dt での位置（地面座標）。等間隔の時刻ではなく、速度プロファイルに沿った時刻。
    public var points: [Vec2]
    /// 各点での速度比 v(s) / v_current（1 = 現在の速度で通れる、0 = 停止）。
    public var speedRatio: [Double]
    /// 各点までの経路長（m）。
    public var arcLength: [Double]
    public var pSafe: Double
    /// 経路の形の識別子（候補の曲率の組）。ヒステリシスに使う。
    public var shape: PathShape
    public var requiresSlowdown: Bool
    /// コンパス矢印が指す地面上の点。
    public var lookahead: Vec2
    public var lookaheadHeading: Double { lookahead.heading }
}

/// 候補経路の形: 前半の曲率と後半の曲率（1/m）。
public struct PathShape: Sendable, Equatable, Hashable {
    public var k1: Double
    public var k2: Double
    public var switchFraction: Double
}

public struct PlannerOutput: Sendable {
    public var best: PlannedPath
    /// デバッグ表示用の候補（点列と非衝突確率）。
    public var candidates: [(points: [Vec2], pSafe: Double)]
    public var goal: Vec2
    public var planningSpeed: Double
}

/// 一定速度でのサンプリング型経路計画（DWA / state lattice 系）＋必要時のみの減速（パス-速度分解）。
public struct PathPlanner: Sendable {
    public struct Config: Sendable {
        /// 経路を表示・評価する時間（秒）。経路長は v · horizon。
        public var horizon = 5.0
        public var dt = 0.2
        /// 停止中も経路が見えるよう、計画に使う速度の下限（m/s）。
        public var minPlanningSpeed = 0.5
        public var maxPlanningSpeed = 2.5
        /// 曲率の候補（1/m）。歩行者は急に曲がれるので広めに取る。
        public var curvatures: [Double] = [-0.8, -0.5, -0.3, -0.18, -0.1, -0.05, 0, 0.05, 0.1, 0.18, 0.3, 0.5, 0.8]
        public var switchFractions: [Double] = [0.35, 0.6, 1.0]
        /// 現在速度の経路でこの非衝突確率に届かなければ減速を検討する。
        public var acceptSafety = 0.9
        public var wRisk = 6.0
        public var wGoal = 1.0
        public var wSmooth = 0.4
        public var wCurvature = 0.3
        /// 減速を検討する上位の経路の数。
        public var slowdownCandidates = 3
        /// 速度プロファイルのDPで残すノード数（計算量の上限）。
        public var slowdownBeam = 120
        /// 速度プロファイルの離散化（速度比の段階）。
        public var speedLevels: [Double] = [1.0, 0.85, 0.7, 0.55, 0.4, 0.25, 0.1, 0.0]
        /// 1ステップあたりに変えられる速度比の上限（加減速の滑らかさ）。
        public var maxSpeedLevelJump = 2
        /// コンパスの先読み時間（秒）。
        public var lookaheadTime = 1.5
        /// 経路の初期方位を、端末の前方からこの角度以内に制限する（ラジアン）。
        public var maxHeadingFromDevice = 60 * Double.pi / 180
        public init() {}
    }

    public var config: Config
    public var collision: CollisionModel
    private var previousShape: PathShape?

    public init(config: Config = Config(), collision: CollisionModel = CollisionModel()) {
        self.config = config
        self.collision = collision
    }

    public mutating func reset() {
        previousShape = nil
    }

    /// - Parameters:
    ///   - userVelocity: ユーザーの速度（地面座標）。
    ///   - goal: 目標地点（地面座標）。
    public mutating func plan(forecasts: [PedestrianForecast], userVelocity: Vec2, goal: Vec2) -> PlannerOutput {
        let speed = min(max(userVelocity.length, config.minPlanningSpeed), config.maxPlanningSpeed)
        // 進行方向: 歩いていれば速度の向き、止まっていれば前方（端末の向き）。
        // 歩行者は端末を進行方向へ向けて持つので、推定速度の向きが前方から大きく外れる場合は誤推定とみなして制限する。
        let heading0: Double
        if userVelocity.length > 0.3, userVelocity.y > 0 {
            heading0 = min(max(userVelocity.heading, -config.maxHeadingFromDevice), config.maxHeadingFromDevice)
        } else {
            heading0 = 0
        }
        let grid = ForecastGrid(forecasts: forecasts, dt: config.dt, duration: config.horizon)
        let steps = grid.steps

        struct Scored {
            var shape: PathShape
            var points: [Vec2]
            var pSafe: Double
            var cost: Double
        }

        var scored: [Scored] = []
        let goalDir = goal.normalized
        let goalDist = goal.length
        for k1 in config.curvatures {
            for sf in config.switchFractions {
                for k2 in (sf >= 1 ? [k1] : config.curvatures) {
                    let shape = PathShape(k1: k1, k2: k2, switchFraction: sf)
                    let pts = Self.rollout(shape: shape, heading: heading0, speed: speed, dt: config.dt, steps: steps)
                    let safety = collision.pathSafety(pts, grid: grid)
                    let end = pts[pts.count - 1]
                    // ゴールへの前進量（ゴール方向の成分）。経路長で正規化する。
                    let progress = goalDist > 0.5 ? (goalDist - (goal - end).length) : end.dot(goalDir)
                    let pathLen = speed * config.horizon
                    let goalCost = 1 - progress / pathLen
                    let curvCost = abs(k1) + abs(k2) * 0.5
                    var smoothCost = 0.0
                    if let prev = previousShape {
                        smoothCost = abs(prev.k1 - k1) + 0.5 * abs(prev.k2 - k2)
                    }
                    let cost = config.wRisk * (1 - safety.pSafe) + config.wGoal * goalCost
                        + config.wSmooth * smoothCost + config.wCurvature * curvCost
                    scored.append(Scored(shape: shape, points: pts, pSafe: safety.pSafe, cost: cost))
                }
            }
        }
        scored.sort { $0.cost < $1.cost }
        var best = scored[0]
        var profile = [Double](repeating: 1, count: best.points.count)
        var slowdown = false

        if best.pSafe < config.acceptSafety {
            // 上位の形について、速度プロファイルを最適化する。
            var bestCost = Double.infinity
            for cand in scored.prefix(config.slowdownCandidates) {
                let (prof, pts, pSafe) = speedProfile(for: cand.shape, heading: heading0, speed: speed, grid: grid)
                let meanRatio = prof.reduce(0, +) / Double(prof.count)
                let cost = config.wRisk * (1 - pSafe) + config.wGoal * (cand.cost - config.wRisk * (1 - cand.pSafe)) + 1.5 * (1 - meanRatio)
                if cost < bestCost, pSafe > best.pSafe {
                    bestCost = cost
                    best = Scored(shape: cand.shape, points: pts, pSafe: pSafe, cost: cost)
                    profile = prof
                    slowdown = prof.contains { $0 < 0.99 }
                }
            }
        }
        previousShape = best.shape

        // 経路長と先読み点。
        var arc = [0.0]
        for i in 1..<best.points.count {
            arc.append(arc[i - 1] + (best.points[i] - best.points[i - 1]).length)
        }
        let la = speed * config.lookaheadTime
        // 減速で経路が短くなり先読み距離に届かないときは、同じ形を現在速度で伸ばした点を使う。
        let lookahead = Self.pointAlong(best.points, arc: arc, distance: la)
            ?? Self.pointAlong(
                Self.rollout(shape: best.shape, heading: heading0, speed: speed, dt: config.dt, steps: steps),
                arc: (0...steps).map { Double($0) * speed * config.dt }, distance: la
            )
            ?? best.points[best.points.count - 1]

        let path = PlannedPath(
            points: best.points, speedRatio: profile, arcLength: arc, pSafe: best.pSafe,
            shape: best.shape, requiresSlowdown: slowdown, lookahead: lookahead
        )
        let cands = scored.map { (points: $0.points, pSafe: $0.pSafe) }
        return PlannerOutput(best: path, candidates: cands, goal: goal, planningSpeed: speed)
    }

    /// 経路の形に沿って、一定速度で進んだときの時刻 i·dt の位置。
    static func rollout(shape: PathShape, heading: Double, speed: Double, dt: Double, steps: Int) -> [Vec2] {
        var pts: [Vec2] = [.zero]
        pts.reserveCapacity(steps + 1)
        var p = Vec2.zero
        var h = heading
        let ds = speed * dt
        let switchStep = Int((Double(steps) * shape.switchFraction).rounded())
        for i in 0..<steps {
            let k = i < switchStep ? shape.k1 : shape.k2
            // 曲率 k の円弧を ds 進む（中点法）。曲率が正なら右へ曲がる。
            let dh = k * ds
            p += Vec2.fromHeading(h + dh / 2, length: ds)
            h += dh
            pts.append(p)
        }
        return pts
    }

    static func pointAlong(_ pts: [Vec2], arc: [Double], distance: Double) -> Vec2? {
        guard let total = arc.last, total > 1e-6 else { return nil }
        if distance >= total { return nil }
        for i in 1..<pts.count where arc[i] >= distance {
            let a = (distance - arc[i - 1]) / max(arc[i] - arc[i - 1], 1e-9)
            return pts[i - 1] * (1 - a) + pts[i] * a
        }
        return nil
    }

    /// ST-graph 上の動的計画法で、経路の形を固定したまま速度プロファイルを求める（パス-速度分解）。
    ///
    /// 状態は (時刻 i, 経路上の距離 s)。各ステップで速度比を `speedLevels` から選び、
    /// 衝突確率（log の和）と減速量のコストを最小化する。速度は現在の速度を超えない。
    func speedProfile(for shape: PathShape, heading: Double, speed: Double, grid: ForecastGrid) -> (ratios: [Double], points: [Vec2], pSafe: Double) {
        let steps = grid.steps
        let total = speed * config.horizon
        let levels = config.speedLevels
        let L = levels.count
        // s の離散化: 速度比の格子に合わせて、最小の刻みで量子化する。
        let ds = speed * config.dt * 0.05
        let maxS = Int((total / ds).rounded()) + 1
        // サンプル済みの経路点（s のインデックス → 位置）。
        let fine = Self.rollout(shape: shape, heading: heading, speed: ds / config.dt, dt: config.dt, steps: maxS)

        struct Node {
            var cost: Double
            var level: Int
            var parentS: Int
            var parentLevel: Int
        }
        // dp[i] : [sIndex * L + level] -> Node
        var layers: [[Int: Node]] = [[0 * L + 0: Node(cost: 0, level: 0, parentS: -1, parentLevel: -1)]]
        layers.reserveCapacity(steps + 1)
        let lambdaSlow = 0.6
        for i in 1...steps {
            var next: [Int: Node] = [:]
            for (key, node) in layers[i - 1] {
                let s0 = key / L
                let l0 = key % L
                let lo = max(0, l0 - config.maxSpeedLevelJump), hi = min(L - 1, l0 + config.maxSpeedLevelJump)
                for l in lo...hi {
                    let r = levels[l]
                    let s1 = min(s0 + Int((r * speed * config.dt / ds).rounded()), maxS)
                    let x = fine[min(s1, fine.count - 1)]
                    let risk = collision.pointRisk(x, timeIndex: i, grid: grid)
                    let c = node.cost - log(max(1 - risk, 1e-6)) + lambdaSlow * (1 - r) * config.dt
                    let k = s1 * L + l
                    if let ex = next[k], ex.cost <= c { continue }
                    next[k] = Node(cost: c, level: l, parentS: s0, parentLevel: l0)
                }
            }
            // ビームで枝刈り。
            if next.count > config.slowdownBeam {
                let kept = next.sorted { $0.value.cost < $1.value.cost }.prefix(config.slowdownBeam)
                next = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
            layers.append(next)
        }
        // 終端: コスト＋到達距離の不足。
        guard let end = layers[steps].min(by: { a, b in
            let sa = Double(a.key / L) * ds, sb = Double(b.key / L) * ds
            return a.value.cost + 0.3 * (total - sa) < b.value.cost + 0.3 * (total - sb)
        }) else {
            let pts = Self.rollout(shape: shape, heading: heading, speed: speed, dt: config.dt, steps: steps)
            return ([Double](repeating: 1, count: steps + 1), pts, collision.pathSafety(pts, grid: grid).pSafe)
        }
        // 経路の復元。
        var sIdx = [Int](repeating: 0, count: steps + 1)
        var lIdx = [Int](repeating: 0, count: steps + 1)
        var key = end.key
        for i in stride(from: steps, through: 1, by: -1) {
            let node = layers[i][key]!
            sIdx[i] = key / L
            lIdx[i] = node.level
            key = node.parentS * L + node.parentLevel
        }
        lIdx[0] = lIdx.count > 1 ? lIdx[1] : 0
        let pts = sIdx.map { fine[min($0, fine.count - 1)] }
        let ratios = lIdx.map { levels[$0] }
        return (ratios, pts, collision.pathSafety(pts, grid: grid).pSafe)
    }
}

/// ゴールの決め方。将来は地図の経路に差し替える。
public protocol GoalProvider: Sendable {
    mutating func goal(context: GoalContext) -> Vec2
}

public struct GoalContext: Sendable {
    /// 端末が向いている方向（地面座標での heading、0 = 前方）。
    public var deviceHeading: Double
    /// 指定した方向について、地面上で見える最も遠い距離を返す（深度マップから）。
    public var farthestVisibleGround: @Sendable (Double) -> Double?
    public init(deviceHeading: Double, farthestVisibleGround: @escaping @Sendable (Double) -> Double?) {
        self.deviceHeading = deviceHeading
        self.farthestVisibleGround = farthestVisibleGround
    }
}

/// v1: 端末が向いている方向の、地面上で見える一番奥をゴールとする。
public struct DeviceForwardGoal: GoalProvider {
    public var maxDistance = 30.0
    public var minDistance = 4.0
    private var smoother = ExponentialSmoother(tau: 0.5)
    private var time = 0.0

    public init() {}

    public mutating func goal(context: GoalContext) -> Vec2 {
        let d = context.farthestVisibleGround(context.deviceHeading) ?? maxDistance
        time += 1
        let s = smoother.update(min(max(d, minDistance), maxDistance), at: time * 0.1)
        return Vec2.fromHeading(context.deviceHeading, length: s)
    }
}
