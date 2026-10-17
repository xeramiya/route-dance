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
        let f = ConstantVelocityPredictor().predict(tracks: tracks, userVelocity: Vec2(0, speed), duration: 5.5)
        return planner.plan(forecasts: f, userVelocity: Vec2(0, speed), goal: goal)
    }

    @Test func goesStraightWhenClear() {
        let out = plan([])
        #expect(out.best.pSafe > 0.999)
        #expect(!out.best.requiresSlowdown)
        #expect(abs(out.best.shape.k1) < 0.06 && abs(out.best.shape.k2) < 0.06)
        // 経路長 ≈ v·5s
        #expect(abs(out.best.arcLength.last! - 1.3 * 5) < 0.05)
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

    @Test func sidestepsCrossingStreamWithoutSlowing() {
        // 横切る人の列。現在の速度のまま避けられるなら、減速しない（仕様: 減速は避けられないときだけ）。
        var tracks: [Track] = []
        for (i, x) in stride(from: -6.0, through: 6.0, by: 0.8).enumerated() {
            tracks.append(track(id: i, position: Vec2(x - 3, 3.0), velocity: Vec2(1.0, 0)))
        }
        let out = plan(tracks)
        #expect(out.best.pSafe > 0.9)
        #expect(!out.best.requiresSlowdown)
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
        let f = ConstantVelocityPredictor().predict(tracks: tracks, userVelocity: Vec2(0, 1.3), duration: 5.5)
        let out = planner.plan(forecasts: f, userVelocity: Vec2(0, 1.3), goal: Vec2(0, 25))
        #expect(out.best.requiresSlowdown)
        #expect(out.best.speedRatio.min()! < 0.6)
        #expect(out.best.arcLength.last! < 1.3 * 5 - 0.5)
        // 減速した経路はしない経路より安全。
        let straight = PathPlanner.rollout(shape: out.best.shape, heading: 0, speed: 1.3, dt: 0.2, steps: 25)
        let grid = ForecastGrid(forecasts: f, dt: 0.2, duration: 5)
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
        let f = ConstantVelocityPredictor().predict(tracks: tr, userVelocity: Vec2(0, 1.3), duration: 5.5)
        let grid = ForecastGrid(forecasts: f, dt: 0.2, duration: 5)
        let field = RiskField.compute(grid: grid, model: CollisionModel(), speed: 1.3)
        func safety(at p: Vec2) -> Double {
            let c = Int((p.x - field.origin.x) / field.cellSize), r = Int((p.y - field.origin.y) / field.cellSize)
            return field.safety[r * field.columns + c]
        }
        #expect(safety(at: Vec2(0, 4)) < 0.5)
        #expect(safety(at: Vec2(4, 4)) > 0.95)
    }
}
