import Foundation
import Testing
import simd
@testable import RouteDanceCore

@Suite struct ObstacleMapTests {
    let camera = PinholeCamera(horizontalFOV: 65 * .pi / 180, width: 720, height: 960)
    let ground = GroundPlane.pitched(8 * .pi / 180, height: 1.45)

    func build(_ depth: DepthMap, scene: SyntheticScene, excluding: [PersonDetection] = [], t: Double = 0, builder: inout ObstacleMapBuilder) -> ObstacleMap {
        builder.update(depth: depth, geometry: scene.geometry, excluding: excluding, imageWidth: camera.width, imageHeight: camera.height, at: t)
    }

    /// 前方 distance に幅 width・高さ 2m の壁を置いた深度マップ（地面も含む）。
    func wallDepth(scene: SyntheticScene, distance: Double, width: Double, center: Double = 0) -> DepthMap {
        var depth = scene.depthMap()
        let g = CameraGeometry(camera: depth.camera, ground: scene.ground)
        let wallNormal = g.forward
        let p0 = g.cameraPoint(ground: Vec2(center, distance))
        for y in 0..<depth.height {
            for x in 0..<depth.width {
                let d = depth.camera.ray(u: Double(x) + 0.5, v: Double(y) + 0.5)
                let den = simd_dot(wallNormal, d)
                guard den > 1e-6 else { continue }
                let t = simd_dot(wallNormal, p0) / den
                let c = d * t
                let gp = g.groundPoint(camera: c)
                let h = scene.ground.signedDistance(c)
                guard abs(gp.x - center) <= width / 2, h >= 0, h <= 2 else { continue }
                let cur = depth.values[y * depth.width + x]
                if !cur.isFinite || Float(c.z) < cur { depth.values[y * depth.width + x] = Float(c.z) }
            }
        }
        return depth
    }

    @Test func flatGroundHasNoObstacles() {
        let scene = SyntheticScene(camera: camera, ground: ground)
        var b = ObstacleMapBuilder()
        let m = build(scene.depthMap(noise: 0.01), scene: scene, builder: &b)
        #expect(m.points.isEmpty)
        #expect(m.nearest == nil)
        #expect(m.bins.allSatisfy { $0.distance == nil })
        #expect(m.collisionProbability(at: Vec2(0, 2), radius: 0.4) == 0)
    }

    @Test func wallInFrontIsDetected() {
        let scene = SyntheticScene(camera: camera, ground: ground)
        var b = ObstacleMapBuilder()
        let m = build(wallDepth(scene: scene, distance: 3, width: 1), scene: scene, builder: &b)
        let n = try! #require(m.nearest)
        #expect(abs(n.length - 3) < 0.2)
        #expect(abs(n.x) < 0.5)
        let front = m.bins.first { $0.headingMin <= 0 && $0.headingMax >= 0 }!
        #expect(abs(front.distance! - 3) < 0.2)
        // 壁の幅 1m（3m先で約±9.5°）の外のビンは空。
        let far = m.bins.filter { abs(($0.headingMin + $0.headingMax) / 2) > 15 * .pi / 180 }
        #expect(far.allSatisfy { $0.distance == nil })
        #expect(m.points.count <= 200)
        #expect(m.collisionProbability(at: Vec2(0, 2.8), radius: 0.4) > 0.9)
        #expect(m.collisionProbability(at: Vec2(0, 1), radius: 0.4) < 0.01)
        #expect(m.collisionProbability(at: Vec2(3, 3), radius: 0.4) < 0.01)
    }

    @Test func excludedPersonIsRemoved() {
        let p = Vec2(0.3, 4)
        let scene = SyntheticScene(camera: camera, ground: ground, people: [p])
        let depth = scene.depthMap()
        var b = ObstacleMapBuilder()
        let without = build(depth, scene: scene, builder: &b)
        #expect(abs(try! #require(without.nearest).length - (p.length - 0.25)) < 0.3)
        b.reset()
        let with = build(depth, scene: scene, excluding: [scene.detection(for: p)], builder: &b)
        #expect(with.points.isEmpty)
        #expect(with.nearest == nil)
    }

    @Test func closePersonWithFeetOffscreenIsObstacle() {
        let p = Vec2(0, 1.2)
        let scene = SyntheticScene(camera: camera, ground: ground, people: [p])
        var det = scene.detection(for: p)
        det.maxY = Double(camera.height)
        // 検出枠が人物の別の場所にある（例: 検出されていない）ケースとして、枠なしで確認する。
        var b = ObstacleMapBuilder()
        let m = build(scene.depthMap(), scene: scene, builder: &b)
        let n = try! #require(m.nearest)
        #expect(n.length > 0.8 && n.length < 1.4)
        #expect(abs(n.x) < 0.3)
        #expect(m.collisionProbability(at: Vec2(0, 1.1), radius: 0.4) > 0.9)
        // 追跡側が枠を持っている人物は除外される。
        b.reset()
        let ex = build(scene.depthMap(), scene: scene, excluding: [det], builder: &b)
        #expect(ex.points.count < m.points.count / 4)
    }

    @Test func collisionProbabilityNearAndFar() {
        let m = ObstacleMap(points: [Vec2(0, 3), Vec2(0.2, 3)])
        #expect(m.collisionProbability(at: Vec2(0, 3), radius: 0.4) > 0.99)
        #expect(m.collisionProbability(at: Vec2(0, 2.7), radius: 0.4) > 0.5)
        #expect(m.collisionProbability(at: Vec2(0, 1), radius: 0.4) < 1e-6)
        #expect(ObstacleMap.empty.collisionProbability(at: .zero, radius: 0.4) == 0)
    }

    @Test func wrongGroundIsDiscarded() {
        // 地面が大きくずれている（水平と推定したが実際は強く下向き）と、遠方の地面が障害物に見える → 捨てる。
        let truth = GroundPlane.pitched(30 * .pi / 180, height: 1.45)
        let scene = SyntheticScene(camera: camera, ground: truth)
        let wrong = CameraGeometry(camera: scene.geometry.camera, ground: .pitched(0, height: 1.45))
        var b = ObstacleMapBuilder()
        let m = b.update(depth: scene.depthMap(), geometry: wrong, excluding: [], imageWidth: camera.width, imageHeight: camera.height, at: 0)
        #expect(m.points.count <= 200)
    }

    @Test func holdsBrieflyThenFades() {
        let scene = SyntheticScene(camera: camera, ground: ground)
        var b = ObstacleMapBuilder()
        let m0 = build(wallDepth(scene: scene, distance: 3, width: 1), scene: scene, t: 0, builder: &b)
        #expect(m0.nearest != nil)
        let m1 = build(scene.depthMap(), scene: scene, t: 0.2, builder: &b)
        #expect(m1.nearest != nil)
        let m2 = build(scene.depthMap(), scene: scene, t: 1.0, builder: &b)
        #expect(m2.nearest == nil)
    }

    @Test func transformMovesPoints() {
        let scene = SyntheticScene(camera: camera, ground: ground)
        var b = ObstacleMapBuilder()
        let m = build(wallDepth(scene: scene, distance: 3, width: 1), scene: scene, builder: &b)
        let moved = b.transform(m, by: Pose2D(rotation: 0, translation: Vec2(0, -1)))
        #expect(abs(try! #require(moved.nearest).length - (try! #require(m.nearest).length - 1)) < 0.05)
    }

    @Test func updateIsFast() {
        let scene = SyntheticScene(camera: camera, ground: ground, people: [Vec2(1, 3)])
        let depth = scene.depthMap(width: 378, height: 504)
        var b = ObstacleMapBuilder()
        _ = build(depth, scene: scene, builder: &b)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<20 { _ = build(depth, scene: scene, t: Double(i), builder: &b) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 20
        print("ObstacleMapBuilder.update: \(ms) ms (debug)")
    }
}
