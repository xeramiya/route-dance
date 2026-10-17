import RouteDanceCore
import RouteDancePerception
import SwiftUI

/// 地面座標 → ビュー座標。カメラの後ろ（z ≤ 近平面）だけを除き、画面外の点もそのまま返す（Canvas がクリップする）。
/// 線分は近平面でクリップするので、カメラ直下の原点から伸びる線も画面下端から自然に出てくる。
struct GroundProjector {
    let geometry: CameraGeometry
    let fit: VideoFit
    let viewSize: CGSize
    /// 近平面（カメラ座標の z、m）。
    var near = 0.15

    private func cameraPoint(_ p: Vec2, _ h: Double) -> SIMD3<Double> {
        geometry.cameraPoint(ground: p, height: h)
    }

    private func view(_ c: SIMD3<Double>) -> CGPoint? {
        guard let px = geometry.camera.project(c) else { return nil }
        return fit.view(CGPoint(x: px.x, y: px.y))
    }

    /// 点。カメラの後ろなら nil。
    func point(_ p: Vec2, height: Double = 0) -> CGPoint? {
        let c = cameraPoint(p, height)
        guard c.z > near else { return nil }
        return view(c)
    }

    /// 近平面でクリップした線分。両端ともカメラの後ろなら nil。
    func segment(_ a: Vec2, _ b: Vec2, height: Double = 0) -> (CGPoint, CGPoint)? {
        clip(cameraPoint(a, height), cameraPoint(b, height))
    }

    private func clip(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> (CGPoint, CGPoint)? {
        var a = a, b = b
        if a.z <= near && b.z <= near { return nil }
        if a.z <= near { a += (b - a) * ((near - a.z) / (b.z - a.z)) }
        if b.z <= near { b += (a - b) * ((near - b.z) / (a.z - b.z)) }
        guard let pa = view(a), let pb = view(b) else { return nil }
        return (pa, pb)
    }

    /// 折れ線。カメラの後ろの部分は切り落とす。
    func polyline(_ pts: [Vec2], height: Double = 0) -> Path {
        var path = Path()
        var last: CGPoint?
        for i in pts.indices.dropFirst() {
            guard let (a, b) = segment(pts[i - 1], pts[i], height: height) else {
                last = nil
                continue
            }
            if last != a { path.move(to: a) }
            path.addLine(to: b)
            last = b
        }
        return path
    }

    /// 地面上の円（中心 c、半径 r）。
    func ring(center c: Vec2, radius r: Double) -> Path {
        let pts = (0...32).map { i -> Vec2 in
            let a = Double(i) / 32 * 2 * .pi
            return c + Vec2(cos(a), sin(a)) * r
        }
        return polyline(pts)
    }
}

/// 推奨経路・予測経路・ヒートマップ・検出枠・障害物を、映像に重ねて描く。
struct OverlayView: View {
    let frame: ProcessedFrame
    let debug: Bool
    let showRiskField: Bool
    let showCandidates: Bool

    /// 予測を出す距離の上限（m）。これより遠い人は点線の枠だけ。
    private let forecastRange = 15.0

    var body: some View {
        Canvas { ctx, size in
            let s = frame.snapshot
            let fit = VideoFit(imageSize: frame.image.extent.size, viewSize: size)
            let proj = GroundProjector(geometry: s.geometry, fit: fit, viewSize: size)

            if debug {
                drawObstacles(s.obstacles, ctx: ctx, proj: proj)
            }
            if debug, showRiskField, let field = s.riskField {
                drawRiskField(field, ctx: ctx, proj: proj)
            }
            if debug, showCandidates, let plan = s.plan {
                for c in plan.candidates where c.points.count > 1 {
                    ctx.stroke(proj.polyline(c.points), with: .color(safetyColor(c.pSafe).opacity(0.18)), lineWidth: 1)
                }
            }
            if debug {
                drawTrackHistory(s, ctx: ctx, proj: proj)
                drawForecasts(s, ctx: ctx, proj: proj)
                drawDetections(s, ctx: ctx, fit: fit)
                drawLostTracks(s, ctx: ctx, fit: fit)
            }
            if let plan = s.plan {
                drawPlan(plan.best, ctx: ctx, proj: proj, width: debug ? 6 : 10)
                if debug, let gp = proj.point(plan.goal) {
                    ctx.fill(Path(ellipseIn: CGRect(x: gp.x - 5, y: gp.y - 5, width: 10, height: 10)), with: .color(.blue))
                }
            }
            if debug, let hy = s.geometry.horizonY {
                let y = fit.view(CGPoint(x: 0, y: hy)).y
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.purple.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - ラベル

    /// 文字。背景の箱は付けず、細い影で縁取って読めるようにする（デバッグ時は映像が白っぽいので暗い影が効く）。
    private func drawLabel(_ ctx: GraphicsContext, _ text: String, at p: CGPoint, color: Color, size: CGFloat = 10, bold: Bool = false) {
        var c = ctx
        c.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.2))
        let resolved = c.resolve(
            Text(text).font(.system(size: size, weight: bold ? .bold : .medium, design: .monospaced)).foregroundStyle(color)
        )
        c.draw(resolved, at: p, anchor: .center)
    }

    // MARK: - 推奨経路

    /// 推奨経路: 速度比で緑 → 黄 → 赤。画面外・カメラ直下の点も繋いで描く。
    /// 経路長が実質0（＝全区間で停止を選び、進める経路が無い）ときは全体を真っ赤にして「止まれ」を示す。
    ///
    /// 始点は候補経路（`candidates`）と同じく、地面原点をそのまま投影した位置に置く（画面下端への固定はしない）。
    /// 候補と推奨で始点・傾きを揃え、経路全体が地面の投影に沿って同じように傾くようにする。
    private func drawPlan(_ plan: PlannedPath, ctx: GraphicsContext, proj: GroundProjector, width: CGFloat) {
        let pts = plan.points
        guard pts.count > 1 else { return }
        // 総経路長。減速プロファイルが全ステップ停止を選ぶと全点が原点付近に潰れ、長さがほぼ0になる。
        let totalLength = plan.arcLength.last ?? 0
        let stopped = totalLength < 0.1

        for i in 1..<pts.count {
            guard let (a, b) = proj.segment(pts[i - 1], pts[i]) else { continue }
            var seg = Path()
            seg.move(to: a)
            seg.addLine(to: b)
            // 遠いほど細く見えるよう、奥行きに応じて線幅を変える。
            let depthScale = max(0.5, 1 - pts[i].length / 20)
            let color = stopped ? Color(red: 1, green: 0, blue: 0) : speedColor(plan.speedRatio[i])
            ctx.stroke(seg, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: width * depthScale + 3, lineCap: .round))
            ctx.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: width * depthScale, lineCap: .round))
        }
        // 経路が点に潰れて線が全く見えないときのために、投影した始点に赤い停止マーカーを出す。
        if stopped {
            let anchor = proj.point(pts[0])
                ?? firstVisibleSegment(pts, proj: proj)?.0
                ?? CGPoint(x: proj.viewSize.width / 2, y: proj.viewSize.height)
            let r = CGRect(x: anchor.x - width, y: anchor.y - width, width: width * 2, height: width * 2)
            ctx.fill(Path(ellipseIn: r), with: .color(Color(red: 1, green: 0, blue: 0)))
            ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
        }
    }

    /// 経路の最初の、近平面クリップ後に描ける線分（の画面座標）を返す。始点アンカーの基準に使う。
    private func firstVisibleSegment(_ pts: [Vec2], proj: GroundProjector) -> (CGPoint, CGPoint)? {
        for i in 1..<pts.count {
            if let seg = proj.segment(pts[i - 1], pts[i]) { return seg }
        }
        return nil
    }

    // MARK: - 他歩行者の予測

    private func drawForecasts(_ s: NavigationSnapshot, ctx: GraphicsContext, proj: GroundProjector) {
        let tracks = Dictionary(s.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for f in s.forecasts {
            // tentative 以外（confirmed と lost）すべて。
            guard let track = tracks[f.id], track.state != .tentative else { continue }
            let color = trackColor(f.id)
            let lost = track.state == .lost
            let alpha = lost ? 0.6 : 1.0
            let speed = f.velocity.length

            // 予測経路: 薄いサンプルと、重み付き平均（太線）。ホライズン N まで。
            let n = min(max(f.times.filter { $0 <= f.horizon }.count, 1), f.times.count)
            for sample in f.samples where sample.count >= n {
                ctx.stroke(proj.polyline([f.position] + sample.prefix(n)), with: .color(color.opacity(0.15 * alpha)), lineWidth: 1)
            }
            let wsum = f.weights.reduce(0, +)
            if wsum > 0, !f.samples.isEmpty, f.samples.allSatisfy({ $0.count >= n }) {
                let mean = (0..<n).map { i in f.samples.indices.reduce(Vec2.zero) { $0 + f.samples[$1][i] * (f.weights[$1] / wsum) } }
                let line = proj.polyline([f.position] + mean)
                ctx.stroke(line, with: .color(.black.opacity(0.35 * alpha)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                ctx.stroke(line, with: .color(color.opacity(0.95 * alpha)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                // N 秒後の予測地点（塗りつぶした丸）と 2σ の点線の円。
                if let end = mean.last {
                    ctx.stroke(
                        proj.ring(center: end, radius: f.sigma(at: f.horizon) * 2),
                        with: .color(color.opacity(0.9 * alpha)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                    if let q = proj.point(end) {
                        let r = CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)
                        ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(alpha)))
                        ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                    }
                }
            }

            // 足元: 向きの矢印（速さに比例、1秒ぶんの移動距離）か、停止の小さな丸。
            guard let foot = proj.point(f.position) else { continue }
            if speed >= 0.3 {
                let tip = f.position + f.velocity
                if let (a, b) = proj.segment(f.position, tip) {
                    drawArrow(ctx, from: a, to: b, color: color.opacity(alpha))
                }
            } else {
                let r = CGRect(x: foot.x - 4, y: foot.y - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(0.5 * alpha)))
                ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.9 * alpha)), lineWidth: 1.5)
            }
            if f.position.length > forecastRange {
                // 遠くの人は番号だけを小さく（距離は枠の上に薄く出している）。
                ctx.draw(
                    Text("#\(f.id)").font(.system(size: 8, design: .monospaced)).foregroundStyle(color.opacity(0.6)),
                    at: CGPoint(x: foot.x, y: foot.y + 10), anchor: .center
                )
            } else {
                let text = String(format: "#%d %.1fm %.1fm/s N=%.1fs", f.id, f.position.length, speed, f.horizon)
                drawLabel(ctx, text, at: CGPoint(x: foot.x, y: foot.y + 14), color: color)
            }
        }
    }

    private func drawArrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let head = min(10, len * 0.6)
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        for sign in [-1.0, 1.0] {
            let ang = sign * 0.45
            let hx = -(ux * cos(ang) - uy * sin(ang)) * head, hy = -(ux * sin(ang) + uy * cos(ang)) * head
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x + hx, y: b.y + hy))
        }
        ctx.stroke(p, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: - 検出枠

    private func viewRect(_ d: PersonDetection, fit: VideoFit) -> CGRect {
        let a = fit.view(CGPoint(x: d.minX, y: d.minY)), b = fit.view(CGPoint(x: d.maxX, y: d.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// 位置推定できた検出は実線。位置推定できなかった検出と、遠距離（予測の対象外）は点線。
    private func drawDetections(_ s: NavigationSnapshot, ctx: GraphicsContext, fit: VideoFit) {
        var unmatched = s.detections
        for p in s.persons {
            if let i = unmatched.firstIndex(of: p.detection) { unmatched.remove(at: i) }
            let d = p.detection
            let rect = viewRect(d, fit: fit)
            let dist = p.position.length
            let far = dist > forecastRange
            let label = String(format: "%.1fm %.0f%%", dist, d.confidence * 100)
            if far {
                // 遠くの人（予測の対象外）は目立たせない: 細い点線と、影のない小さな薄い文字。
                ctx.stroke(Path(rect), with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                ctx.draw(
                    Text(String(format: "%.0fm", dist)).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.45)),
                    at: CGPoint(x: rect.midX, y: rect.minY - 6), anchor: .center
                )
            } else {
                ctx.stroke(Path(rect), with: .color(.cyan.opacity(0.9)), lineWidth: 1.5)
                drawLabel(ctx, label, at: CGPoint(x: rect.midX, y: rect.minY - 8), color: .cyan)
            }
        }
        for d in unmatched {
            let rect = viewRect(d, fit: fit)
            ctx.stroke(Path(rect), with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
    }

    /// 見失い中のトラック: 外挿位置から推定した枠を、トラック色の半透明の点線で。
    private func drawLostTracks(_ s: NavigationSnapshot, ctx: GraphicsContext, fit: VideoFit) {
        for t in s.tracks where t.state == .lost {
            guard let box = t.predictedBox else { continue }
            let rect = viewRect(box, fit: fit)
            let color = trackColor(t.id)
            ctx.stroke(Path(rect), with: .color(color.opacity(0.65)), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            drawLabel(
                ctx, String(format: "#%d 見失い %.1fs", t.id, t.timeSinceUpdate),
                at: CGPoint(x: rect.midX, y: rect.minY - 8), color: color.opacity(0.9)
            )
        }
    }

    private func drawTrackHistory(_ s: NavigationSnapshot, ctx: GraphicsContext, proj: GroundProjector) {
        for t in s.tracks where t.state != .tentative {
            ctx.stroke(
                proj.polyline(t.history.map(\.p)),
                with: .color(trackColor(t.id).opacity(t.state == .lost ? 0.3 : 0.9)), lineWidth: 2
            )
        }
    }

    // MARK: - 障害物

    private struct WallGroup {
        var bins: [ObstacleMap.Bin] = []
        var minDistance: Double { bins.compactMap(\.distance).min() ?? .infinity }
    }

    /// 方位ビンごとの最短距離を、隣り合って距離差が 0.5m 以内のものを繋いで1枚の壁にする。
    private func wallGroups(_ bins: [ObstacleMap.Bin], maxDistance: Double) -> [WallGroup] {
        var groups: [WallGroup] = []
        var current = WallGroup()
        for b in bins.sorted(by: { $0.headingMin < $1.headingMin }) {
            guard let d = b.distance, d <= maxDistance else {
                if !current.bins.isEmpty { groups.append(current) }
                current = WallGroup()
                continue
            }
            if let last = current.bins.last, let ld = last.distance,
               abs(d - ld) <= 0.5, b.headingMin - last.headingMax < 0.02 {
                current.bins.append(b)
            } else {
                if !current.bins.isEmpty { groups.append(current) }
                current = WallGroup(bins: [b])
            }
        }
        if !current.bins.isEmpty { groups.append(current) }
        return groups
    }

    private func obstacleColor(_ d: Double) -> Color {
        if d <= 2 { return Color(red: 1, green: 0.15, blue: 0.1) }
        if d <= 5 { return Color(red: 1, green: 0.6, blue: 0.1) }
        return Color(white: 0.75)
    }

    private func drawObstacles(_ map: ObstacleMap, ctx: GraphicsContext, proj: GroundProjector) {
        let wallHeight = 1.5
        for g in wallGroups(map.bins, maxDistance: 8) {
            let dmin = g.minDistance
            let color = obstacleColor(dmin)
            let strength = dmin <= 5 ? 1.0 : 0.45
            // 各ビンの手前の縁（地面と高さ wallHeight）と、奥行き 0.4m の地面の帯。
            var bottom: [Vec2] = [], top: [CGPoint] = [], bottomView: [CGPoint] = []
            var band: [Vec2] = []
            var ok = true
            for b in g.bins {
                guard let d = b.distance else { continue }
                for h in [b.headingMin, b.headingMax] {
                    let p = Vec2.fromHeading(h, length: d)
                    guard let pb = proj.point(p), let pt = proj.point(p, height: wallHeight) else { ok = false; break }
                    bottom.append(p)
                    bottomView.append(pb)
                    top.append(pt)
                    band.append(Vec2.fromHeading(h, length: d + 0.4))
                }
            }
            guard ok, bottom.count >= 2 else { continue }

            // 地面の帯。
            let bandPts = bottom + band.reversed()
            let bandView = bandPts.compactMap { proj.point($0) }
            if bandView.count == bandPts.count {
                var bp = Path()
                bp.addLines(bandView)
                bp.closeSubpath()
                ctx.fill(bp, with: .color(color.opacity(0.3 * strength)))
            }

            // 壁の面。
            var wall = Path()
            wall.addLines(bottomView + top.reversed())
            wall.closeSubpath()
            ctx.fill(wall, with: .color(color.opacity(0.14 * strength)))
            var layerCtx = ctx
            layerCtx.drawLayer { layer in
                layer.clip(to: wall)
                let r = wall.boundingRect
                var hatch = Path()
                let spacing: CGFloat = 9
                var x = r.minX - r.height
                while x < r.maxX {
                    hatch.move(to: CGPoint(x: x, y: r.maxY))
                    hatch.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                    x += spacing
                }
                layer.stroke(hatch, with: .color(color.opacity(0.75 * strength)), lineWidth: 1.5)
            }
            ctx.stroke(wall, with: .color(color.opacity(0.9 * strength)), lineWidth: 1.5)
            // 壁の下の縁を太く。
            var edge = Path()
            edge.addLines(bottomView)
            ctx.stroke(edge, with: .color(color.opacity(strength)), lineWidth: 3)

            // 画面外にはみ出す壁でもラベルが読めるよう、見えている部分の中心に置く。
            let visible = wall.boundingRect.intersection(CGRect(origin: .zero, size: proj.viewSize).insetBy(dx: 24, dy: 24))
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            let center = CGPoint(x: visible.midX, y: visible.midY)
            drawLabel(ctx, String(format: "%.1fm", dmin), at: center, color: color, size: 11, bold: true)
        }

        if let n = map.nearest, let q = proj.point(n) {
            let r = CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: r), with: .color(obstacleColor(n.length)))
            ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 1.5)
            drawLabel(ctx, String(format: "障害物 %.1fm", n.length), at: CGPoint(x: q.x, y: q.y + 14), color: obstacleColor(n.length), size: 11, bold: true)
        }
    }

    // MARK: - ヒートマップ

    private func drawRiskField(_ f: RiskField, ctx: GraphicsContext, proj: GroundProjector) {
        for r in 0..<f.rows {
            for c in 0..<f.columns {
                let safety = f.safety[r * f.columns + c]
                guard safety < 0.98 else { continue }
                let o = f.origin + Vec2(Double(c) * f.cellSize, Double(r) * f.cellSize)
                let corners = [o, o + Vec2(f.cellSize, 0), o + Vec2(f.cellSize, f.cellSize), o + Vec2(0, f.cellSize)]
                let qs = corners.compactMap { proj.point($0) }
                guard qs.count == 4 else { continue }
                var path = Path()
                path.addLines(qs)
                path.closeSubpath()
                ctx.fill(path, with: .color(Color(red: 1, green: 0.2, blue: 0.1).opacity((1 - safety) * 0.55)))
            }
        }
    }
}

/// 速度比（1 = 現在速度）→ 緑・黄・赤。
func speedColor(_ ratio: Double) -> Color {
    let r = min(max(ratio, 0), 1)
    if r >= 0.95 { return Color(red: 0.1, green: 0.85, blue: 0.35) }
    if r >= 0.6 {
        let a = (r - 0.6) / 0.35
        return Color(red: 1 - 0.9 * a, green: 0.8 + 0.05 * a, blue: 0.1 + 0.25 * a)
    }
    let a = r / 0.6
    return Color(red: 1, green: 0.15 + 0.65 * a, blue: 0.1)
}

/// 非衝突確率 → 色（デバッグの候補経路用）。
func safetyColor(_ p: Double) -> Color {
    Color(red: 1 - p, green: p, blue: 0.2)
}

func trackColor(_ id: Int) -> Color {
    let hues: [Double] = [0.58, 0.83, 0.08, 0.5, 0.92, 0.15, 0.7, 0.33]
    return Color(hue: hues[id % hues.count], saturation: 0.85, brightness: 0.8)
}
