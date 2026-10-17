import Foundation

/// 深度マップから作った静的障害物（壁、柱、全身が映っていない近くの人など）の地面上の地図。
///
/// 極座標の格子（方位ビンごとの最短距離）と、そこから作った障害物点で表す。
/// 計画は `collisionProbability(at:radius:)` を経路の各点で引き、デバッグUIは `points` と `nearest` を描く。
public struct ObstacleMap: Sendable {
    /// 障害物と判定した地面上の点（現フレームの地面座標）。
    public var points: [Vec2]
    /// 方位ビン（heading の小さい順）。
    public var bins: [Bin]
    /// 最も近い障害物（ユーザーの前方±90°）。
    public var nearest: Vec2?
    public var timestamp: Double

    public struct Bin: Sendable {
        public var headingMin: Double
        public var headingMax: Double
        /// このビンで最も近い障害物までの距離（m）。なければ nil。
        public var distance: Double?
    }

    public init(points: [Vec2] = [], bins: [Bin] = [], nearest: Vec2? = nil, timestamp: Double = 0) {
        self.points = points
        self.bins = bins
        self.nearest = nearest
        self.timestamp = timestamp
    }

    public static let empty = ObstacleMap()

    /// 点 p にユーザー（半径 radius）がいるときに、障害物とぶつかる確率（0...1）。
    public func collisionProbability(at p: Vec2, radius: Double) -> Double {
        var best = Double.infinity
        for q in points {
            let d = (q - p).lengthSquared
            if d < best { best = d }
        }
        guard best.isFinite else { return 0 }
        let d = best.squareRoot()
        // 距離 radius で 0.5、radius - 0.15 で ≈1、radius + 0.3 で ≈0。
        return 1 / (1 + exp((d - radius) / 0.08))
    }
}

/// 深度マップから ObstacleMap を作る（仮実装: 中身は別担当が実装する）。
public struct ObstacleMapBuilder: Sendable {
    public init() {}

    public mutating func reset() {}

    /// 新しい深度で障害物地図を作り直す。excluding は人物の検出枠（ピクセル、追跡側で扱うので除外する）。
    public mutating func update(
        depth: DepthMap, geometry: CameraGeometry, excluding: [PersonDetection], imageWidth: Int, imageHeight: Int, at t: Double
    ) -> ObstacleMap {
        ObstacleMap(timestamp: t)
    }

    /// 深度がないフレームで、自己位置の変化（前→現）だけ適用する。
    public func transform(_ m: ObstacleMap, by delta: Pose2D) -> ObstacleMap {
        var r = m
        r.points = m.points.map { delta.apply($0) }
        r.nearest = m.nearest.map { delta.apply($0) }
        return r
    }
}
