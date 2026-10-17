import Foundation
import simd

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

/// 深度マップから ObstacleMap を作る。
///
/// 各画素をカメラ座標の点にして、地面からの高さ h が τ(z) < h < 2m のものを障害物とする
/// （τ(z) = 0.12 + 0.03·z。地面推定の誤差が距離に比例して効くぶん許容を広げる）。
/// 障害物の点を地面へ射影し、方位ビンごとに「近くで複数の点が支持する最小距離」を取る（Stixel World の考え方）。
/// 深度は約5Hzなので、ビンごとに最後の観測を短時間（`holdDuration`）だけ保持して欠測を埋める。
public struct ObstacleMapBuilder: Sendable {
    public struct Config: Sendable {
        /// 方位ビンの幅（ラジアン）。
        public var binWidth = 3.0 * .pi / 180
        /// ビン数（中心が前方になるよう奇数）。47ビン×3° = 前方±70.5°。
        public var binCount = 47
        /// 障害物とみなす高さの範囲: τ(z) < h < maxHeight。
        public var toleranceBase = 0.12
        public var toleranceSlope = 0.03
        public var maxHeight = 2.0
        /// この地面距離（m）より遠い点は使わない。近すぎる点も使わない。
        public var maxRange = 12.0
        public var minRange = 0.25
        /// ビンの最短距離として採用するのに必要な支持点数と、支持点が収まるべき距離の幅（0.3 + 0.06·d）。
        public var minSupport = 3
        /// 壁を表すために、最短距離からこの奥行き（m）までの点も `points` に入れる。
        public var wallDepth = 0.3
        /// `points` の重複除去の格子（m）と最大数。
        public var cell = 0.2
        public var maxPoints = 200
        /// 画素の間引き: 深度マップの幅をこの数で割った値（最小1）おきに見る。
        public var sampleColumns = 96
        /// ビンの観測を保持する時間（秒）。保持した点は自己運動で動かさないので、深度1回ぶんの欠測を埋める程度にとどめる。
        public var holdDuration = 0.3
        /// 人物枠を広げる割合（枠の縁に映る人物の画素を取りこぼさないため）。
        public var excludeMargin = 0.04
        public init() {}
    }

    public var config = Config()

    /// ビンごとの最後の観測。
    private struct BinState: Sendable {
        var distance: Double
        var points: [Vec2]
        var time: Double
    }
    private var held: [BinState?] = []
    private var lastTime = -Double.infinity

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        held = []
        lastTime = -.infinity
    }

    /// 新しい深度で障害物地図を作り直す。excluding は人物の検出枠（ピクセル、追跡側で扱うので除外する）。
    public mutating func update(
        depth: DepthMap, geometry: CameraGeometry, excluding: [PersonDetection], imageWidth: Int, imageHeight: Int, at t: Double
    ) -> ObstacleMap {
        let c = config
        if held.count != c.binCount || t < lastTime { held = Array(repeating: nil, count: c.binCount) }
        lastTime = t

        let fresh = observe(depth: depth, geometry: geometry, excluding: excluding, imageWidth: imageWidth, imageHeight: imageHeight)

        // ビンごとに、新しい観測があれば置き換え、なければ保持時間内の前回の観測を使う。
        var points: [Vec2] = []
        var bins: [ObstacleMap.Bin] = []
        let start = -Double(c.binCount) * c.binWidth / 2
        for i in 0..<c.binCount {
            if let f = fresh?[i] {
                held[i] = BinState(distance: f.distance, points: f.points, time: t)
            } else if let h = held[i], t - h.time > c.holdDuration {
                held[i] = nil
            }
            let lo = start + Double(i) * c.binWidth
            if let h = held[i] {
                bins.append(.init(headingMin: lo, headingMax: lo + c.binWidth, distance: h.distance))
                points += h.points
            } else {
                bins.append(.init(headingMin: lo, headingMax: lo + c.binWidth, distance: nil))
            }
        }
        points = dedupe(points)
        var nearest: Vec2?
        var nearestD = Double.infinity
        for p in points where abs(p.heading) <= .pi / 2 {
            let d = p.lengthSquared
            if d < nearestD { nearestD = d; nearest = p }
        }
        return ObstacleMap(points: points, bins: bins, nearest: nearest, timestamp: t)
    }

    /// 深度がないフレームで、自己位置の変化（前→現）だけ適用する。
    public func transform(_ m: ObstacleMap, by delta: Pose2D) -> ObstacleMap {
        var r = m
        r.points = m.points.map { delta.apply($0) }
        r.nearest = m.nearest.map { delta.apply($0) }
        // ビンは方位ごとの最短距離なので、回転・移動後の点から作り直す。
        r.bins = rebin(m.bins, points: r.points)
        return r
    }

    // MARK: - 内部

    private struct BinObservation {
        var distance: Double
        var points: [Vec2]
    }

    /// 現在の深度から、ビンごとの観測を作る。地面推定の誤りが疑われる場合は nil（観測なし）。
    private func observe(
        depth: DepthMap, geometry g: CameraGeometry, excluding: [PersonDetection], imageWidth: Int, imageHeight: Int
    ) -> [BinObservation?]? {
        let c = config
        let cam = depth.camera
        let w = depth.width, h = depth.height
        guard w > 0, h > 0, imageWidth > 0, imageHeight > 0, depth.values.count >= w * h else { return nil }
        let n = g.ground.normal, height = g.ground.height

        // 人物枠を深度マップの画素座標へ。
        let sx = Double(w) / Double(imageWidth), sy = Double(h) / Double(imageHeight)
        let boxes: [(Double, Double, Double, Double)] = excluding.map { b in
            let mx = (b.maxX - b.minX) * c.excludeMargin, my = (b.maxY - b.minY) * c.excludeMargin
            return ((b.minX - mx) * sx, (b.minY - my) * sy, (b.maxX + mx) * sx, (b.maxY + my) * sy)
        }

        let step = max(1, w / c.sampleColumns)
        let start = -Double(c.binCount) * c.binWidth / 2
        var perBin = [[Vec2]](repeating: [], count: c.binCount)
        var total = 0, obstacleCount = 0, groundCount = 0
        var obstacleDistances: [Double] = []

        var y = step / 2
        while y < h {
            let v = Double(y) + 0.5
            var x = step / 2
            while x < w {
                defer { x += step }
                let u = Double(x) + 0.5
                let zf = depth.values[y * w + x]
                guard zf.isFinite, zf > 0.2 else { continue }
                let z = Double(zf)
                if z > c.maxRange * 1.5 { continue }
                if boxes.contains(where: { u >= $0.0 && u <= $0.2 && v >= $0.1 && v <= $0.3 }) { continue }
                let p = cam.unproject(u: u, v: v, depth: z)
                let hgt = simd_dot(n, p) + height
                let gp = g.groundPoint(camera: p)
                let r = gp.length
                guard r <= c.maxRange else { continue }
                total += 1
                let tau = c.toleranceBase + c.toleranceSlope * z
                if abs(hgt) <= tau { groundCount += 1; continue }
                guard hgt > tau, hgt < c.maxHeight, r >= c.minRange else { continue }
                obstacleCount += 1
                obstacleDistances.append(r)
                let bi = Int(floor((gp.heading - start) / c.binWidth))
                guard bi >= 0, bi < c.binCount, gp.y > 0 else { continue }
                perBin[bi].append(gp)
            }
            y += step
        }

        // 安全策: 画面の大部分が障害物で、地面らしい画素がほとんどなく、障害物が遠い場合は、
        // 地面の推定誤差（まだ収束していない等）とみなして捨てる。
        if total >= 50, Double(obstacleCount) / Double(total) > 0.85, Double(groundCount) / Double(total) < 0.03 {
            obstacleDistances.sort()
            if obstacleDistances[obstacleDistances.count / 2] > 2.0 { return nil }
        }

        var out = [BinObservation?](repeating: nil, count: c.binCount)
        for i in 0..<c.binCount {
            let pts = perBin[i].sorted { $0.lengthSquared < $1.lengthSquared }
            guard pts.count >= c.minSupport else { continue }
            let k = c.minSupport - 1
            for j in 0..<(pts.count - k) {
                let d0 = pts[j].length, d1 = pts[j + k].length
                guard d1 - d0 <= 0.3 + 0.06 * d0 else { continue }
                // 最短距離の点（ビン中心方位）と、その奥 wallDepth までの実際の点。
                let center = start + (Double(i) + 0.5) * c.binWidth
                var ps = [Vec2.fromHeading(center, length: d0)]
                for q in pts[j...] {
                    if q.length > d0 + c.wallDepth { break }
                    ps.append(q)
                }
                out[i] = BinObservation(distance: d0, points: ps)
                break
            }
        }
        return out
    }

    /// 格子で重複を除き、手前の点を優先して最大数に絞る。
    private func dedupe(_ pts: [Vec2]) -> [Vec2] {
        let c = config
        var seen = Set<Int64>()
        var out: [Vec2] = []
        out.reserveCapacity(min(pts.count, c.maxPoints))
        for p in pts.sorted(by: { $0.lengthSquared < $1.lengthSquared }) {
            let ix = Int64(floor(p.x / c.cell)), iy = Int64(floor(p.y / c.cell))
            if seen.insert(ix << 32 ^ (iy & 0xffff_ffff)).inserted {
                out.append(p)
                if out.count >= c.maxPoints { break }
            }
        }
        return out
    }

    /// 点から方位ビンの最短距離を作り直す（ビンの範囲は元のまま）。
    private func rebin(_ bins: [ObstacleMap.Bin], points: [Vec2]) -> [ObstacleMap.Bin] {
        var r = bins
        for i in r.indices { r[i].distance = nil }
        guard let first = bins.first else { return r }
        let width = first.headingMax - first.headingMin
        for p in points {
            let bi = Int(floor((p.heading - first.headingMin) / width))
            guard bi >= 0, bi < r.count else { continue }
            let d = p.length
            if r[bi].distance == nil || d < r[bi].distance! { r[bi].distance = d }
        }
        return r
    }
}
