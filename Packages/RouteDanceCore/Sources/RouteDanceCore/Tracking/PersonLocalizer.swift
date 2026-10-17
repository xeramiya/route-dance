import Foundation

/// 人物検出（画像上の枠）。座標はピクセル、左上原点。
public struct PersonDetection: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    public var confidence: Double
    public var isUpperBodyOnly: Bool

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double, confidence: Double, isUpperBodyOnly: Bool = false) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.confidence = confidence
        self.isUpperBodyOnly = isUpperBodyOnly
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var centerX: Double { (minX + maxX) / 2 }

    public func iou(_ o: PersonDetection) -> Double {
        let ix = max(0, min(maxX, o.maxX) - max(minX, o.minX))
        let iy = max(0, min(maxY, o.maxY) - max(minY, o.minY))
        let inter = ix * iy
        let union = width * height + o.width * o.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// 深度マップの読み出し。カメラと同じ解像度とは限らないので、正規化座標で引く。
public protocol DepthSampler: Sendable {
    /// 正規化座標 (0...1, 0...1) のz深度（m）。無効なら nil。
    func depth(nx: Double, ny: Double) -> Double?
}

/// 枠から、地面上の位置とその不確かさを求める。
public struct LocalizedPerson: Sendable {
    public var detection: PersonDetection
    public var position: Vec2
    /// 位置の分散（m²）。進行方向の区別はせず、距離方向と横方向の分散。
    public var rangeVariance: Double
    public var lateralVariance: Double
    public var sources: Set<Source>

    public enum Source: String, Sendable {
        case footRay, depth, heightPrior
    }
}

public struct PersonLocalizer: Sendable {
    public struct Config: Sendable {
        public var personHeight = 1.65
        public var personHeightStd = 0.10
        /// 体の厚みの半分（深度は体の表面までなので、中心までの補正）。
        public var bodyHalfDepth = 0.15
        /// 足元の判定: 枠の下端が画像下端からこの割合以内なら足元が切れている。
        public var bottomMargin = 0.01
        /// 深度の相対誤差（MoGe-2 + スケール誤差込みの目安）。
        public var depthRelativeStd = 0.08
        /// 足元のピクセル誤差（枠の下端のずれ）。
        public var footPixelStd = 4.0
        public init() {}
    }

    public var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public func localize(_ det: PersonDetection, geometry g: CameraGeometry, depth: (any DepthSampler)?) -> LocalizedPerson? {
        let cam = g.camera
        var estimates: [(range: Double, variance: Double, source: LocalizedPerson.Source)] = []
        let u = det.centerX

        // 足元レイ
        let feetVisible = !det.isUpperBodyOnly && det.maxY < Double(cam.height) * (1 - config.bottomMargin)
        if feetVisible, let p = g.intersectGround(u: u, v: det.maxY) {
            let r = p.length
            // 角度誤差 δθ ≈ σ_px / f に対し、距離誤差 ≈ r² δθ / h。
            let dTheta = config.footPixelStd / cam.fy
            let sigma = r * r * dTheta / max(g.ground.height, 0.5) + 0.05
            estimates.append((r, sigma * sigma, .footRay))
        }

        // 深度: 枠の中央の縦帯の中央値
        if let depth {
            var samples: [Double] = []
            let y0 = det.minY + det.height * 0.2, y1 = det.minY + det.height * (det.isUpperBodyOnly ? 0.9 : 0.6)
            let x0 = det.centerX - det.width * 0.15, x1 = det.centerX + det.width * 0.15
            for iy in 0..<6 {
                for ix in 0..<3 {
                    let x = x0 + (x1 - x0) * (Double(ix) + 0.5) / 3
                    let y = y0 + (y1 - y0) * (Double(iy) + 0.5) / 6
                    if let d = depth.depth(nx: x / Double(cam.width), ny: y / Double(cam.height)), d > 0.2, d < 80 {
                        samples.append(d)
                    }
                }
            }
            if samples.count >= 4 {
                samples.sort()
                let z = samples[samples.count / 2] + config.bodyHalfDepth
                // z深度から光線に沿って体の中心の地面位置を求める。
                let ray = cam.ray(u: u, v: (y0 + y1) / 2)
                let center = ray * z
                let p = g.groundPoint(camera: center)
                let sigma = config.depthRelativeStd * p.length + 0.1
                estimates.append((p.length, sigma * sigma, .depth))
            }
        }

        // 身長の事前分布（頭頂の位置から）
        if !det.isUpperBodyOnly, det.minY > 2 {
            // 頭頂の光線と、地面から personHeight の高さの平面との交点を求める（足元ではなく頭で測る）。
            let ray = cam.ray(u: u, v: det.minY)
            let n = g.ground.normal
            let denom = simd_dot_d(n, ray)
            // normal·X + height = personHeight の平面
            if abs(denom) > 1e-6 {
                let t = (config.personHeight - g.ground.height) / denom
                if t > 0 {
                    let p = g.groundPoint(camera: ray * t)
                    let r = p.length
                    if r > 0.5, r < 60 {
                        // r ∝ 1/|H − h| なので、カメラが頭の高さに近いほど身長のばらつきが大きく効く。
                        let dh = max(abs(config.personHeight - g.ground.height), 0.05)
                        let sigma = r * config.personHeightStd / dh + 0.2
                        estimates.append((r, sigma * sigma, .heightPrior))
                    }
                }
            }
        }

        guard !estimates.isEmpty else { return nil }
        // 距離は分散の逆数で重み付け平均し、方向は枠の中心の光線で決める。
        var wsum = 0.0, rsum = 0.0
        for e in estimates {
            let w = 1 / e.variance
            wsum += w
            rsum += w * e.range
        }
        let range = rsum / wsum
        // 地面座標の基底は法線と直交しているので、光線を地面へ射影した向きがそのまま方位になる。
        let dir = g.groundPoint(camera: cam.ray(u: u, v: det.maxY)).normalized
        guard dir != .zero else { return nil }
        let position = dir * range
        let lateralSigma = range * 0.01 + 0.05
        return LocalizedPerson(
            detection: det,
            position: position,
            rangeVariance: 1 / wsum,
            lateralVariance: lateralSigma * lateralSigma,
            sources: Set(estimates.map(\.source))
        )
    }
}

@inline(__always)
func simd_dot_d(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}
