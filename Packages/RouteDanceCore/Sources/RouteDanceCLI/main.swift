import AVFoundation
import CoreImage
import Foundation
import RouteDanceCore
import RouteDancePerception

// 使い方:
//   swift run -c release routedance-cli <画像または動画> [--models <Modelsディレクトリ>] [--frames N]
// 画像なら1枚、動画なら先頭から N フレーム（既定 90）を処理して、各段の結果と時間を表示する。

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: routedance-cli <image|video> [--models DIR] [--frames N]")
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
@Sendable func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let maxFrames = Int(option("--frames") ?? "90") ?? 90

@Sendable func loadDepth(portrait: Bool) throws -> DepthEstimator {
    let modelsDir = URL(fileURLWithPath: option("--models") ?? "../../Models")
    let name = portrait ? "MoGe2S" : "MoGe2S_landscape"
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("routedance-\(name).mlmodelc")
    if FileManager.default.fileExists(atPath: cache.path) {
        return try DepthEstimator(url: cache)
    }
    let compiled = try MLModelCompile.compile(modelsDir.appendingPathComponent("\(name).mlpackage"))
    try? FileManager.default.removeItem(at: cache)
    try FileManager.default.copyItem(at: compiled, to: cache)
    return try DepthEstimator(url: cache)
}

func describe(_ f: ProcessedFrame) {
    let s = f.snapshot
    let g = s.geometry
    print(String(format: "t=%.2fs  速度 %.2f m/s  地面: h=%.2fm pitch=%.1f° roll=%.1f° (inlier %@)  画角 %.1f°",
                 s.timestamp, s.userSpeed, g.ground.height, g.ground.pitch * 180 / .pi, g.ground.roll * 180 / .pi,
                 s.groundInlierRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "-", g.camera.horizontalFOV * 180 / .pi))
    print(String(format: "  時間[ms] 検出 %.1f / 深度 %.1f (age %.2fs) / フロー %.1f (%d点, odo inlier %d) / core %.1f / 計 %.1f",
                 f.stats.detectionMilliseconds, f.stats.depthMilliseconds, f.stats.depthAge, f.stats.flowMilliseconds,
                 f.stats.flowPoints, s.odometryInliers, f.stats.coreMilliseconds, f.stats.totalMilliseconds))
    let coreT = s.timings.sorted { $0.key < $1.key }.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
    print("  core内訳[ms] \(coreT)")
    for p in s.persons {
        print(String(format: "  人物 conf=%.2f 位置(%.2f, %.2f) 距離 %.2fm ±%.2f [%@]", p.detection.confidence, p.position.x, p.position.y,
                     p.position.length, p.rangeVariance.squareRoot(), p.sources.map(\.rawValue).sorted().joined(separator: ",")))
    }
    for t in s.tracks {
        print(String(format: "  track#%d %@ 位置(%.2f, %.2f) 速度(%.2f, %.2f)", t.id, t.state.rawValue, t.position.x, t.position.y, t.velocity.x, t.velocity.y))
    }
    if let plan = s.plan {
        let b = plan.best
        print(String(format: "  計画: P_safe=%.3f 減速=%@ 矢印 %.1f° 長さ %.2fm ゴール(%.1f, %.1f) 最小速度比 %.2f",
                     b.pSafe, b.requiresSlowdown ? "あり" : "なし", b.lookaheadHeading * 180 / .pi, b.arcLength.last ?? 0,
                     plan.goal.x, plan.goal.y, b.speedRatio.min() ?? 1))
    }
}

let processor = FrameProcessor(loadDepth: { try loadDepth(portrait: $0) })

let ext = inputURL.pathExtension.lowercased()
if ["jpg", "jpeg", "png", "heic"].contains(ext) {
    guard let img = CIImage(contentsOf: inputURL, options: [.applyOrientationProperty: true]) else {
        print("画像を読めません")
        exit(1)
    }
    // 深度は非同期なので、同じ画像を数フレーム流して結果が揃うのを待つ。
    for i in 0..<12 {
        let f = await processor.process(InputFrame(image: img, timestamp: Double(i) * 0.1))
        if i == 11 || (f.stats.depthAvailable && i >= 3) {
            describe(f)
            break
        }
        try await Task.sleep(for: .milliseconds(120))
    }
} else {
    let reader = try VideoFrameReader(url: inputURL)
    var n = 0
    var sumMs = 0.0
    while n < maxFrames, let frame = try reader.next() {
        let f = await processor.process(frame)
        sumMs += f.stats.totalMilliseconds
        if n % 15 == 0 { describe(f) }
        n += 1
    }
    print(String(format: "%d フレーム、平均 %.1f ms/frame", n, sumMs / Double(max(n, 1))))
}
if let e = await processor.depthStatus { print(e) }
