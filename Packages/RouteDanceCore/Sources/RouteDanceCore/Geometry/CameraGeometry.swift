import Foundation
import simd

/// ピクセル単位のピンホールカメラ。画像座標は左上原点、カメラ座標はOpenCV系（x右・y下・z前）。
public struct PinholeCamera: Sendable, Equatable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// 水平画角（ラジアン）から作る。主点は画像中心、正方画素。
    public init(horizontalFOV: Double, width: Int, height: Int) {
        let f = Double(width) / 2 / tan(horizontalFOV / 2)
        self.init(fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2, width: width, height: height)
    }

    /// MoGeの正規化内部パラメータから作る。
    public init(_ k: MoGeIntrinsics, width: Int, height: Int) {
        self.init(
            fx: Double(k.fx) * Double(width), fy: Double(k.fy) * Double(height),
            cx: Double(k.cx) * Double(width), cy: Double(k.cy) * Double(height),
            width: width, height: height
        )
    }

    public var horizontalFOV: Double { 2 * atan(Double(width) / 2 / fx) }

    /// 別の解像度に拡大縮小したカメラ（同じ画角）。
    public func scaled(toWidth w: Int, height h: Int) -> PinholeCamera {
        let sx = Double(w) / Double(width), sy = Double(h) / Double(height)
        return PinholeCamera(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }

    /// ピクセル (u, v) を通る光線の向き（z = 1 に正規化）。
    public func ray(u: Double, v: Double) -> SIMD3<Double> {
        SIMD3((u - cx) / fx, (v - cy) / fy, 1)
    }

    public func unproject(u: Double, v: Double, depth: Double) -> SIMD3<Double> {
        ray(u: u, v: v) * depth
    }

    public func project(_ p: SIMD3<Double>) -> SIMD2<Double>? {
        guard p.z > 1e-6 else { return nil }
        return SIMD2(fx * p.x / p.z + cx, fy * p.y / p.z + cy)
    }
}

/// カメラ座標系で表した地面平面。`normal · X + height = 0`。
/// `normal` は地面から上向き（カメラ側）の単位ベクトル、`height` はカメラから地面までの距離（m）。
public struct GroundPlane: Sendable, Equatable {
    public var normal: SIMD3<Double>
    public var height: Double

    public init(normal: SIMD3<Double>, height: Double) {
        self.normal = simd_normalize(normal)
        self.height = height
    }

    /// 水平に構えたカメラ（光軸が地面と平行）の地面。
    public static func level(height: Double) -> GroundPlane {
        GroundPlane(normal: SIMD3(0, -1, 0), height: height)
    }

    /// カメラの俯角 pitch（下向き正、ラジアン）と高さから作る。ロールは0。
    public static func pitched(_ pitch: Double, height: Double) -> GroundPlane {
        // カメラ座標で、上向き (0,-1,0) をカメラが下を向くぶん回したもの。
        GroundPlane(normal: SIMD3(0, -cos(pitch), -sin(pitch)), height: height)
    }

    /// 点の地面からの高さ（上が正）。
    public func signedDistance(_ p: SIMD3<Double>) -> Double {
        simd_dot(normal, p) + height
    }

    /// カメラの俯角（光軸が地面に対して下を向く角度、ラジアン）。
    public var pitch: Double { asin(max(-1, min(1, -normal.z))) }

    /// カメラのロール（ラジアン）。画像の右側が下がる向きが正。
    public var roll: Double { atan2(-normal.x, -normal.y) }
}

/// 画像と地面座標（俯瞰2D）の相互変換。
public struct CameraGeometry: Sendable, Equatable {
    public var camera: PinholeCamera
    public var ground: GroundPlane

    /// 地面座標の基底（カメラ座標）。
    public let foot: SIMD3<Double>
    public let forward: SIMD3<Double>
    public let right: SIMD3<Double>

    public init(camera: PinholeCamera, ground: GroundPlane) {
        self.camera = camera
        self.ground = ground
        let n = ground.normal
        foot = -ground.height * n
        var f = SIMD3<Double>(0, 0, 1) - n.z * n
        if simd_length(f) < 1e-6 {
            // 真下を向いている場合は、画像の上方向を前とする。
            f = SIMD3<Double>(0, -1, 0) - n.y * n
        }
        forward = simd_normalize(f)
        right = simd_normalize(simd_cross(forward, n))
    }

    /// 地面座標 (x, y) と高さ z（上が正）をカメラ座標へ。
    public func cameraPoint(ground p: Vec2, height z: Double = 0) -> SIMD3<Double> {
        let lateral: SIMD3<Double> = right * p.x
        let ahead: SIMD3<Double> = forward * p.y
        let up: SIMD3<Double> = ground.normal * z
        return foot + lateral + ahead + up
    }

    /// カメラ座標の点を地面座標へ投影する（高さは捨てる）。
    public func groundPoint(camera p: SIMD3<Double>) -> Vec2 {
        let d = p - foot
        return Vec2(simd_dot(d, right), simd_dot(d, forward))
    }

    /// 地面上の点を画像へ投影する。
    public func project(ground p: Vec2, height z: Double = 0) -> SIMD2<Double>? {
        camera.project(cameraPoint(ground: p, height: z))
    }

    /// ピクセルを通る光線と地面の交点。光線が地平線より上を向くか、遠すぎる場合は nil。
    public func intersectGround(u: Double, v: Double, maxDistance: Double = 200) -> Vec2? {
        let d = camera.ray(u: u, v: v)
        let denom = simd_dot(ground.normal, d)
        guard denom < -1e-6 else { return nil }
        let t = -ground.height / denom
        let p = d * t
        let g = groundPoint(camera: p)
        guard g.length <= maxDistance else { return nil }
        return g
    }

    /// 画像上の地平線の y 座標（画像中心の列での値）。
    public var horizonY: Double? {
        // 光線 d が地面と平行になる v を求める: n · d = 0。
        let n = ground.normal
        let u = camera.cx
        // n.x*(u-cx)/fx + n.y*(v-cy)/fy + n.z = 0
        guard abs(n.y) > 1e-9 else { return nil }
        let a = n.x * (u - camera.cx) / camera.fx + n.z
        return camera.cy - a * camera.fy / n.y
    }
}
