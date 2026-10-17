import Foundation
import Testing
@testable import RouteDanceCore

/// NavigationCore を通して、座標の向き（符号）が端から端まで正しいことを確かめる。
///
/// 合成の世界: 平らな地面、ユーザーは前方へ 1.3 m/s で歩く。地面上の点と人物を毎フレーム画像に投影して、
/// 検出・フローの入力を作る（深度は与えず、既定の地面と足元レイだけで動かす）。
@Suite struct NavigationCoreTests {
    let camera = PinholeCamera(horizontalFOV: 65 * .pi / 180, width: 720, height: 960)
    let ground = GroundPlane.pitched(10 * .pi / 180, height: 1.45)

    func run(userSpeed: Double, pedestrian: (Double) -> Vec2, frames: Int = 45) -> NavigationSnapshot {
        var core = NavigationCore()
        let g = CameraGeometry(camera: camera, ground: ground)
        var rng = SeededRandom(seed: 5)
        let landmarks = (0..<200).map { _ in Vec2(Double.random(in: -4...4, using: &rng), Double.random(in: 1.5...10, using: &rng)) }
        let dt = 1.0 / 15
        var last: NavigationSnapshot?
        for i in 0..<frames {
            let t = Double(i) * dt
            let userY = userSpeed * t
            let prevY = userSpeed * (t - dt)
            // 世界座標のランドマークを、前後のフレームのユーザー座標系で見る。
            var pairs: [(previous: SIMD2<Double>, current: SIMD2<Double>)] = []
            if i > 0 {
                for l in landmarks {
                    // ランドマークは世界座標で y = l.y + 5 に固定。ユーザーから見た位置は前進ぶんだけ近づく。
                    let prevRel = Vec2(l.x, (l.y + 5) - prevY)
                    let curRel = Vec2(l.x, (l.y + 5) - userY)
                    guard let pa = g.project(ground: prevRel), let pb = g.project(ground: curRel),
                          pa.y > 0, pa.y < 960, pb.y > 0, pb.y < 960, pa.x > 0, pa.x < 720, pb.x > 0, pb.x < 720
                    else { continue }
                    pairs.append((pa, pb))
                }
            }
            let pw = pedestrian(t)
            let rel = Vec2(pw.x, pw.y - userY)
            let scene = SyntheticScene(camera: camera, ground: ground, people: [rel])
            let det = scene.detection(for: rel)
            let input = PerceptionInput(
                timestamp: t, imageWidth: 720, imageHeight: 960, detections: [det], flowPairs: pairs,
                knownHorizontalFOV: camera.horizontalFOV
            )
            last = core.process(input)
        }
        return last!
    }

    @Test func walkingForwardGivesForwardVelocity() {
        let s = run(userSpeed: 1.3) { _ in Vec2(3, 30) }
        #expect(abs(s.userVelocity.y - 1.3) < 0.15)
        #expect(abs(s.userVelocity.x) < 0.1)
        #expect(s.egoTracking)
    }

    @Test func oncomingPedestrianIsTrackedWithWorldVelocity() {
        // 他歩行者は世界座標で -1.0 m/s（こちらへ向かってくる）。ユーザーは +1.3 m/s。
        let s = run(userSpeed: 1.3) { t in Vec2(-0.3, 14 - 1.0 * t) }
        let tr = s.tracks.first { $0.state == .confirmed }
        #expect(tr != nil)
        if let tr {
            // 追跡の速度は地面（世界）に対する速度なので、自分の移動ぶんは差し引かれているはず。
            #expect(abs(tr.velocity.y + 1.0) < 0.3)
        }
        let plan = s.plan!
        // 正面左から来る人を避けるので、矢印は右寄り、経路は現在速度で約5秒分。
        #expect(plan.best.lookaheadHeading > -0.05)
        #expect(plan.best.pSafe > 0.8)
        #expect(abs(plan.planningSpeed - s.userVelocity.length) < 0.2)
    }
}
