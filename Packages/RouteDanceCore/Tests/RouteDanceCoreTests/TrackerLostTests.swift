import Foundation
import Testing
@testable import RouteDanceCore

/// 検出が抜けたときに、外挿した位置で回避対象に残ることを確かめる。
@Suite struct TrackerLostTests {
    func person(_ p: Vec2, score: Double = 0.9) -> LocalizedPerson {
        LocalizedPerson(
            detection: PersonDetection(minX: 100, minY: 100, maxX: 160, maxY: 300, confidence: score),
            position: p, rangeVariance: 0.04, lateralVariance: 0.01, sources: [.footRay]
        )
    }

    @Test func lostTrackIsExtrapolatedAndStaysActive() {
        var tracker = PedestrianTracker()
        let dt = 1.0 / 15
        // 横切る人（右へ 1.2 m/s、3m 先）。1秒見えて、その後0.8秒検出が抜ける。
        for i in 0..<15 {
            let t = Double(i) * dt
            tracker.update(persons: [person(Vec2(-1.5 + 1.2 * t, 3))], egoDelta: .identity, at: t)
        }
        let id = tracker.activeTracks.first!.id
        for i in 15..<27 {
            tracker.update(persons: [], egoDelta: .identity, at: Double(i) * dt)
        }
        let tr = tracker.activeTracks.first { $0.id == id }
        #expect(tr != nil)
        if let tr {
            #expect(tr.state == .lost)
            // 外挿: t=1.73s で x ≈ -1.5 + 1.2·1.73 ≈ 0.58
            #expect(abs(tr.position.x - (-1.5 + 1.2 * 26 * dt)) < 0.3)
            // 見失い中は不確かさが増える。
            #expect(tr.positionSigma > 0.15)
        }
    }

    @Test func nearDetectionConfirmsImmediately() {
        var tracker = PedestrianTracker()
        tracker.update(persons: [person(Vec2(0.3, 2.0))], egoDelta: .identity, at: 0)
        #expect(tracker.activeTracks.count == 1)
        tracker.update(persons: [person(Vec2(0, 12))], egoDelta: .identity, at: 0.1)
        // 遠い人は確定を待つ。
        #expect(tracker.activeTracks.count == 1)
    }

    @Test func processNoiseIsFrameRateIndependent() {
        // 30fps と 10fps で 1秒予測したときの位置の分散がほぼ同じ。
        func variance(fps: Double) -> Double {
            var f = GroundKalman(position: .zero, variance: 0.01)
            for _ in 0..<Int(fps) { f.predict(dt: 1 / fps) }
            return f.positionCovariance[0][0]
        }
        let a = variance(fps: 30), b = variance(fps: 10)
        #expect(abs(a - b) / a < 0.05)
    }

    @Test func reacquiredTrackRecoversVelocity() {
        var tracker = PedestrianTracker()
        let dt = 0.1
        // 最初は止まっていた人が、見失っている間に歩き出す。
        for i in 0..<10 { tracker.update(persons: [person(Vec2(0, 6))], egoDelta: .identity, at: Double(i) * dt) }
        for i in 10..<16 { tracker.update(persons: [], egoDelta: .identity, at: Double(i) * dt) }
        // 0.6秒後に再検出。その間に x 方向へ 0.6 m 進んでいた（1 m/s）。
        tracker.update(persons: [person(Vec2(0.6, 6))], egoDelta: .identity, at: 1.6)
        let tr = tracker.activeTracks.first!
        #expect(tr.velocity.x > 0.6)
    }
}
