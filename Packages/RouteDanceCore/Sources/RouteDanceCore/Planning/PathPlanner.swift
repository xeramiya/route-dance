import Foundation

/// 推奨経路。起点は常に地面座標の原点（カメラ直下）。
public struct PlannedPath: Sendable {
    /// 時刻 i·dt での位置（地面座標）。等間隔の時刻ではなく、速度プロファイルに沿った時刻。points[0] は常に原点。
    public var points: [Vec2]
    /// 各点での速度比 v(s) / v_current（1 = 現在の速度で通れる、0 = 停止）。
    public var speedRatio: [Double]
    /// 各点までの経路長（m）。
    public var arcLength: [Double]
    /// 非衝突確率（人と静的障害物。3秒まで厳密、5秒まで時間割引）。
    public var pSafe: Double
    /// 経路の形の識別子（候補の曲率の組）。ヒステリシスに使う。
    public var shape: PathShape
    public var requiresSlowdown: Bool
    /// コンパス矢印が指す地面上の点。
    public var lookahead: Vec2
    public var lookaheadHeading: Double { lookahead.heading }
    /// 経路の起点での曲率（1/m）。時間方向にローパスされている。
    public var startCurvature: Double = 0
    /// 起点での方位（地面座標、右回り正、ラジアン）。時間方向にローパスされている。
    public var startHeading: Double = 0
    /// 厳密な制約の区間（3秒まで）での非衝突確率。
    public var pSafeHard: Double = 1
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
///
/// 選び方の方針:
/// - リスクはヒンジ化: 非衝突確率が 1−ε 以上なら、それ以上安全にしても得をしない（全員から離れる経路を選ばない）。
///   安全な候補どうしは、曲率・曲率変化率・ゴール方向からの横ずれが小さい（なだらかな）ものを選ぶ。
/// - 厳密な制約は `hardHorizon` まで。それ以降は時間割引のソフト項。
/// - 前回の形を新しい予測で再評価し、十分良い候補が現れたときだけ切り替える（ヒステリシス）。
/// - 候補は現在の曲率から連続に始め（クロソイド的な遷移）、表示する曲率は採用した曲率へ時間方向にローパスで追従する。
public struct PathPlanner: Sendable {
    public struct Config: Sendable {
        /// 経路を表示・評価する時間（秒）。経路長は v · horizon（1.3 m/s で約13m）。
        /// 他歩行者の予測は数秒先で不確かになるので、hardHorizon より先のリスクは softDecay で割り引く。
        public var horizon = 10.0
        public var dt = 0.2
        /// 厳密な制約を課す時間（秒）と、それ以降のリスクの重みが 1/e になるまでの時間（秒）。
        public var hardHorizon = 3.0
        public var softDecay = 2.0
        /// 停止中も経路が見えるよう、計画に使う速度の下限（m/s）。10秒で約8m。
        public var minPlanningSpeed = 0.8
        public var maxPlanningSpeed = 2.5
        /// 曲率の候補（1/m）。k_max(v) = lateralAcceleration / v² を超えるものは使わない。
        public var curvatures: [Double] = [-0.5, -0.35, -0.25, -0.18, -0.12, -0.07, -0.03, 0, 0.03, 0.07, 0.12, 0.18, 0.25, 0.35, 0.5]
        /// 前半の曲率で進む時間（秒）。経路の長さ（horizon）に依らず、避ける動作の長さを一定にする。
        /// nil（≥ horizon）は全区間同じ曲率。
        public var switchTimes: [Double?] = [1.75, 3.0, nil]
        /// 歩行者の横加速度の目安（m/s²）。
        public var lateralAcceleration = 1.0
        /// 曲率の変化率の上限 |dk/ds|（1/m²）。クロソイド的な遷移。
        public var maxCurvatureRate = 0.3

        /// 許容する衝突確率 ε（全体）と、1人あたりの ε_i。
        public var epsilon = 0.04
        public var perPersonEpsilon = 0.03
        /// リスクのコスト: J = wHard·max(0, r_hard−ε) + wLinear·r_hard + wSoft·max(0, r_soft−ε) + wLinear·r_soft + wPerson·Σmax(0, p_i−ε_i)
        public var wHard = 40.0
        public var wSoft = 8.0
        public var wLinear = 0.5
        public var wPerson = 15.0
        /// 滑らかさ（Apollo EM型）: w1·mean(k²) + w2·mean((dk/ds)²) + w3·mean(ゴール方向からの横ずれ²)。
        public var wCurvature = 20.0
        public var wCurvatureRate = 4.0
        public var wLateral = 0.3
        /// ゴールへの前進量（経路長で正規化）。
        public var wGoal = 2.0
        /// 遠回りの抑制: ゴール方向の直線から横に maxDetour（m）以上離れる経路は wDetour·超過² で罰する。
        /// 大きく回り込むより、減速・停止して待つ方を選ばせる。
        public var maxDetour = 2.0
        public var wDetour = 4.0
        /// 画面（カメラの水平画角）の外へ出る経路の罰。ユーザーに見えない経路を案内しない。
        /// visibleHalfAngle は NavigationCore が毎フレーム、推定した画角から設定する。
        public var visibleHalfAngle = 28 * Double.pi / 180
        public var visibleMargin = 3 * Double.pi / 180
        public var wOffscreen = 6.0

        /// 現在速度の経路で、厳密区間のリスクがこれを超えるときだけ減速を検討する。
        public var slowdownRisk = 0.08
        /// 減速を検討する上位の経路の数。
        public var slowdownCandidates = 2
        /// 速度プロファイルのDPで残すノード数（計算量の上限）。
        public var slowdownBeam = 50
        /// 速度プロファイルの離散化（速度比の段階）。
        public var speedLevels: [Double] = [1.0, 0.85, 0.7, 0.55, 0.4, 0.25, 0.1, 0.0]
        /// 1ステップあたりに変えられる速度比の上限（加減速の滑らかさ）。
        public var maxSpeedLevelJump = 2
        public var slowdownPenalty = 1.5

        /// ヒステリシス: J(新)+δ < J(前回) のときだけ切り替える。δ = max(hysteresisAbsolute, hysteresisRelative·J(前回))。
        public var hysteresisAbsolute = 0.3
        public var hysteresisRelative = 0.15
        /// 前回の形も最良の候補も安全なときの δ（滑らかさとゴールの差だけで比べる）。
        public var hysteresisSafe = 0.02
        /// 切り替えてから最低限保持する時間（秒）。
        public var minHoldTime = 0.9
        /// 前回の形のリスクが ε のこの倍率を超えたら、保持時間を無視して切り替える。
        public var forceSwitchFactor = 1.5
        /// 避ける向きの反転（右↔左）に課す追加のヒステリシス。
        /// 今の形が右へ避けているのに反対（左）の形へ切り替えるのは、ユーザーにとって負担が大きい。
        /// 反転するのは「今の向きのままではもう危ない」ときだけにしたいので、δ にこの分を上乗せする。
        /// 今の形が安全（r_hard ≤ ε）なほど上乗せを強くし、危ないほど弱める（必要な反転は妨げない）。
        public var reversalHysteresis = 0.6
        /// 表示する曲率・方位・速度が目標へ追従する時定数（秒）。安全が悪化したときは curvatureTauFast。
        public var curvatureTau = 0.6
        /// 表示する曲率の、1秒あたりの変化量の上限（1/m/s）。危険時の速い追従でも急に曲がらないように。
        public var maxCurvatureChangePerSecond = 0.4
        public var curvatureTauFast = 0.2
        /// 起点の方位・速度の平滑化の時定数（秒）。直進／停止中の首振りを抑えるため長めにする。
        public var headingTau = 0.7
        public var speedTau = 0.6
        /// 呼び出し側が時刻を渡さないときの、1回の計画あたりの時間（秒）。
        public var fallbackFrameInterval = 1.0 / 30

        /// 静的障害物との衝突判定に使うユーザーの半径（m）。
        public var obstacleRadius = 0.35
        /// コンパスの先読み時間（秒）。
        public var lookaheadTime = 1.5
        /// 経路の初期方位を、端末の前方からこの角度以内に制限する（ラジアン）。画角の半分も超えない。
        public var maxHeadingFromDevice = 25 * Double.pi / 180
        public init() {}
    }

    public var config: Config
    public var collision: CollisionModel

    // 時間方向の状態。
    private var previousShape: PathShape?
    private var currentCurvature = 0.0
    private var smoothedHeading: Double?
    private var smoothedSpeed: Double?
    private var lastSwitchTime = -Double.infinity
    /// 表示中の経路（時間方向にローパスしたもの）。次のフレームで新しい予測に対して再評価する。
    private var displayedPoints: [Vec2]?
    private var lastTime: Double?
    private var callCount = 0

    public init(config: Config = Config(), collision: CollisionModel = CollisionModel()) {
        self.config = config
        self.collision = collision
    }

    public mutating func reset() {
        previousShape = nil
        currentCurvature = 0
        smoothedHeading = nil
        smoothedSpeed = nil
        lastSwitchTime = -.infinity
        displayedPoints = nil
        lastTime = nil
        callCount = 0
    }

    /// 候補1本ぶんの評価結果。
    private struct Scored {
        var shape: PathShape
        var points: [Vec2]
        /// 非衝突確率: 厳密区間と、時間割引つきの全区間。
        var safeHard: Double
        var safeSoft: Double
        var riskCost: Double
        /// リスク以外のコスト（滑らかさ＋ゴール＋遠回り＋画面外）。
        var pathCost: Double
        /// ゴール方向の直線からの最大の横ずれ（m）。
        var maxDeviation: Double = 0
        var cost: Double { riskCost + pathCost }
        var rHard: Double { 1 - safeHard }
    }

    /// - Parameters:
    ///   - userVelocity: ユーザーの速度（地面座標）。
    ///   - goal: 目標地点（地面座標）。
    ///   - time: 現在の時刻（秒）。ヒステリシスの保持時間とローパスに使う。渡されないときは呼び出し回数 × 1/30 秒で近似する。
    public mutating func plan(
        forecasts: [PedestrianForecast], userVelocity: Vec2, goal: Vec2, obstacles: ObstacleMap = .empty, time: Double? = nil
    ) -> PlannerOutput {
        callCount += 1
        let now = time ?? Double(callCount) * config.fallbackFrameInterval
        let frameDt = lastTime.map { min(max(now - $0, 0.005), 0.3) } ?? config.fallbackFrameInterval
        lastTime = now

        // 速度と初期方位は時間方向に平滑化する（経路の長さ・向きが毎フレーム揺れないように）。
        let rawSpeed = min(max(userVelocity.length, config.minPlanningSpeed), config.maxPlanningSpeed)
        let speed = Self.lowpass(&smoothedSpeed, target: rawSpeed, dt: frameDt, tau: config.speedTau)
        // 進行方向: 歩いていれば速度の向き、止まっていれば前方（端末の向き）。
        // 歩行者は端末を進行方向へ向けて持つので、推定速度の向きが前方から大きく外れる場合は誤推定とみなして制限する。
        let rawHeading: Double
        let headingLimit = min(config.maxHeadingFromDevice, max(config.visibleHalfAngle - config.visibleMargin, 0.05))
        if userVelocity.length > 0.3, userVelocity.y > 0 {
            rawHeading = min(max(userVelocity.heading, -headingLimit), headingLimit)
        } else {
            rawHeading = 0
        }
        let heading0 = Self.lowpass(&smoothedHeading, target: rawHeading, dt: frameDt, tau: config.headingTau)

        let grid = ForecastGrid(
            forecasts: forecasts, dt: config.dt, duration: config.horizon,
            hardHorizon: config.hardHorizon, softDecay: config.softDecay
        )
        let steps = grid.steps
        let k0 = currentCurvature
        let ds = speed * config.dt
        var lattice = ObstacleLattice(map: obstacles, radius: config.obstacleRadius)

        let kMax = min(config.lateralAcceleration / (speed * speed), config.curvatures.map { abs($0) }.max() ?? 0)
        let ks = config.curvatures.filter { abs($0) <= kMax + 1e-9 }
        let kList = ks.isEmpty ? [0.0] : ks
        // 後半の曲率は粗い格子で十分（前半を細かく、後半は間引いて候補数を抑える）。
        let k2List = kList.count > 9 ? kList.enumerated().filter { $0.offset % 2 == 0 || $0.element == 0 }.map(\.element) : kList

        let goalDist = goal.length
        let goalDir = goalDist > 1e-6 ? goal / goalDist : Vec2(0, 1)
        let pathLen = speed * config.horizon

        var scored: [Scored] = []
        scored.reserveCapacity(kList.count * (1 + 2 * k2List.count))
        for k1 in kList {
            for st in config.switchTimes {
                let sf = st.map { min($0 / config.horizon, 1) } ?? 1
                for k2 in (sf >= 1 ? [k1] : k2List) {
                    let shape = PathShape(k1: k1, k2: k2, switchFraction: sf)
                    let (pts, curv) = Self.rolloutWithCurvature(
                        shape: shape, heading: heading0, speed: speed, dt: config.dt, steps: steps,
                        startCurvature: k0, maxRate: config.maxCurvatureRate
                    )
                    let end = pts[pts.count - 1]
                    // ゴールへの前進量。経路長で正規化する。
                    let progress = goalDist > 0.5 ? (goalDist - (goal - end).length) : end.dot(goalDir)
                    var sumK2 = 0.0, sumDk2 = 0.0, sumE2 = 0.0, maxE = 0.0, offscreen = 0.0
                    var prevK = k0
                    let halfAngle = config.visibleHalfAngle - config.visibleMargin
                    for i in 0..<steps {
                        sumK2 += curv[i] * curv[i]
                        let dk = (curv[i] - prevK) / max(ds, 1e-6)
                        sumDk2 += dk * dk
                        prevK = curv[i]
                        let q = pts[i + 1]
                        let e = q.cross(goalDir)
                        sumE2 += e * e
                        maxE = max(maxE, abs(e))
                        // カメラの足元付近（1.5m以内）は画面に映らないのが普通なので数えない。
                        if q.length > 1.5 {
                            let over = abs(q.heading) - halfAngle
                            if over > 0 { offscreen += over }
                        }
                    }
                    let n = Double(steps)
                    let detour = max(0, maxE - config.maxDetour)
                    let pathCost = config.wGoal * (1 - progress / pathLen)
                        + config.wCurvature * sumK2 / n + config.wCurvatureRate * sumDk2 / n + config.wLateral * sumE2 / n
                        + config.wDetour * detour * detour + config.wOffscreen * offscreen / n
                    let ev = evaluateRisk(pts, grid: grid, lattice: &lattice)
                    scored.append(Scored(
                        shape: shape, points: pts, safeHard: ev.safeHard, safeSoft: ev.safeSoft,
                        riskCost: ev.cost, pathCost: pathCost, maxDeviation: maxE
                    ))
                }
            }
        }

        // 最良の候補（コスト最小）と、前回の形（新しい予測で再評価したもの）。
        var bestIndex = 0
        for i in 1..<scored.count where scored[i].cost < scored[bestIndex].cost { bestIndex = i }
        var chosenIndex = bestIndex
        var forced = false
        if let prev = previousShape, let prevIndex = scored.firstIndex(where: { $0.shape == prev }), prevIndex != bestIndex {
            let cur = scored[prevIndex], best = scored[bestIndex]
            // 両方とも安全（ε 以下）なら、差は滑らかさとゴールだけ。大きなヒステリシスを掛けると、
            // 避け終わった後も少し曲がった形を保ち続けて、だんだん向きがずれていくので、小さな δ で比べる。
            let bothSafe = cur.rHard <= config.epsilon && best.rHard <= config.epsilon
            var delta = bothSafe
                ? config.hysteresisSafe
                : max(config.hysteresisAbsolute, config.hysteresisRelative * cur.cost)
            // 避ける向きの反転（右↔左）には追加のヒステリシスを課す。今の形がまだ安全なら、
            // 反対側へ飛ぶのは大きく損がないと許さない（右を案内中に急に左へ振らない）。
            // 今の形が危ないほど上乗せを減らし、本当に必要な反転は妨げない。
            let curDir = cur.shape.k1
            let bestDir = best.shape.k1
            let reverses = curDir * bestDir < -1e-9 && abs(curDir) > 1e-9
            if reverses {
                let safetyScale = max(0, 1 - cur.rHard / max(config.forceSwitchFactor * config.epsilon, 1e-6))
                delta += config.reversalHysteresis * safetyScale
            }
            forced = cur.rHard > config.forceSwitchFactor * config.epsilon && best.cost < cur.cost - 0.05
            let held = now - lastSwitchTime < config.minHoldTime
            let better = best.cost + delta < cur.cost
            chosenIndex = (forced || (better && !held)) ? bestIndex : prevIndex
        }
        if scored[chosenIndex].shape != previousShape { lastSwitchTime = now }
        var best = scored[chosenIndex]
        var profile = [Double](repeating: 1, count: best.points.count)
        var slowdown = false

        if best.rHard > config.slowdownRisk || best.maxDeviation > config.maxDetour + 0.3 {
            // 現在速度では安全にならないか、安全にするには大きく遠回りが要る。
            // 上位の形と、ゴールへ最も真っ直ぐ向かう形について、速度プロファイル（減速・停止）を最適化する。
            var bestCost = best.cost
            var tried = Set<PathShape>()
            var order = scored.indices.sorted { scored[$0].cost < scored[$1].cost }.prefix(config.slowdownCandidates).map { $0 }
            if !order.contains(chosenIndex) { order.insert(chosenIndex, at: 0) }
            // リスクを無視したときに最も良い（真っ直ぐゴールへ向かう）形。減速して待つ候補として必ず試す。
            let direct = scored.indices.sorted { scored[$0].pathCost < scored[$1].pathCost }
            for idx in direct.prefix(2) where !order.contains(idx) { order.append(idx) }
            for idx in order {
                let cand = scored[idx]
                guard tried.insert(cand.shape).inserted else { continue }
                let (prof, pts) = speedProfile(
                    for: cand.shape, heading: heading0, speed: speed, grid: grid, startCurvature: k0, lattice: &lattice
                )
                let meanRatio = prof.reduce(0, +) / Double(prof.count)
                let ev = evaluateRisk(pts, grid: grid, lattice: &lattice)
                let cost = ev.cost + cand.pathCost + config.slowdownPenalty * (1 - meanRatio)
                if cost < bestCost {
                    bestCost = cost
                    best = Scored(
                        shape: cand.shape, points: pts, safeHard: ev.safeHard, safeSoft: ev.safeSoft,
                        riskCost: ev.cost, pathCost: cand.pathCost + config.slowdownPenalty * (1 - meanRatio),
                        maxDeviation: cand.maxDeviation
                    )
                    profile = prof
                    slowdown = prof.contains { $0 < 0.99 }
                }
            }
        }
        previousShape = scored[chosenIndex].shape
        let displayedStartCurvature = k0

        // 表示する経路を、採用した経路へ時間方向にローパスで追従させる（切り替わっても経路が飛ばない）。
        // 前回表示した経路が今の予測で危なくなっているときは、速く追従する。起点は常に原点。
        var shown = best.points
        var shownSafeHard = best.safeHard, shownSafeSoft = best.safeSoft
        var fast = forced
        if let prev = displayedPoints, prev.count == best.points.count {
            let prevEval = evaluateRisk(prev, grid: grid, lattice: &lattice)
            if 1 - prevEval.safeHard > config.forceSwitchFactor * config.epsilon, best.rHard < 1 - prevEval.safeHard { fast = true }
            let tau = fast ? config.curvatureTauFast : config.curvatureTau
            let a = 1 - exp(-frameDt / tau)
            // 減速を伴う経路は、時刻あたりの位置が変わるので、そのまま採用する。
            if !slowdown {
                // 補間した経路が採用した経路よりずっと危ないときは（避ける向きが逆転したときなど）、追従を段階的に速める。
                let limit = max(config.forceSwitchFactor * config.epsilon, best.rHard + 0.05)
                for gain in [a, max(a, 2 * a), max(a, 0.5), 1.0] {
                    var cand = zip(prev, best.points).map { $0 + gain * ($1 - $0) }
                    cand[0] = .zero
                    let ev = gain >= 1 ? (safeHard: best.safeHard, safeSoft: best.safeSoft, cost: 0) : evaluateRisk(cand, grid: grid, lattice: &lattice)
                    if 1 - ev.safeHard <= limit || gain >= 1 {
                        shown = cand
                        shownSafeHard = ev.safeHard
                        shownSafeSoft = ev.safeSoft
                        break
                    }
                }
            }
        }
        displayedPoints = shown
        best.points = shown
        best.safeHard = shownSafeHard
        best.safeSoft = shownSafeSoft
        // 次の候補の始点の曲率も、表示している経路に合わせてローパスで追従させる。
        // 危険時（fast）も、人が急に向きを変えられる速さを超えないよう、1秒あたりの曲率の変化量に上限を置く。
        let tauK = fast ? config.curvatureTauFast : config.curvatureTau
        let step = (1 - exp(-frameDt / tauK)) * (best.shape.k1 - currentCurvature)
        let maxStep = config.maxCurvatureChangePerSecond * frameDt
        currentCurvature += min(max(step, -maxStep), maxStep)

        // 経路長と先読み点。
        var arc = [0.0]
        for i in 1..<best.points.count {
            arc.append(arc[i - 1] + (best.points[i] - best.points[i - 1]).length)
        }
        let la = speed * config.lookaheadTime
        // 減速で経路が短くなり先読み距離に届かないときは、同じ形を現在速度で伸ばした点を使う。
        let lookahead = Self.pointAlong(best.points, arc: arc, distance: la)
            ?? Self.pointAlong(
                Self.rolloutWithCurvature(
                    shape: best.shape, heading: heading0, speed: speed, dt: config.dt, steps: steps,
                    startCurvature: k0, maxRate: config.maxCurvatureRate
                ).points,
                arc: (0...steps).map { Double($0) * speed * config.dt }, distance: la
            )
            ?? best.points[best.points.count - 1]

        let path = PlannedPath(
            points: best.points, speedRatio: profile, arcLength: arc, pSafe: best.safeSoft,
            shape: best.shape, requiresSlowdown: slowdown, lookahead: lookahead,
            startCurvature: displayedStartCurvature, startHeading: heading0, pSafeHard: best.safeHard
        )
        let cands = scored.map { (points: $0.points, pSafe: $0.safeSoft) }
        return PlannerOutput(best: path, candidates: cands, goal: goal, planningSpeed: speed)
    }

    /// 一次のローパス。state が nil なら target で初期化する。
    private static func lowpass(_ state: inout Double?, target: Double, dt: Double, tau: Double) -> Double {
        guard let s = state else {
            state = target
            return target
        }
        let v = s + (1 - exp(-dt / max(tau, 1e-6))) * (target - s)
        state = v
        return v
    }

    /// 経路のリスクとコスト。人（異方ガウス）と静的障害物を独立に合成する。
    private func evaluateRisk(_ pts: [Vec2], grid: ForecastGrid, lattice: inout ObstacleLattice) -> (safeHard: Double, safeSoft: Double, cost: Double) {
        let r = collision.pathRisk(pts, grid: grid)
        // 静的障害物は動かないので、予測の不確かさのような時間割引はしない（全区間で厳密に扱う）。
        // 割り引くと、遠い壁の手前で止まる経路や、壁に向かって進む経路が安全に見えてしまう。
        var obsHard = 0.0
        if !lattice.isEmpty {
            for x in pts {
                let p = lattice.probability(x)
                if p > obsHard { obsHard = p }
            }
        }
        let obsSoft = obsHard
        let safeHard = r.pSafeHard * (1 - obsHard)
        let safeSoft = r.pSafeSoft * (1 - obsSoft)
        let rH = 1 - safeHard, rS = 1 - safeSoft
        let eps = config.epsilon
        var cost = config.wHard * max(0, rH - eps) + config.wLinear * rH
            + config.wSoft * max(0, rS - eps) + config.wLinear * rS
        for p in r.perPersonHard { cost += config.wPerson * max(0, p - config.perPersonEpsilon) }
        cost += config.wPerson * max(0, obsHard - config.perPersonEpsilon)
        return (safeHard, safeSoft, cost)
    }

    /// 経路の形に沿って、一定速度で進んだときの時刻 i·dt の位置。曲率は目標へ即座に切り替わる（後方互換）。
    static func rollout(shape: PathShape, heading: Double, speed: Double, dt: Double, steps: Int) -> [Vec2] {
        rolloutWithCurvature(shape: shape, heading: heading, speed: speed, dt: dt, steps: steps, startCurvature: nil, maxRate: .infinity).points
    }

    /// 曲率を startCurvature から目標の曲率へ、|dk/ds| ≤ maxRate で変えながら進む（クロソイド的な遷移）。
    /// startCurvature が nil なら最初から目標の曲率。戻り値の curvatures[i] は、ステップ i で使った曲率。
    static func rolloutWithCurvature(
        shape: PathShape, heading: Double, speed: Double, dt: Double, steps: Int, startCurvature: Double?, maxRate: Double
    ) -> (points: [Vec2], curvatures: [Double]) {
        var pts: [Vec2] = [.zero]
        var curv: [Double] = []
        pts.reserveCapacity(steps + 1)
        curv.reserveCapacity(steps)
        var p = Vec2.zero
        var h = heading
        let ds = speed * dt
        var kc = startCurvature ?? shape.k1
        let switchStep = Int((Double(steps) * shape.switchFraction).rounded())
        let maxDk = maxRate * ds
        for i in 0..<steps {
            let target = i < switchStep ? shape.k1 : shape.k2
            if startCurvature != nil {
                kc += min(max(target - kc, -maxDk), maxDk)
            } else {
                kc = target
            }
            // 曲率 k の円弧を ds 進む（中点法）。曲率が正なら右へ曲がる。
            let dh = kc * ds
            p += Vec2.fromHeading(h + dh / 2, length: ds)
            h += dh
            pts.append(p)
            curv.append(kc)
        }
        return (pts, curv)
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
    /// 衝突確率（log の和、厳密区間より先は時間割引）と減速量のコストを最小化する。速度は現在の速度を超えない。
    private func speedProfile(
        for shape: PathShape, heading: Double, speed: Double, grid: ForecastGrid, startCurvature: Double, lattice: inout ObstacleLattice
    ) -> (ratios: [Double], points: [Vec2]) {
        let steps = grid.steps
        let total = speed * config.horizon
        let levels = config.speedLevels
        let L = levels.count
        // s の離散化: 速度比の格子に合わせて、最小の刻みで量子化する。
        let ds = speed * config.dt * 0.05
        let maxS = Int((total / ds).rounded()) + 1
        // サンプル済みの経路点（s のインデックス → 位置）。形は現在速度の経路と同じ（曲率の遷移は距離で決まる）。
        let fine = Self.rolloutWithCurvature(
            shape: shape, heading: heading, speed: ds / config.dt, dt: config.dt, steps: maxS,
            startCurvature: startCurvature, maxRate: config.maxCurvatureRate
        ).points
        // 形の switchFraction は経路長に対する割合なので、fine の長さ（maxS）で決まるのは近似になる（total とほぼ同じ）。

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
            // 同じ時刻・同じ経路上の位置の衝突コストは、多くのノードで共有されるのでキャッシュする。
            var riskCache: [Int: Double] = [:]
            for (key, node) in layers[i - 1] {
                let s0 = key / L
                let l0 = key % L
                let lo = max(0, l0 - config.maxSpeedLevelJump), hi = min(L - 1, l0 + config.maxSpeedLevelJump)
                for l in lo...hi {
                    let r = levels[l]
                    let s1 = min(s0 + Int((r * speed * config.dt / ds).rounded()), maxS)
                    let riskCost: Double
                    if let cached = riskCache[s1] {
                        riskCost = cached
                    } else {
                        let x = fine[min(s1, fine.count - 1)]
                        let pPed = collision.pointRisk(x, timeIndex: i, grid: grid, applyTimeWeight: true)
                        let pObs = lattice.isEmpty ? 0 : lattice.probability(x)
                        let risk = 1 - (1 - pPed) * (1 - pObs)
                        riskCost = -log(max(1 - risk, 1e-6))
                        riskCache[s1] = riskCost
                    }
                    let c = node.cost + riskCost + lambdaSlow * (1 - r) * config.dt
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
            let pts = Self.rolloutWithCurvature(
                shape: shape, heading: heading, speed: speed, dt: config.dt, steps: steps,
                startCurvature: startCurvature, maxRate: config.maxCurvatureRate
            ).points
            return ([Double](repeating: 1, count: steps + 1), pts)
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
        return (ratios, pts)
    }
}

/// 静的障害物の衝突確率を、細かい格子（5cm）にスナップしてキャッシュする。
/// `ObstacleMap.collisionProbability` は点数に比例して重いので、候補どうしで共有される点を使い回す。
struct ObstacleLattice {
    let map: ObstacleMap
    let radius: Double
    let isEmpty: Bool
    private var cache: [Int: Double] = [:]
    private let cell = 0.05

    init(map: ObstacleMap, radius: Double) {
        self.map = map
        self.radius = radius
        isEmpty = map.points.isEmpty
    }

    mutating func probability(_ x: Vec2) -> Double {
        if isEmpty { return 0 }
        let ix = Int((x.x / cell).rounded()), iy = Int((x.y / cell).rounded())
        let key = (ix + 100_000) &* 200_003 &+ (iy + 100_000)
        if let v = cache[key] { return v }
        let v = map.collisionProbability(at: Vec2(Double(ix) * cell, Double(iy) * cell), radius: radius)
        cache[key] = v
        return v
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

/// v1: 端末が向いている方向の、画面の一番奥をゴールとする。
///
/// 手前の人や障害物で地面が隠れていても、ゴールは手前に縮めない（縮めると経路がその人の手前で止まって揺れる）。
/// 人や障害物はゴールではなく、計画のリスクで避ける。見えている地面の最遠点が遠ければそこまで伸ばす。
public struct DeviceForwardGoal: GoalProvider {
    public var maxDistance = 30.0
    public var minDistance = 20.0
    private var smoother = ExponentialSmoother(tau: 1.0)
    /// ゴールの方位も平滑化する。端末の手ブレがそのままゴールの横位置になり、経路が左右に揺れるのを防ぐ。
    private var headingSmoother = AngleSmoother(tau: 1.0)
    private var time = 0.0

    public init() {}

    public mutating func goal(context: GoalContext) -> Vec2 {
        let d = context.farthestVisibleGround(context.deviceHeading) ?? maxDistance
        time += 1
        let s = smoother.update(min(max(d, minDistance), maxDistance), at: time * 0.1)
        let heading = headingSmoother.update(context.deviceHeading, at: time * 0.1)
        return Vec2.fromHeading(heading, length: s)
    }
}
