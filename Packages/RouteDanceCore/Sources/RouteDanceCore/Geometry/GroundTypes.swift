import Foundation
import simd

// 地面座標系（俯瞰2D）:
//   原点はカメラ直下の地面。x は右、y は前（カメラの前方を地面に投影した向き）。単位はメートル。
//   「現在フレームの地面座標」は毎フレーム自己位置推定の結果で更新される。
//   追跡・予測・計画はすべてこの座標系で行う。

public typealias Vec2 = SIMD2<Double>

public extension SIMD2 where Scalar == Double {
    var length: Double { simd_length(self) }
    var lengthSquared: Double { simd_length_squared(self) }
    var normalized: Vec2 {
        let l = length
        return l > 1e-12 ? self / l : .zero
    }
    /// y軸（前方）からの方位角。右回りが正（ラジアン）。
    var heading: Double { atan2(x, y) }
    static func fromHeading(_ h: Double, length: Double = 1) -> Vec2 {
        Vec2(sin(h), cos(h)) * length
    }
    func rotated(by angle: Double) -> Vec2 {
        // 右回り（heading が増える向き）の回転。
        let c = cos(angle), s = sin(angle)
        return Vec2(c * x + s * y, -s * x + c * y)
    }
    func dot(_ o: Vec2) -> Double { simd_dot(self, o) }
    func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
}

/// 角度を (-π, π] に正規化する。
@inlinable
public func wrapAngle(_ a: Double) -> Double {
    var r = fmod(a + .pi, 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r - .pi
}

/// 地面座標系での剛体変換（2D）。前フレームの座標を現フレームの座標へ移す。
public struct Pose2D: Sendable, Equatable {
    /// heading 方向の回転（右回り正）。
    public var rotation: Double
    public var translation: Vec2

    public init(rotation: Double = 0, translation: Vec2 = .zero) {
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = Pose2D()

    public func apply(_ p: Vec2) -> Vec2 { p.rotated(by: rotation) + translation }
    public func applyVector(_ v: Vec2) -> Vec2 { v.rotated(by: rotation) }

    public var inverse: Pose2D {
        let r = -rotation
        return Pose2D(rotation: r, translation: -translation.rotated(by: r))
    }

    /// self の後に other を適用する変換。
    public func then(_ other: Pose2D) -> Pose2D {
        Pose2D(rotation: rotation + other.rotation, translation: other.apply(translation))
    }
}

/// 時刻付きの2D点。
public struct TimedPoint: Sendable, Equatable {
    public var t: Double
    public var p: Vec2
    public init(t: Double, p: Vec2) {
        self.t = t
        self.p = p
    }
}
