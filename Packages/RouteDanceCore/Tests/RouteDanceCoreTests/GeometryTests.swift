import Foundation
import Testing
@testable import RouteDanceCore

@Suite struct GeometryTests {
    let cam = PinholeCamera(horizontalFOV: 65 * .pi / 180, width: 720, height: 960)

    @Test func headingAndRotationAreConsistent() {
        let v = Vec2(0, 1)
        #expect(abs(v.heading) < 1e-12)
        let r = v.rotated(by: .pi / 2)
        #expect(abs(r.x - 1) < 1e-12 && abs(r.y) < 1e-12)
        #expect(abs(r.heading - .pi / 2) < 1e-12)
        let h = Vec2.fromHeading(0.3)
        #expect(abs(h.heading - 0.3) < 1e-12)
    }

    @Test func poseInverseAndComposition() {
        let a = Pose2D(rotation: 0.2, translation: Vec2(0.3, -0.5))
        let p = Vec2(1.5, 4)
        let back = a.inverse.apply(a.apply(p))
        #expect((back - p).length < 1e-12)
        let b = Pose2D(rotation: -0.1, translation: Vec2(0.1, 0.2))
        #expect((a.then(b).apply(p) - b.apply(a.apply(p))).length < 1e-12)
    }

    @Test func groundRayRoundTrip() {
        let g = CameraGeometry(camera: cam, ground: .pitched(12 * .pi / 180, height: 1.4))
        for p in [Vec2(0, 3), Vec2(-1.5, 6), Vec2(2, 10)] {
            let px = g.project(ground: p)!
            let back = g.intersectGround(u: px.x, v: px.y)!
            #expect((back - p).length < 1e-6)
        }
        // 地平線より上の光線は地面に当たらない。
        #expect(g.intersectGround(u: 360, v: 10) == nil)
        let hy = g.horizonY!
        #expect(hy > 0 && hy < 480)
    }

    @Test func groundPlaneAnglesAndRoll() {
        let pitch = 0.25
        let gp = GroundPlane.pitched(pitch, height: 1.5)
        #expect(abs(gp.pitch - pitch) < 1e-9)
        #expect(abs(gp.roll) < 1e-9)
        // カメラ直下の点は地面上。
        let g = CameraGeometry(camera: cam, ground: gp)
        #expect(abs(gp.signedDistance(g.foot)) < 1e-9)
        #expect(abs(gp.signedDistance(g.cameraPoint(ground: Vec2(1, 5)))) < 1e-9)
        #expect(abs(gp.signedDistance(g.cameraPoint(ground: Vec2(1, 5), height: 1.7)) - 1.7) < 1e-9)
    }

    @Test func hungarianFindsOptimum() {
        let cost: [[Double]] = [
            [4, 1, 3],
            [2, 0, 5],
            [3, 2, 2],
        ]
        let r = hungarianAssignment(cost, threshold: 10)
        let total = r.reduce(0.0) { $0 + cost[$1.row][$1.col] }
        #expect(r.count == 3)
        #expect(total == 5)  // (0,1) + (1,0) + (2,2)
        // 閾値以上の組は割り当てない。
        let r2 = hungarianAssignment([[1, 9], [9, 9]], threshold: 5)
        #expect(r2.count == 1 && r2[0].row == 0 && r2[0].col == 0)
        // 長方形。
        let r3 = hungarianAssignment([[5, 1, 9, 2]], threshold: 10)
        #expect(r3.count == 1 && r3[0].col == 1)
    }
}
