import Foundation
import Testing
@testable import RouteDanceCore

// Fixtures/MoGe/ は Tools/ModelConversion/gen_postprocess_fixtures.py が書き出す。
// 期待値は MoGe 公式の recover_focal_shift（PyTorch + scipy）で計算したもの。

private struct FixtureFile: Decodable {
    struct Probe: Decodable { let x: Int; let y: Int; let depth: Double? }
    struct Estimate: Decodable {
        let focal: Double; let shift: Double; let fov_x_deg: Double
        let valid_count: Int; let probes: [Probe]
    }
    struct Known: Decodable {
        let fov_x_deg: Double; let shift: Double
        let valid_count: Int; let probes: [Probe]
    }
    struct Case: Decodable {
        let name: String; let bin: String
        let width: Int; let height: Int; let metric_scale: Double
        let estimate: Estimate; let known_fov: Known
    }
    let cases: [Case]
}

private struct LoadedCase {
    let spec: FixtureFile.Case
    var raw: MoGeRawOutput
}

private func loadCases() throws -> [LoadedCase] {
    let base = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("MoGe")
    let json = try Data(contentsOf: base.appendingPathComponent("cases.json"))
    let file = try JSONDecoder().decode(FixtureFile.self, from: json)
    return try file.cases.map { c in
        let data = try Data(contentsOf: base.appendingPathComponent(c.bin))
        let n = c.width * c.height
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(floats.count == 4 * n)
        let raw = MoGeRawOutput(
            points: Array(floats[0..<(3 * n)]), mask: Array(floats[(3 * n)..<(4 * n)]),
            metricScale: Float(c.metric_scale), width: c.width, height: c.height
        )
        return LoadedCase(spec: c, raw: raw)
    }
}

private func relErr(_ a: Float, _ b: Double) -> Double { abs(Double(a) - b) / max(abs(b), 1e-9) }

@Suite("MoGePostprocess")
struct MoGePostprocessTests {
    @Test("focal/shiftを同時推定: PyTorch版 recover_focal_shift と一致")
    func estimateMatchesReference() throws {
        for c in try loadCases() {
            let r = try MoGePostprocess.recover(c.raw, focal: .estimate)
            #expect(relErr(r.focal, c.spec.estimate.focal) < 2e-3, "\(c.spec.name) focal \(r.focal) vs \(c.spec.estimate.focal)")
            #expect(abs(Double(r.shift) - c.spec.estimate.shift) < 2e-3, "\(c.spec.name) shift \(r.shift) vs \(c.spec.estimate.shift)")
            let fovDeg = Double(r.intrinsics.horizontalFOV) * 180 / .pi
            #expect(abs(fovDeg - c.spec.estimate.fov_x_deg) < 0.1, "\(c.spec.name) fov \(fovDeg) vs \(c.spec.estimate.fov_x_deg)")
            #expect(r.valid.filter { $0 }.count == c.spec.estimate.valid_count)
            #expect(r.intrinsics.cx == 0.5 && r.intrinsics.cy == 0.5)
            // 正方画素: fx * W == fy * H
            #expect(abs(r.intrinsics.fx * Float(r.width) - r.intrinsics.fy * Float(r.height)) < 1e-3)
            for p in c.spec.estimate.probes {
                let got = r.depthAt(x: p.x, y: p.y)
                if let expected = p.depth {
                    let g = try #require(got)
                    #expect(relErr(g, expected) < 5e-3, "\(c.spec.name) depth(\(p.x),\(p.y)) \(g) vs \(expected)")
                } else {
                    #expect(got == nil)
                }
            }
        }
    }

    @Test("水平画角が既知: shiftのみ推定して一致")
    func knownFOVMatchesReference() throws {
        for c in try loadCases() {
            let k = c.spec.known_fov
            let r = try MoGePostprocess.recover(c.raw, focal: .knownHorizontalFOV(Float(k.fov_x_deg * .pi / 180)))
            #expect(abs(Double(r.shift) - k.shift) < 2e-3, "\(c.spec.name) shift \(r.shift) vs \(k.shift)")
            let fovDeg = Double(r.intrinsics.horizontalFOV) * 180 / .pi
            #expect(abs(fovDeg - k.fov_x_deg) < 1e-3)
            for p in k.probes {
                if let expected = p.depth {
                    let g = try #require(r.depthAt(x: p.x, y: p.y))
                    #expect(relErr(g, expected) < 5e-3, "\(c.spec.name) depth(\(p.x),\(p.y)) \(g) vs \(expected)")
                }
            }
        }
    }

    @Test("内部パラメータ既知(knownIntrinsics)は水平画角既知と同じ結果")
    func knownIntrinsicsEqualsKnownFOV() throws {
        let c = try #require(try loadCases().first)
        let fov = Float(65.0 * .pi / 180)
        let aspect = Float(c.raw.width) / Float(c.raw.height)
        let k = MoGeIntrinsics(horizontalFOV: fov, aspectRatio: aspect)
        let a = try MoGePostprocess.recover(c.raw, focal: .knownHorizontalFOV(fov))
        let b = try MoGePostprocess.recover(c.raw, focal: .knownIntrinsics(k))
        #expect(abs(a.shift - b.shift) < 1e-4)
        #expect(abs(a.focal - b.focal) < 1e-4)
    }

    @Test("合成データ: 既知のfocal/shiftを厳密に復元する")
    func syntheticRoundTrip() throws {
        let w = 64, h = 48
        let aspect = Double(w) / Double(h)
        let span = (1 + aspect * aspect).squareRoot()
        let trueFocal = 1.7, trueShift = 0.35, scale: Float = 3.0
        var points = [Float](repeating: 0, count: 3 * w * h)
        let mask = [Float](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let u = (-1 + 2 * Double(x) / Double(w - 1)) * aspect / span * Double(w - 1) / Double(w)
                let v = (-1 + 2 * Double(y) / Double(h - 1)) / span * Double(h - 1) / Double(h)
                // 平面と球面の混合で奥行きを変化させる（z_true > 0）
                let zTrue = 2.0 + 0.8 * sin(Double(x) * 0.15) + 0.5 * cos(Double(y) * 0.2) + 1.2 * Double(y) / Double(h)
                let z = zTrue - trueShift
                let p = y * w + x
                points[p] = Float(u * zTrue / trueFocal)
                points[w * h + p] = Float(v * zTrue / trueFocal)
                points[2 * w * h + p] = Float(z)
            }
        }
        let r = try MoGePostprocess.recover(points: points, mask: mask, metricScale: scale, width: w, height: h)
        #expect(abs(Double(r.focal) - trueFocal) < 1e-3)
        #expect(abs(Double(r.shift) - trueShift) < 1e-3)
        #expect(r.residualRMS < 1e-4)
        let p0 = 10 * w + 20
        #expect(abs(r.depth[p0] - Float((points[2 * w * h + p0] + Float(trueShift)) * scale)) < 1e-2)
    }

    @Test("マスクで除外した画素はNaN、全画素無効ならエラー")
    func maskHandling() throws {
        var c = try #require(try loadCases().first)
        let n = c.raw.width * c.raw.height
        for i in 0..<(n / 2) { c.raw.mask[i] = 0 }
        let r = try MoGePostprocess.recover(c.raw)
        #expect(r.depth[0].isNaN && !r.valid[0])
        #expect(r.depth[n - 1].isFinite && r.valid[n - 1])

        c.raw.mask = [Float](repeating: 0, count: n)
        #expect(throws: MoGePostprocessError.tooFewValidPoints) { try MoGePostprocess.recover(c.raw) }
    }

    @Test("形状が不正ならエラー")
    func invalidShape() {
        #expect(throws: MoGePostprocessError.invalidShape) {
            try MoGePostprocess.recover(points: [0, 1], mask: [1], metricScale: 1, width: 4, height: 4)
        }
    }

    @Test("repack: ストライド付きバッファを連続配列に詰め直す")
    func repackStrided() {
        // shape [1, 2, 2, 3]、行方向に1要素のパディング（行ストライド4）
        let strides = [16, 8, 4, 1]
        var src = [Float](repeating: -1, count: 16)
        var expected = [Float]()
        var v: Float = 0
        for c in 0..<2 { for y in 0..<2 { for x in 0..<3 {
            src[c * strides[1] + y * strides[2] + x] = v; expected.append(v); v += 1
        } } }
        let packed = src.withUnsafeBufferPointer { MoGeRawOutput.repack($0.baseAddress!, shape: [1, 2, 2, 3], strides: strides) }
        #expect(packed == expected)
        let dense = expected.withUnsafeBufferPointer { MoGeRawOutput.repack($0.baseAddress!, shape: [1, 2, 2, 3], strides: [12, 6, 3, 1]) }
        #expect(dense == expected)
    }

    @Test("内部パラメータの投影と逆投影が往復する")
    func projectUnproject() throws {
        let k = MoGeIntrinsics(horizontalFOV: 1.0, aspectRatio: 0.75)
        let p = k.unproject(u: 100, v: 300, depth: 5, width: 378, height: 504)
        let uv = try #require(k.project(p, width: 378, height: 504))
        #expect(abs(uv.x - 100) < 1e-2 && abs(uv.y - 300) < 1e-2)
        #expect(k.project(SIMD3<Float>(0, 0, -1), width: 10, height: 10) == nil)
    }
}
