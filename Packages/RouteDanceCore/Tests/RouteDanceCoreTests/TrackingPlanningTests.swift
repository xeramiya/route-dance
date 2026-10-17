import Foundation
import Testing
@testable import RouteDanceCore

private func person(_ p: Vec2, score: Double = 0.9, box: Double = 0) -> LocalizedPerson {
    LocalizedPerson(
        detection: PersonDetection(minX: box, minY: 100, maxX: box + 60, maxY: 300, confidence: score),
        position: p, rangeVariance: 0.04, lateralVariance: 0.01, sources: [.footRay]
    )
}

private func track(id: Int, position: Vec2, velocity: Vec2) -> Track {
    var f = GroundKalman(position: position, variance: 0.01)
    f.x[2] = velocity.x
    f.x[3] = velocity.y
    return Track(id: id, filter: f, state: .confirmed, lastDetection: nil, hits: 10, age: 1, timeSinceUpdate: 0, history: [])
}

@Suite struct TrackerTests {
    @Test func twoPeopleKeepTheirIDsAndVelocity() {
        var tracker = PedestrianTracker()
        let dt = 0.1
        // A は右から左へ、B は奥から手前へ。
        for i in 0...30 {
            let t = Double(i) * dt
            let a = Vec2(3 - 1.2 * t, 6)
            let b = Vec2(-1, 10 - 1.0 * t)
            tracker.update(persons: [person(a, box: 400), person(b, box: 100)], egoDelta: .identity, at: t)
        }
        let tr = tracker.activeTracks.sorted { $0.id < $1.id }
        #expect(tr.count == 2)
        #expect(tr.allSatisfy { $0.state == .confirmed })
        let a = tr.first { $0.position.y > 5 && $0.position.y < 7 }!
        let b = tr.first { $0.id != a.id }!
        #expect((a.velocity - Vec2(-1.2, 0)).length < 0.15)
        #expect((b.velocity - Vec2(0, -1.0)).length < 0.15)
    }

    @Test func survivesShortOcclusionAndUsesLowScores() {
        var tracker = PedestrianTracker()
        let dt = 0.1
        var id: Int?
        for i in 0...25 {
            let t = Double(i) * dt
            let p = Vec2(0, 8 - 0.8 * t)
            let persons: [LocalizedPerson]
            switch i {
            case 10...13: persons = []  // 隠れる
            case 14...16: persons = [person(p, score: 0.3)]  // 低スコアでしか見えない
            default: persons = [person(p)]
            }
            tracker.update(persons: persons, egoDelta: .identity, at: t)
            if i == 9 { id = tracker.activeTracks.first?.id }
        }
        #expect(tracker.activeTracks.count == 1)
        #expect(tracker.activeTracks.first?.id == id)
    }

    @Test func egoMotionIsCompensated() {
        // 静止した人に向かってユーザーが 1.2 m/s で歩く → 人の速度は 0 に近いはず。
        var tracker = PedestrianTracker()
        let dt = 0.1
        var pos = Vec2(0.5, 8)
        for i in 0...30 {
            let delta = Pose2D(rotation: 0, translation: Vec2(0, -1.2 * dt))
            if i > 0 { pos = delta.apply(pos) }
            tracker.update(persons: [person(pos)], egoDelta: i == 0 ? .identity : delta, at: Double(i) * dt)
        }
        let tr = tracker.activeTracks.first!
        #expect(tr.velocity.length < 0.1)
        #expect((tr.position - pos).length < 0.1)
    }
}

@Suite struct PredictionTests {
    @Test func cpaHorizon() {
        let h = CPAHorizon()
        // 正面から近づく（相対速度 2.6 m/s、距離 10 m）→ t_cpa ≈ 3.85 s
        let head = h.evaluate(relativePosition: Vec2(0, 10), relativeVelocity: Vec2(0, -2.6), userSpeed: 1.3)
        #expect(abs(head.tCPA - 10 / 2.6) < 1e-9)
        #expect(abs(head.horizon - (10 / 2.6 + 1)) < 1e-9)
        // 同じ向きに少し遅く歩く人（相対 −0.3 m/s、距離 4 m）→ 長いホライズン（上限）
        let same = h.evaluate(relativePosition: Vec2(0, 4), relativeVelocity: Vec2(0, -0.3), userSpeed: 1.3)
        #expect(same.horizon == h.maxHorizon)
        // 離れていく人 → t_cpa = 0 なので N = clamp(τ) = 1 s
        let away = h.evaluate(relativePosition: Vec2(0, 4), relativeVelocity: Vec2(0, 1.0), userSpeed: 1.3)
        #expect(away.tCPA == 0)
        #expect(away.horizon == max(h.tau, h.minHorizon))
        // 相対速度がほぼ0 → 距離 / 速度
        let still = h.evaluate(relativePosition: Vec2(0, 3), relativeVelocity: Vec2(0, 0.05), userSpeed: 1.5)
        #expect(abs(still.horizon - 2) < 1e-9)
    }

    @Test func cvmSamplesAreCenteredOnConstantVelocity() {
        let p = ConstantVelocityPredictor()
        let f = p.predict(tracks: [track(id: 1, position: Vec2(2, 6), velocity: Vec2(-1, 0))], userVelocity: Vec2(0, 1.3), duration: 5)[0]
        #expect(abs(f.weights.reduce(0, +) - 1) < 1e-9)
        var mean = Vec2.zero
        let at3 = f.positions(at: 3)
        for (k, x) in at3.enumerated() { mean += x * f.weights[k] }
        #expect((mean - Vec2(-1, 6)).length < 0.2)
        #expect(f.sigma(at: 3) > f.sigma(at: 0))
        #expect(f.horizon >= 1 && f.horizon <= 6)
    }
}

@Suite struct PlannerTests {
    func plan(_ tracks: [Track], speed: Double = 1.3, goal: Vec2 = Vec2(0, 25)) -> PlannerOutput {
        var planner = PathPlanner()
        let f = ConstantVelocityPredictor().predict(tracks: tracks, userVelocity: Vec2(0, speed), duration: 7.5)
        return planner.plan(forecasts: f, userVelocity: Vec2(0, speed), goal: goal)
    }

    @Test func goesStraightWhenClear() {
        let out = plan([])
        #expect(out.best.pSafe > 0.999)
        #expect(!out.best.requiresSlowdown)
        #expect(abs(out.best.shape.k1) < 0.06 && abs(out.best.shape.k2) < 0.06)
        // 経路長 ≈ v·7s
        #expect(abs(out.best.arcLength.last! - 1.3 * 7) < 0.05)
        #expect(abs(out.best.lookaheadHeading) < 0.05)
    }

    @Test func swervesAroundOncomingPerson() {
        // 正面から歩いてくる人。少しだけ左にずれている。
        let out = plan([track(id: 1, position: Vec2(-0.2, 7), velocity: Vec2(0, -1.2))])
        #expect(out.best.pSafe > 0.9)
        #expect(!out.best.requiresSlowdown)
        // 右へ避ける（左の人から離れる）。
        let maxX = out.best.points.map(\.x).max()!
        #expect(maxX > 0.4)
        #expect(out.best.lookaheadHeading > 0)
    }

    @Test func goalPullsTowardDeviceDirection() {
        let out = plan([], goal: Vec2.fromHeading(0.6, length: 20))
        #expect(out.best.lookaheadHeading > 0.1)
    }

    @Test func sidestepsCrossingGroupWithoutSlowing() {
        // 左から横切る短い人の列。現在の速度のまま前を抜けて避けられるなら、減速しない（減速は避けられないときだけ）。
        var tracks: [Track] = []
        for (i, x) in stride(from: -5.5, through: -3.1, by: 0.8).enumerated() {
            tracks.append(track(id: i, position: Vec2(x, 3.0), velocity: Vec2(1.0, 0)))
        }
        let out = plan(tracks)
        #expect(out.best.pSafe > 0.9)
        #expect(!out.best.requiresSlowdown)
    }

    @Test func waitsForUnavoidableCrossingWall() {
        // 左右に長く続く横切りの列は、曲がっても避けきれない。衝突するくらいなら減速して待つ。
        var tracks: [Track] = []
        for (i, x) in stride(from: -6.0, through: 6.0, by: 0.8).enumerated() {
            tracks.append(track(id: i, position: Vec2(x - 3, 3.0), velocity: Vec2(1.0, 0)))
        }
        let out = plan(tracks)
        #expect(out.best.requiresSlowdown)
        #expect(out.best.pSafeHard > 0.8)
    }

    @Test func slowsDownWhenTurningIsNotAllowed() {
        // 直進しか許さない設定で、横切る人の列 → 速度プロファイルで待つ。
        var tracks: [Track] = []
        for (i, x) in stride(from: -6.0, through: 6.0, by: 0.8).enumerated() {
            tracks.append(track(id: i, position: Vec2(x - 3, 3.0), velocity: Vec2(1.0, 0)))
        }
        var config = PathPlanner.Config()
        config.curvatures = [0]
        config.switchFractions = [1]
        var planner = PathPlanner(config: config)
        let f = ConstantVelocityPredictor().predict(tracks: tracks, userVelocity: Vec2(0, 1.3), duration: 7.5)
        let out = planner.plan(forecasts: f, userVelocity: Vec2(0, 1.3), goal: Vec2(0, 25))
        #expect(out.best.requiresSlowdown)
        #expect(out.best.speedRatio.min()! < 0.6)
        #expect(out.best.arcLength.last! < 1.3 * 7 - 0.5)
        // 減速した経路はしない経路より安全。
        let straight = PathPlanner.rollout(shape: out.best.shape, heading: 0, speed: 1.3, dt: 0.2, steps: 35)
        let grid = ForecastGrid(forecasts: f, dt: 0.2, duration: 7)
        #expect(out.best.pSafe > CollisionModel().pathSafety(straight, grid: grid).pSafe + 0.2)
    }

    @Test func planningIsFastEnoughForRealTime() {
        // 10人の他歩行者で1回の計画が十分速いこと。debugビルドは最適化がなく数百ms かかるので、release でのみ厳しく見る。
        // 計測: M4 Pro、release で約2ms。
        var tracks: [Track] = []
        for i in 0..<10 {
            tracks.append(track(id: i, position: Vec2(Double(i % 5) - 2, 3 + Double(i)), velocity: Vec2(0.3 * Double(i % 3) - 0.3, -1)))
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = plan(tracks)
        }
        #if DEBUG
        #expect(elapsed < .seconds(3))
        #else
        #expect(elapsed < .milliseconds(30))
        #endif
    }

    @Test func riskFieldMarksPersonAhead() {
        let tr = [track(id: 1, position: Vec2(0, 4), velocity: .zero)]
        let f = ConstantVelocityPredictor().predict(tracks: tr, userVelocity: Vec2(0, 1.3), duration: 7.5)
        let grid = ForecastGrid(forecasts: f, dt: 0.2, duration: 7)
        let field = RiskField.compute(grid: grid, model: CollisionModel(), speed: 1.3)
        func safety(at p: Vec2) -> Double {
            let c = Int((p.x - field.origin.x) / field.cellSize), r = Int((p.y - field.origin.y) / field.cellSize)
            return field.safety[r * field.columns + c]
        }
        #expect(safety(at: Vec2(0, 4)) < 0.5)
        #expect(safety(at: Vec2(4, 4)) > 0.95)
    }
}

// MARK: - 経路の選び方（流れに乗る・なだらか・安定）

/// 複数フレームを続けて計画するためのヘルパー。
private struct Drive {
    var planner = PathPlanner()
    let predictor = ConstantVelocityPredictor()
    var frame = 0
    let fps = 30.0

    /// ユーザーは (0, speed) で前進し続けるものとして、世界座標の人の動きを毎フレームユーザー座標に直して渡す。
    mutating func step(tracks: [Track], speed: Double = 1.3, goal: Vec2 = Vec2(0, 25), obstacles: ObstacleMap = .empty) -> PlannerOutput {
        let v = Vec2(0, speed)
        let f = predictor.predict(tracks: tracks, userVelocity: v, duration: 7.5)
        defer { frame += 1 }
        return planner.plan(forecasts: f, userVelocity: v, goal: goal, obstacles: obstacles, time: Double(frame) / fps)
    }
}

/// 経路上の各点（時刻 i·dt）と、人が等速で動いたときの位置との最小距離とそのときの横間隔。
private func closestPass(_ path: PlannedPath, person p0: Vec2, velocity: Vec2, dt: Double = 0.2) -> (distance: Double, lateral: Double) {
    var best = (distance: Double.infinity, lateral: Double.infinity)
    for (i, x) in path.points.enumerated() {
        let q = p0 + velocity * (Double(i) * dt)
        let d = (x - q).length
        if d < best.distance { best = (d, abs(x.x - q.x)) }
    }
    return best
}

@Suite struct PathChoiceTests {
    @Test func everyPathStartsAtOrigin() {
        var d = Drive()
        let tr = [track(id: 1, position: Vec2(-0.2, 7), velocity: Vec2(0, -1.2)), track(id: 2, position: Vec2(2, 4), velocity: Vec2(0, 0.6))]
        for _ in 0..<20 {
            let out = d.step(tracks: tr)
            #expect(out.best.points[0] == .zero)
            #expect(out.candidates.allSatisfy { $0.points[0] == .zero })
        }
    }

    @Test func passesSlowWalkerInSameDirectionClosely() {
        // 同じ向きにゆっくり歩く人の真後ろ。遠くへ大きく避けず、すぐ横（1.0〜1.6m）を抜く。
        var d = Drive()
        var out = d.step(tracks: [track(id: 1, position: Vec2(0, 3), velocity: Vec2(0, 0.7))])
        for _ in 0..<30 { out = d.step(tracks: [track(id: 1, position: Vec2(0, 3), velocity: Vec2(0, 0.7))]) }
        let pass = closestPass(out.best, person: Vec2(0, 3), velocity: Vec2(0, 0.7))
        #expect(out.best.pSafeHard > 0.9)
        #expect(!out.best.requiresSlowdown)
        #expect(pass.distance > 0.9)
        #expect(pass.lateral > 0.9 && pass.lateral < 1.7)
    }

    @Test func staysInFlowBetweenSameDirectionWalkers() {
        // 左右に同じ速さで歩く人。間を真っ直ぐ進んでよい（全員から最も離れる経路を探して曲がらない）。
        var d = Drive()
        let tr = [
            track(id: 1, position: Vec2(-1.4, 3), velocity: Vec2(0, 1.2)),
            track(id: 2, position: Vec2(1.4, 3.5), velocity: Vec2(0, 1.3)),
            track(id: 3, position: Vec2(-1.6, 6), velocity: Vec2(0, 1.2)),
        ]
        var out = d.step(tracks: tr)
        for _ in 0..<30 { out = d.step(tracks: tr) }
        #expect(out.best.pSafeHard > 0.95)
        let maxX = out.best.points.map { abs($0.x) }.max()!
        #expect(maxX < 0.6)
    }

    @Test func doesNotTurnMoreThanNeededForOncomingPerson() {
        // 正面の人は安全に避けられればよい。大きく曲がらず、避けたあとは緩やかに戻る。
        var d = Drive()
        let tr = [track(id: 1, position: Vec2(-0.2, 8), velocity: Vec2(0, -1.2))]
        var out = d.step(tracks: tr)
        for _ in 0..<30 { out = d.step(tracks: tr) }
        #expect(out.best.pSafeHard > 0.9)
        // 曲率は横加速度 1 m/s² 相当（k ≤ 0.6）の半分以下で、横ずれも 3m 以内。
        #expect(abs(out.best.shape.k1) <= 0.3 && abs(out.best.shape.k2) <= 0.3)
        #expect(out.best.points.map { abs($0.x) }.max()! < 3.0)
    }

    @Test func keepsPreviousShapeWhenItStaysSafe() {
        // 前回の計画が安全なら、予測がわずかに揺れただけで別の形に切り替えない。
        var d = Drive()
        var shapes = Set<PathShape>()
        for i in 0..<90 {
            // 人の位置を数cm揺らす（検出ノイズ）。
            let jitter = 0.04 * sin(Double(i) * 1.3)
            let tr = [track(id: 1, position: Vec2(-0.3 + jitter, 8 - 1.2 * Double(i) / 30), velocity: Vec2(0.03 * jitter, -1.2))]
            let out = d.step(tracks: tr)
            if i >= 30 { shapes.insert(out.best.shape) }
        }
        #expect(shapes.count <= 2)
    }

    @Test func curvatureAndArrowChangeSmoothlyOverManyFrames() {
        // 正面から人が近づき、すれ違うまで、計画どおりに進むユーザーを閉ループでシミュレートする（30fps、6秒）。
        // 毎フレームの矢印角度・曲率の変化は小さい。
        var planner = PathPlanner()
        let predictor = ConstantVelocityPredictor()
        let speed = 1.3
        var userPos = Vec2.zero, userHeading = 0.0
        let personStart = Vec2(-0.3, 9), personVelocity = Vec2(0, -1.2)
        var prevHeading: Double?, prevCurvature: Double?
        var maxDHeading = 0.0, maxDK = 0.0
        var maxLateral = 0.0
        for i in 0..<180 {
            let t = Double(i) / 30
            let rel = (personStart + personVelocity * t - userPos).rotated(by: -userHeading)
            let tr = [track(id: 1, position: rel, velocity: personVelocity.rotated(by: -userHeading))]
            let f = predictor.predict(tracks: tr, userVelocity: Vec2(0, speed), duration: 7.5)
            let out = planner.plan(forecasts: f, userVelocity: Vec2(0, speed), goal: Vec2(0, 25), time: t)
            let h = out.best.lookaheadHeading
            let k = out.best.startCurvature
            if let ph = prevHeading { maxDHeading = max(maxDHeading, abs(h - ph)) }
            if let pk = prevCurvature { maxDK = max(maxDK, abs(k - pk)) }
            prevHeading = h
            prevCurvature = k
            // 計画の最初の1秒の旋回率で進む。
            let turnRate = 2 * out.best.points[1].heading / 0.2
            userHeading += turnRate / 30
            userPos += Vec2.fromHeading(userHeading, length: speed / 30)
            maxLateral = max(maxLateral, abs(userPos.x))
            #expect(out.best.points[0] == .zero)
        }
        // 毎フレーム（1/30 秒）の矢印角度の変化は 1°未満、曲率の変化は 0.015 未満（τ=0.6秒の追従）。
        #expect(maxDHeading < 1 * .pi / 180, "maxDH=\(maxDHeading * 180 / .pi)")
        #expect(maxDK < 0.015, "maxDK=\(maxDK)")
        // 衝突せず、大きく避けすぎない。
        #expect(maxLateral > 0.2 && maxLateral < 2.5)
    }

    @Test func switchingShapesDoesNotJumpTheDisplayedPath() {
        // 人の位置が左右に入れ替わる（避ける向きが逆転する）ときも、表示する経路が1フレームで大きく飛ばない。
        var d = Drive()
        var prev: PlannedPath?
        var maxJump = 0.0
        for i in 0..<120 {
            let x = i < 60 ? -0.3 : 0.3
            let out = d.step(tracks: [track(id: 1, position: Vec2(x, 7), velocity: Vec2(0, -1.0))])
            if let p = prev, p.points.count == out.best.points.count, i != 60 {
                maxJump = max(maxJump, (p.points[10] - out.best.points[10]).length)
            }
            prev = out.best
        }
        #expect(maxJump < 0.25)
    }

    @Test func avoidsStaticObstacleAhead() {
        // 正面 4m に壁の一部（幅 1m）。避ける。
        var pts: [Vec2] = []
        for x in stride(from: -0.5, through: 0.5, by: 0.05) { pts.append(Vec2(x, 4)) }
        let obstacles = ObstacleMap(points: pts)
        var d = Drive()
        var out = d.step(tracks: [], obstacles: obstacles)
        for _ in 0..<20 { out = d.step(tracks: [], obstacles: obstacles) }
        let minDist = out.best.points.map { x in pts.map { ($0 - x).length }.min()! }.min()!
        #expect(minDist > 0.45)
        #expect(out.best.pSafeHard > 0.9)
    }

    @Test func anisotropicUncertaintyIsWiderAlongTravel() {
        let f = ConstantVelocityPredictor().predict(tracks: [track(id: 1, position: Vec2(0, 6), velocity: Vec2(0, -1.2))], userVelocity: Vec2(0, 1.3), duration: 5)[0]
        #expect(f.sigmaAlong(at: 3) > f.sigmaCross(at: 3) * 1.5)
        #expect(abs(f.sigmaAlong(at: 3) - (0.1 + 0.15 * 3)) < 1e-9)
        #expect(abs(f.sigmaCross(at: 3) - (0.1 + 0.06 * 3)) < 1e-9)
        // 進行方向のずれは、横のずれより衝突確率が高い（同じ距離でも）。
        let grid = ForecastGrid(forecasts: [f], dt: 0.2, duration: 5)
        let model = CollisionModel()
        let center = f.positions(at: 2)[4]  // 中央サンプル付近
        let along = model.pointRisk(center + Vec2(0, 0.7), timeIndex: 10, grid: grid)
        let cross = model.pointRisk(center + Vec2(0.7, 0), timeIndex: 10, grid: grid)
        #expect(along > cross)
    }

    @Test func stationaryPersonIsIsotropic() {
        let f = ConstantVelocityPredictor().predict(tracks: [track(id: 1, position: Vec2(1, 5), velocity: .zero)], userVelocity: Vec2(0, 1.3), duration: 5)[0]
        #expect(f.sigmaAlong(at: 2) == f.sigmaCross(at: 2))
        #expect(f.sigma(at: 2) == f.sigmaAlong(at: 2))
    }

    @Test func riskBeyondHardHorizonIsDiscounted() {
        // 同じ距離でも、4.5秒先の接近は 1.5 秒先の接近より軽く扱われる。
        let early = ForecastGrid(forecasts: [], dt: 0.2, duration: 5)
        #expect(early.timeWeight[7] == 1)
        #expect(early.timeWeight[25] < 0.5)
        #expect(early.hardSteps == 15)
    }
}
