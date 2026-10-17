import Foundation
import Testing
import simd
@testable import RouteDanceCore

/// 合成シーン: 平らな地面と、指定位置に立つ人物（円柱）を描いた深度マップ。
struct SyntheticScene {
    var camera: PinholeCamera
    var ground: GroundPlane
    var people: [Vec2] = []
    var personHeight = 1.65
    var personRadius = 0.25

    var geometry: CameraGeometry { CameraGeometry(camera: camera, ground: ground) }

    func depthMap(width: Int = 90, height: Int = 120, noise: Double = 0, seed: UInt64 = 3) -> DepthMap {
        var rng = SeededRandom(seed: seed)
        let cam = camera.scaled(toWidth: width, height: height)
        let g = CameraGeometry(camera: cam, ground: ground)
        var values = [Float](repeating: .nan, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let d = cam.ray(u: Double(x) + 0.5, v: Double(y) + 0.5)
                var best = Double.infinity
                let denom = simd_dot(ground.normal, d)
                if denom < -1e-6 {
                    let t = -ground.height / denom
                    if t * d.z < 60 { best = t * d.z }
                }
                for p in people {
                    // 光線と円柱の交差（地面座標で）
                    for s in stride(from: 0.5, through: 40, by: 0.05) {
                        let c = d * s
                        let gp = g.groundPoint(camera: c)
                        let h = ground.signedDistance(c)
                        if h >= 0, h <= personHeight, (gp - p).length <= personRadius {
                            best = min(best, c.z)
                            break
                        }
                    }
                }
                if best.isFinite {
                    values[y * width + x] = Float(best * (1 + noise * rng.gaussian()))
                }
            }
        }
        return DepthMap(width: width, height: height, values: values, camera: cam, timestamp: 0)
    }

    /// 人物の検出枠（ピクセル、元のカメラ解像度）。
    func detection(for p: Vec2, confidence: Double = 0.9) -> PersonDetection {
        let g = geometry
        let side = Vec2(p.normalized.y, -p.normalized.x) * personRadius
        let corners = [g.project(ground: p + side)!, g.project(ground: p - side)!,
                       g.project(ground: p + side, height: personHeight)!, g.project(ground: p - side, height: personHeight)!]
        return PersonDetection(
            minX: corners.map(\.x).min()!, minY: corners.map(\.y).min()!,
            maxX: corners.map(\.x).max()!, maxY: corners.map(\.y).max()!, confidence: confidence
        )
    }
}

@Suite struct GroundAndLocalizationTests {
    let camera = PinholeCamera(horizontalFOV: 65 * .pi / 180, width: 720, height: 960)

    @Test func groundPlaneRecoveredFromDepth() {
        let truth = GroundPlane.pitched(15 * .pi / 180, height: 1.4)
        let scene = SyntheticScene(camera: camera, ground: truth, people: [Vec2(0.5, 4)])
        let depth = scene.depthMap(noise: 0.01)
        var est = GroundEstimator()
        let obs = est.update(points: depth.groundCandidatePoints(step: 3), at: 0)
        #expect(obs != nil)
        #expect(abs(est.current.height - 1.4) < 0.05)
        #expect(abs(est.current.pitch - truth.pitch) < 1.5 * .pi / 180)
    }

    @Test func personLocalizedWithAndWithoutDepth() {
        let ground = GroundPlane.pitched(10 * .pi / 180, height: 1.45)
        for truth in [Vec2(0.8, 3.5), Vec2(-1.2, 7), Vec2(2, 12)] {
            let scene = SyntheticScene(camera: camera, ground: ground, people: [truth])
            let det = scene.detection(for: truth)
            let loc = PersonLocalizer()
            let noDepth = loc.localize(det, geometry: scene.geometry, depth: nil)!
            #expect((noDepth.position - truth).length < 0.15 * truth.length)
            #expect(noDepth.sources.contains(.footRay))
            let depth = scene.depthMap()
            let withDepth = loc.localize(det, geometry: scene.geometry, depth: depth)!
            #expect(withDepth.sources.contains(.depth))
            #expect((withDepth.position - truth).length < 0.1 * truth.length + 0.2)
        }
    }

    @Test func feetCutOffUsesOtherCues() {
        let ground = GroundPlane.pitched(5 * .pi / 180, height: 1.45)
        let truth = Vec2(0, 1.6)
        let scene = SyntheticScene(camera: camera, ground: ground, people: [truth])
        var det = scene.detection(for: truth)
        det.maxY = Double(camera.height)  // 足元が画面外
        let loc = PersonLocalizer().localize(det, geometry: scene.geometry, depth: scene.depthMap())!
        #expect(!loc.sources.contains(.footRay))
        #expect((loc.position - truth).length < 0.5)
    }

    @Test func farthestVisibleGroundStopsAtObstacle() {
        let ground = GroundPlane.pitched(12 * .pi / 180, height: 1.45)
        let open = SyntheticScene(camera: camera, ground: ground)
        let d0 = open.depthMap().farthestVisibleGround(heading: 0, geometry: open.geometry)!
        #expect(d0 > 15)
        let blocked = SyntheticScene(camera: camera, ground: ground, people: [Vec2(0, 6)])
        let d1 = blocked.depthMap().farthestVisibleGround(heading: 0, geometry: blocked.geometry)!
        #expect(d1 < 7.1 && d1 > 3)
    }
}

@Suite struct OdometryTests {
    @Test func recoversRigidMotion() {
        var rng = SeededRandom(seed: 11)
        let truth = Pose2D(rotation: 0.05, translation: Vec2(0.02, -0.06))
        var pairs: [GroundOdometry.Correspondence] = []
        for _ in 0..<150 {
            let p = Vec2(Double.random(in: -3...3, using: &rng), Double.random(in: 1...8, using: &rng))
            var c = truth.apply(p)
            c += Vec2(rng.gaussian(), rng.gaussian()) * 0.01
            pairs.append(.init(previous: p, current: c))
        }
        // 外れ値（他歩行者の上の点など）
        for _ in 0..<50 {
            let p = Vec2(Double.random(in: -3...3, using: &rng), Double.random(in: 1...8, using: &rng))
            pairs.append(.init(previous: p, current: p + Vec2(0.3, 0.2)))
        }
        let r = GroundOdometry.estimate(pairs)!
        #expect(abs(r.transform.rotation - truth.rotation) < 0.005)
        #expect((r.transform.translation - truth.translation).length < 0.01)
        #expect(r.inlierCount >= 140)
    }

    @Test func egoSpeedFromWalkingForward() {
        // 1.3 m/s で前進 → 世界は毎フレーム -v·dt 動く。
        var ego = EgoMotionEstimator()
        var state: EgoMotionEstimator.State?
        let dt = 1.0 / 30
        for i in 0...90 {
            let d: Pose2D? = i == 0 ? nil : Pose2D(rotation: 0, translation: Vec2(0, -1.3 * dt))
            state = ego.update(d, at: Double(i) * dt)
        }
        #expect(abs(state!.velocity.y - 1.3) < 0.02)
        #expect(abs(state!.velocity.x) < 0.02)
        #expect(abs(state!.speed - 1.3) < 0.05)
        #expect(state!.isTracking)
    }
}

@Suite struct OpticalFlowTests {
    /// 滑らかなテクスチャ画像。
    func texture(width: Int, height: Int, shift: SIMD2<Double>) -> GrayImage {
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) - shift.x, v = Double(y) - shift.y
                let val = 0.5 + 0.2 * sin(u * 0.13) * cos(v * 0.11) + 0.15 * sin((u + v) * 0.07) + 0.1 * cos(u * 0.05 - v * 0.09)
                px[y * width + x] = Float(val)
            }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }

    @Test func tracksTranslation() {
        let flow = SparseOpticalFlow()
        let a = texture(width: 160, height: 200, shift: .zero)
        let b = texture(width: 160, height: 200, shift: SIMD2(6.5, -9.25))
        let pa = flow.pyramid(a), pb = flow.pyramid(b)
        var flowConfig = SparseOpticalFlow.Config()
        flowConfig.minEigenvalue = 1e-6
        let pts = SparseOpticalFlow(config: flowConfig).selectFeatures(in: a, spacing: 12) { x, y in x > 20 && x < 140 && y > 20 && y < 180 }
        #expect(pts.count > 30)
        let tracked = flow.track(points: pts, prev: pa, next: pb)
        let ok = zip(pts, tracked).compactMap { p, q in q.map { $0 - p } }
        #expect(Double(ok.count) > Double(pts.count) * 0.8)
        let meanX = ok.map(\.x).reduce(0, +) / Float(ok.count)
        let meanY = ok.map(\.y).reduce(0, +) / Float(ok.count)
        #expect(abs(meanX - 6.5) < 0.2)
        #expect(abs(meanY + 9.25) < 0.2)
    }
}
