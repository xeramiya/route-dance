import Foundation
import simd

// MoGe-2 (Core ML) の生出力から、メトリック深度と内部パラメータを復元する後処理。
//
// Core MLモデルは「アフィン不変の点群」(x, y, z) を出力する。この点群は真のカメラ座標系の点群に対して
// z方向のシフトと焦点距離が未確定なので、次の最小二乗問題を解いて復元する（MoGe公式の recover_focal_shift と同じ）。
//
//     min_{focal, shift} Σ_i || focal * xy_i / (z_i + shift) - uv_i ||²
//
// uv は「画像対角を1に正規化した視野面座標」で、focal は画像対角の半分に対する相対焦点距離。
// focal を既知にした場合は shift だけを解く。得られた (z + shift) にメトリックスケールを掛けるとメートル単位のz深度になる。
//
// 座標系: OpenCV系（カメラ座標でx右・y下・z前）。画像座標は左上原点、行優先。

// MARK: - 公開型

/// 画像サイズで正規化した内部パラメータ。
///
/// `fx, cx` は画像幅、`fy, cy` は画像高さで割った値（ピクセル値 = `fx * width` など）。
/// MoGeは主点を画像中心に固定し、正方画素を仮定するため `cx = cy = 0.5`、`fx * width == fy * height` になる。
public struct MoGeIntrinsics: Sendable, Equatable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float

    public init(fx: Float, fy: Float, cx: Float = 0.5, cy: Float = 0.5) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// 指定した画像サイズでのピクセル単位の内部パラメータ行列 K（simdは列優先）。
    public func matrix(width: Int, height: Int) -> simd_float3x3 {
        let w = Float(width)
        let h = Float(height)
        return simd_float3x3(columns: (
            SIMD3<Float>(fx * w, 0, 0),
            SIMD3<Float>(0, fy * h, 0),
            SIMD3<Float>(cx * w, cy * h, 1)
        ))
    }

    /// 水平画角（ラジアン）。
    public var horizontalFOV: Float { 2 * atan(0.5 / fx) }
    /// 垂直画角（ラジアン）。
    public var verticalFOV: Float { 2 * atan(0.5 / fy) }

    /// ピクセル座標 (u, v)（左上原点、画素中心が整数+0.5ではなく整数座標）とz深度からカメラ座標の点を求める。
    public func unproject(u: Float, v: Float, depth: Float, width: Int, height: Int) -> SIMD3<Float> {
        let x = (u / Float(width) - cx) / fx * depth
        let y = (v / Float(height) - cy) / fy * depth
        return SIMD3<Float>(x, y, depth)
    }

    /// カメラ座標の点をピクセル座標へ投影する。zが0以下なら nil。
    public func project(_ p: SIMD3<Float>, width: Int, height: Int) -> SIMD2<Float>? {
        guard p.z > 0 else { return nil }
        return SIMD2<Float>(
            (fx * p.x / p.z + cx) * Float(width),
            (fy * p.y / p.z + cy) * Float(height)
        )
    }

    /// 水平画角（ラジアン）と画像アスペクト比 (width / height) から内部パラメータを作る。主点は画像中心。
    public init(horizontalFOV: Float, aspectRatio: Float) {
        let fx = 0.5 / tan(horizontalFOV / 2)
        self.init(fx: fx, fy: fx * aspectRatio)
    }
}

/// 焦点距離の扱い。
public enum MoGeFocalMode: Sendable, Equatable {
    /// 点群から焦点距離とシフトを同時に推定する（動画で内部パラメータ不明のとき）。
    case estimate
    /// 水平画角（ラジアン）が既知。シフトのみ推定する。
    case knownHorizontalFOV(Float)
    /// 内部パラメータが既知（`fx` のみ使う。主点は画像中心、正方画素を仮定）。シフトのみ推定する。
    ///
    /// モデル入力が元画像の中央クロップ／リサイズである場合は、呼び出し側でクロップ後の画像に対する値へ換算して渡すこと。
    case knownIntrinsics(MoGeIntrinsics)
}

/// Core MLモデルの生出力。
///
/// - `points`: CHWの連続メモリ。長さ `3 * height * width`、チャンネル順は x, y, z（`points[c * H * W + y * W + x]`）。
/// - `mask`: 有効画素の確率（0...1）。長さ `height * width`。
/// - `metricScale`: `metric_scale` 出力（スカラー）。
///
/// `MLMultiArray` から取り出すときは `strides` が連続でない場合があるため、`MoGeRawOutput.repack` で詰め直すこと。
public struct MoGeRawOutput: Sendable {
    public var points: [Float]
    public var mask: [Float]
    public var metricScale: Float
    public var width: Int
    public var height: Int

    public init(points: [Float], mask: [Float], metricScale: Float, width: Int, height: Int) {
        self.points = points
        self.mask = mask
        self.metricScale = metricScale
        self.width = width
        self.height = height
    }

    /// ストライド付きバッファ（`MLMultiArray` の `dataPointer` と `strides`）を、連続した行優先の `[Float]` に詰め直す。
    ///
    /// - Parameters:
    ///   - source: 先頭ポインタ。
    ///   - shape: 形状。例: points は `[1, 3, H, W]`、mask は `[1, 1, H, W]`。
    ///   - strides: 要素単位のストライド（`MLMultiArray.strides` をそのまま `Int` にしたもの）。
    public static func repack(_ source: UnsafePointer<Float>, shape: [Int], strides: [Int]) -> [Float] {
        precondition(shape.count == strides.count)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        // 連続している場合は一括コピー
        var expected = 1
        var contiguous = true
        for axis in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[axis] != 1 && strides[axis] != expected { contiguous = false }
            expected *= shape[axis]
        }
        if contiguous {
            out.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: source, count: count)
            }
            return out
        }
        var index = [Int](repeating: 0, count: shape.count)
        for i in 0..<count {
            var offset = 0
            for axis in 0..<shape.count { offset += index[axis] * strides[axis] }
            out[i] = source[offset]
            var axis = shape.count - 1
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < shape[axis] { break }
                index[axis] = 0
                axis -= 1
            }
        }
        return out
    }
}

/// 後処理の結果。
public struct MoGeDepthResult: Sendable {
    public var width: Int
    public var height: Int
    /// メートル単位のz深度（カメラ光軸方向の距離、行優先、長さ `width * height`）。無効画素は `.nan`。
    public var depth: [Float]
    /// 有効画素（マスク確率 > 0.5 かつ深度 > 0）。
    public var valid: [Bool]
    /// 正規化内部パラメータ（`knownIntrinsics` を渡した場合も、使われたのは `fx` のみで主点は画像中心）。
    public var intrinsics: MoGeIntrinsics
    /// 復元したzシフト（メトリックスケール適用前の単位）。
    public var shift: Float
    /// 画像対角の半分に対する相対焦点距離（MoGe公式の `focal`）。
    public var focal: Float
    /// 適用したメトリックスケール。
    public var metricScale: Float
    /// 最小二乗の最終残差の二乗平均平方根（正規化uv単位）。大きいほど点群が射影モデルに合っていない。
    public var residualRMS: Float

    public func depthAt(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let d = depth[y * width + x]
        return d.isNaN ? nil : d
    }
}

public enum MoGePostprocessError: Error, Equatable {
    case invalidShape
    case tooFewValidPoints
    case solverFailed
}

// MARK: - 実装

public enum MoGePostprocess {
    /// 最小二乗に使うダウンサンプル後の格子サイズ（MoGe公式の `downsample_size=(64, 64)` と同じ）。
    public static let solverGridSize = 64
    /// マスク確率の閾値。
    public static let maskThreshold: Float = 0.5

    /// 生出力からメトリック深度と内部パラメータを復元する。
    public static func recover(_ raw: MoGeRawOutput, focal mode: MoGeFocalMode = .estimate) throws -> MoGeDepthResult {
        try recover(
            points: raw.points, mask: raw.mask, metricScale: raw.metricScale,
            width: raw.width, height: raw.height, focal: mode
        )
    }

    public static func recover(
        points: [Float], mask: [Float], metricScale: Float,
        width: Int, height: Int, focal mode: MoGeFocalMode = .estimate
    ) throws -> MoGeDepthResult {
        let pixelCount = width * height
        guard width > 1, height > 1, points.count == 3 * pixelCount, mask.count == pixelCount else {
            throw MoGePostprocessError.invalidShape
        }

        let aspect = Double(width) / Double(height)
        let span = (1 + aspect * aspect).squareRoot()

        // --- 最小二乗用に 64x64 へ nearest ダウンサンプル（PyTorchの F.interpolate(mode="nearest") と同じ添字） ---
        let gridW = solverGridSize
        let gridH = solverGridSize
        let scaleX = Float(width) / Float(gridW)
        let scaleY = Float(height) / Float(gridH)
        let uvStepX = aspect / span * Double(width - 1) / Double(width)
        let uvStepY = 1 / span * Double(height - 1) / Double(height)

        var sx = [Double](), sy = [Double](), sz = [Double]()
        var su = [Double](), sv = [Double]()
        sx.reserveCapacity(gridW * gridH)
        sy.reserveCapacity(gridW * gridH)
        sz.reserveCapacity(gridW * gridH)
        su.reserveCapacity(gridW * gridH)
        sv.reserveCapacity(gridW * gridH)

        for gy in 0..<gridH {
            let py = min(Int((Float(gy) * scaleY).rounded(.down)), height - 1)
            let v = (-1 + 2 * Double(py) / Double(height - 1)) * uvStepY
            for gx in 0..<gridW {
                let px = min(Int((Float(gx) * scaleX).rounded(.down)), width - 1)
                let p = py * width + px
                guard mask[p] > maskThreshold else { continue }
                let u = (-1 + 2 * Double(px) / Double(width - 1)) * uvStepX
                sx.append(Double(points[p]))
                sy.append(Double(points[pixelCount + p]))
                sz.append(Double(points[2 * pixelCount + p]))
                su.append(u)
                sv.append(v)
            }
        }
        guard sx.count >= 2 else { throw MoGePostprocessError.tooFewValidPoints }

        // --- focal / shift の推定 ---
        let fixedFocal: Double?
        switch mode {
        case .estimate:
            fixedFocal = nil
        case .knownHorizontalFOV(let fov):
            fixedFocal = aspect / span / tan(Double(fov) / 2)
        case .knownIntrinsics(let k):
            // fx_norm = focal / 2 * span / aspect  ->  focal = 2 * aspect * fx_norm / span
            fixedFocal = 2 * aspect * Double(k.fx) / span
        }
        if let f = fixedFocal, !(f > 0 && f.isFinite) { throw MoGePostprocessError.solverFailed }

        let problem = ShiftProblem(x: sx, y: sy, z: sz, u: su, v: sv, fixedFocal: fixedFocal)
        let solution = try problem.solve()
        let focal = solution.focal
        let shift = solution.shift

        // --- 深度マップ（メトリック） ---
        var depth = [Float](repeating: .nan, count: pixelCount)
        var valid = [Bool](repeating: false, count: pixelCount)
        let shiftF = Float(shift)
        let zOffset = 2 * pixelCount
        for p in 0..<pixelCount where mask[p] > maskThreshold {
            let z = points[zOffset + p] + shiftF
            if z > 0 {
                depth[p] = z * metricScale
                valid[p] = true
            }
        }

        let fy = Float(focal / 2 * span)
        let fx = Float(focal / 2 * span / aspect)
        return MoGeDepthResult(
            width: width, height: height, depth: depth, valid: valid,
            intrinsics: MoGeIntrinsics(fx: fx, fy: fy),
            shift: shiftF, focal: Float(focal), metricScale: metricScale,
            residualRMS: Float(solution.rms)
        )
    }
}

// MARK: - 1次元の最小二乗（shift）

/// `min_shift Σ || f * xy / (z + shift) - uv ||²` を解く。focal が未知なら各 shift で閉形式の最適 f を使う（変数削減）。
/// 初期値 shift = 0、Levenberg-Marquardt（scipyの `least_squares(method="lm")` と同じ問題設定。収束判定はより厳しい）。
struct ShiftProblem {
    let x: [Double], y: [Double], z: [Double], u: [Double], v: [Double]
    let fixedFocal: Double?

    init(x: [Double], y: [Double], z: [Double], u: [Double], v: [Double], fixedFocal: Double?) {
        self.x = x; self.y = y; self.z = z; self.u = u; self.v = v
        self.fixedFocal = fixedFocal
    }

    /// 残差ベクトルの二乗和と、そのときの focal。`z + shift <= 0` の点があれば nil。
    private func cost(shift: Double) -> (cost: Double, focal: Double)? {
        var sumPU = 0.0, sumPP = 0.0
        let n = z.count
        var minDen = Double.infinity
        for i in 0..<n {
            let den = z[i] + shift
            minDen = min(minDen, den)
        }
        guard minDen > 1e-9 else { return nil }
        for i in 0..<n {
            let inv = 1 / (z[i] + shift)
            let px = x[i] * inv, py = y[i] * inv
            sumPU += px * u[i] + py * v[i]
            sumPP += px * px + py * py
        }
        let f = fixedFocal ?? (sumPP > 0 ? sumPU / sumPP : 1)
        var c = 0.0
        for i in 0..<n {
            let inv = 1 / (z[i] + shift)
            let rx = f * x[i] * inv - u[i]
            let ry = f * y[i] * inv - v[i]
            c += rx * rx + ry * ry
        }
        return (c, f)
    }

    /// 残差ベクトル r(shift)（長さ2n）。focal は `cost` と同じ規則。
    private func residuals(shift: Double, focal f: Double, into r: inout [Double]) {
        for i in 0..<z.count {
            let inv = 1 / (z[i] + shift)
            r[2 * i] = f * x[i] * inv - u[i]
            r[2 * i + 1] = f * y[i] * inv - v[i]
        }
    }

    struct Solution { var shift: Double; var focal: Double; var rms: Double }

    func solve() throws -> Solution {
        var shift = 0.0
        // z は exp 再マップ済みで正のはずだが、念のため初期値が不正なら z の最小値で下駄を履かせる
        if cost(shift: shift) == nil {
            shift = -(z.min() ?? 0) + 1e-3
        }
        guard let start = cost(shift: shift) else { throw MoGePostprocessError.solverFailed }
        return solveFrom(shift: shift, current: start)
    }

    private func solveFrom(shift startShift: Double, current startCost: (cost: Double, focal: Double)) -> Solution {
        var shift = startShift
        var current = startCost
        var lambda = 1e-3
        let n2 = 2 * z.count
        var r0 = [Double](repeating: 0, count: n2)
        var r1 = [Double](repeating: 0, count: n2)

        for _ in 0..<200 {
            // ヤコビアン（変数削減した残差の中心差分）。focalは各shiftで最適化し直す。
            let h = 1e-6 * max(1, abs(shift))
            guard let cp = cost(shift: shift + h), let cm = cost(shift: shift - h) else {
                // 中心差分が取れない（z+shift が0付近）。lambda を増やして続行する代わりに終了
                break
            }
            residuals(shift: shift, focal: current.focal, into: &r0)
            var jr = 0.0, jj = 0.0
            residuals(shift: shift + h, focal: cp.focal, into: &r1)
            var r2 = [Double](repeating: 0, count: n2)
            residuals(shift: shift - h, focal: cm.focal, into: &r2)
            for k in 0..<n2 {
                let j = (r1[k] - r2[k]) / (2 * h)
                jr += j * r0[k]
                jj += j * j
            }
            guard jj > 0, jj.isFinite else { break }

            var improved = false
            for _ in 0..<30 {
                let step = -jr / (jj * (1 + lambda))
                let trial = shift + step
                if let t = cost(shift: trial), t.cost < current.cost {
                    let converged = abs(step) <= 1e-10 * (1 + abs(shift)) || (current.cost - t.cost) <= 1e-14 * current.cost
                    shift = trial
                    current = t
                    lambda = max(lambda / 3, 1e-12)
                    improved = true
                    if converged { return finish(shift: shift, current: current) }
                    break
                }
                lambda *= 4
            }
            if !improved { break }
        }
        return finish(shift: shift, current: current)
    }

    private func finish(shift: Double, current: (cost: Double, focal: Double)) -> Solution {
        Solution(shift: shift, focal: current.focal, rms: (current.cost / Double(2 * z.count)).squareRoot())
    }
}
