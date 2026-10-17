import Foundation

/// グレースケール画像（0...1、行優先）。オプティカルフロー用に縮小した輝度画像を想定する。
public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always)
    func at(_ x: Int, _ y: Int) -> Float {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        return pixels[cy * width + cx]
    }

    /// 双線形補間。
    @inline(__always)
    func sample(_ x: Float, _ y: Float) -> Float {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let ax = x - Float(x0), ay = y - Float(y0)
        let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
        return (a * (1 - ax) + b * ax) * (1 - ay) + (c * (1 - ax) + d * ax) * ay
    }

    /// 2x2平均で半分に縮小する。
    public func downsampled() -> GrayImage {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                out[y * w + x] = (at(2 * x, 2 * y) + at(2 * x + 1, 2 * y) + at(2 * x, 2 * y + 1) + at(2 * x + 1, 2 * y + 1)) * 0.25
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// ピラミッド型 Lucas-Kanade による疎なオプティカルフロー。
public struct SparseOpticalFlow: Sendable {
    public struct Config: Sendable {
        public var levels = 3
        public var halfWindow = 4
        public var iterations = 10
        /// 前後方向の整合性チェックのしきい値（ピクセル、元の解像度）。
        public var forwardBackwardThreshold: Float = 1.0
        /// 特徴点の最小のテクスチャ（構造テンソルの最小固有値）。
        public var minEigenvalue: Float = 1e-4
        public init() {}
    }

    public var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public func pyramid(_ img: GrayImage) -> [GrayImage] {
        var p = [img]
        for _ in 1..<config.levels { p.append(p[p.count - 1].downsampled()) }
        return p
    }

    /// 追跡に向いた点（Shi-Tomasi）を格子から選ぶ。
    /// - Parameter allowed: 点を置いてよいかどうか（画像座標）。地面領域かつ人物の枠の外、など。
    public func selectFeatures(in img: GrayImage, spacing: Int = 8, maxCount: Int = 120, allowed: (Int, Int) -> Bool) -> [SIMD2<Float>] {
        var cands: [(SIMD2<Float>, Float)] = []
        let r = config.halfWindow
        var y = r + 1
        while y < img.height - r - 1 {
            var x = r + 1
            while x < img.width - r - 1 {
                if allowed(x, y) {
                    let e = minEigen(img, x, y)
                    if e > config.minEigenvalue { cands.append((SIMD2(Float(x), Float(y)), e)) }
                }
                x += spacing
            }
            y += spacing
        }
        cands.sort { $0.1 > $1.1 }
        return cands.prefix(maxCount).map(\.0)
    }

    func minEigen(_ img: GrayImage, _ cx: Int, _ cy: Int) -> Float {
        var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0
        let r = config.halfWindow
        for y in (cy - r)...(cy + r) {
            for x in (cx - r)...(cx + r) {
                let ix = (img.at(x + 1, y) - img.at(x - 1, y)) * 0.5
                let iy = (img.at(x, y + 1) - img.at(x, y - 1)) * 0.5
                gxx += ix * ix
                gxy += ix * iy
                gyy += iy * iy
            }
        }
        let n = Float((2 * r + 1) * (2 * r + 1))
        gxx /= n; gxy /= n; gyy /= n
        let tr = gxx + gyy, det = gxx * gyy - gxy * gxy
        return tr / 2 - sqrt(max(0, tr * tr / 4 - det))
    }

    /// prev の点 points を next で追跡する。失敗した点は nil。
    public func track(points: [SIMD2<Float>], prev: [GrayImage], next: [GrayImage]) -> [SIMD2<Float>?] {
        points.map { p in
            guard let q = trackPoint(p, from: prev, to: next),
                  let back = trackPoint(q, from: next, to: prev),
                  simd_length_f(back - p) < config.forwardBackwardThreshold
            else { return nil }
            return q
        }
    }

    func trackPoint(_ p: SIMD2<Float>, from a: [GrayImage], to b: [GrayImage]) -> SIMD2<Float>? {
        var guess = SIMD2<Float>(0, 0)
        let r = config.halfWindow
        for level in stride(from: min(a.count, b.count) - 1, through: 0, by: -1) {
            let ia = a[level], ib = b[level]
            let scale = Float(1 << level)
            let pl = p / scale
            // 構造テンソル（テンプレート側）
            var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0
            var ixs = [Float](), iys = [Float](), ts = [Float]()
            ixs.reserveCapacity((2 * r + 1) * (2 * r + 1))
            iys.reserveCapacity(ixs.capacity)
            ts.reserveCapacity(ixs.capacity)
            for dy in -r...r {
                for dx in -r...r {
                    let x = pl.x + Float(dx), y = pl.y + Float(dy)
                    let ix = (ia.sample(x + 1, y) - ia.sample(x - 1, y)) * 0.5
                    let iy = (ia.sample(x, y + 1) - ia.sample(x, y - 1)) * 0.5
                    ixs.append(ix)
                    iys.append(iy)
                    ts.append(ia.sample(x, y))
                    gxx += ix * ix
                    gxy += ix * iy
                    gyy += iy * iy
                }
            }
            let det = gxx * gyy - gxy * gxy
            guard det > 1e-9 else { return nil }
            var d = guess
            for _ in 0..<config.iterations {
                var bx: Float = 0, by: Float = 0
                var k = 0
                for dy in -r...r {
                    for dx in -r...r {
                        let x = pl.x + Float(dx) + d.x, y = pl.y + Float(dy) + d.y
                        let diff = ts[k] - ib.sample(x, y)
                        bx += diff * ixs[k]
                        by += diff * iys[k]
                        k += 1
                    }
                }
                let step = SIMD2<Float>((gyy * bx - gxy * by) / det, (gxx * by - gxy * bx) / det)
                d += step
                if simd_length_f(step) < 0.01 { break }
            }
            guess = level > 0 ? d * 2 : d
        }
        let q = p + guess
        let w = Float(a[0].width), h = Float(a[0].height)
        guard q.x >= 0, q.y >= 0, q.x < w, q.y < h, guess.x.isFinite, guess.y.isFinite else { return nil }
        return q
    }
}

@inline(__always)
func simd_length_f(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
