import Foundation

/// メトリックz深度のマップ（m）。無効画素は NaN。
public struct DepthMap: DepthSampler {
    public var width: Int
    public var height: Int
    public var values: [Float]
    /// 推定した（または既知の）カメラ。深度マップの解像度での値。
    public var camera: PinholeCamera
    public var timestamp: Double

    public init(width: Int, height: Int, values: [Float], camera: PinholeCamera, timestamp: Double) {
        self.width = width
        self.height = height
        self.values = values
        self.camera = camera
        self.timestamp = timestamp
    }

    public init(_ r: MoGeDepthResult, timestamp: Double) {
        self.init(
            width: r.width, height: r.height, values: r.depth,
            camera: PinholeCamera(r.intrinsics, width: r.width, height: r.height), timestamp: timestamp
        )
    }

    public func depth(nx: Double, ny: Double) -> Double? {
        let x = Int(nx * Double(width)), y = Int(ny * Double(height))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let v = values[y * width + x]
        return v.isFinite && v > 0 ? Double(v) : nil
    }

    /// 地面推定用の点群（カメラ座標）。画面の下側から格子状に取り、除外領域（人物の枠など、正規化座標）を避ける。
    public func groundCandidatePoints(
        startFraction: Double = 0.45, step: Int = 6, maxDepth: Double = 15, excluding: [(Double, Double, Double, Double)] = []
    ) -> [SIMD3<Double>] {
        var pts: [SIMD3<Double>] = []
        let y0 = Int(Double(height) * startFraction)
        var y = y0
        while y < height {
            var x = step / 2
            while x < width {
                let nx = Double(x) / Double(width), ny = Double(y) / Double(height)
                let blocked = excluding.contains { nx >= $0.0 && nx <= $0.2 && ny >= $0.1 && ny <= $0.3 }
                let v = values[y * width + x]
                if !blocked, v.isFinite, v > 0.2, Double(v) < maxDepth {
                    pts.append(camera.unproject(u: Double(x) + 0.5, v: Double(y) + 0.5, depth: Double(v)))
                }
                x += step
            }
            y += step
        }
        return pts
    }

    /// 方位 heading（地面座標）に沿って、地面として見えている最も遠い距離を求める。
    ///
    /// 地面上の点を手前から順に投影し、観測深度が地面の期待深度より明らかに手前なら（障害物で隠れている）そこで止める。
    public func farthestVisibleGround(heading: Double, geometry g: CameraGeometry, maxDistance: Double = 30, step: Double = 0.5) -> Double? {
        let cam = g.camera
        var last: Double?
        var occludedRun = 0
        var r = 1.0
        while r <= maxDistance {
            let p = Vec2.fromHeading(heading, length: r)
            let c = g.cameraPoint(ground: p)
            guard let px = cam.project(c) else { break }
            let nx = px.x / Double(cam.width), ny = px.y / Double(cam.height)
            guard nx >= 0, nx < 1, ny >= 0, ny < 1 else {
                if last != nil { break }
                r += step
                continue
            }
            if let d = depth(nx: nx, ny: ny) {
                if d < c.z * 0.9 {
                    occludedRun += 1
                    if occludedRun >= 2 { break }
                } else {
                    occludedRun = 0
                    last = r
                }
            }
            r += step
        }
        return last
    }
}
