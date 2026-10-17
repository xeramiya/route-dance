import RouteDanceCore
import RouteDancePerception
import SwiftUI

/// 推奨経路・予測経路・ヒートマップ・検出枠を、映像に重ねて描く。
struct OverlayView: View {
    let frame: ProcessedFrame
    let debug: Bool
    let showRiskField: Bool
    let showCandidates: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = frame.snapshot
            let imageSize = frame.image.extent.size
            let fit = VideoFit(imageSize: imageSize, viewSize: size)
            let g = s.geometry
            // 地面座標 → ビュー座標。カメラのすぐ近く（画面外に大きくはみ出す点）は描かない。
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -size.width, dy: -size.height)
            func project(_ p: Vec2, height: Double = 0) -> CGPoint? {
                guard let px = g.project(ground: p, height: height) else { return nil }
                let v = fit.view(CGPoint(x: px.x, y: px.y))
                return bounds.contains(v) ? v : nil
            }

            if debug, showRiskField, let field = s.riskField {
                drawRiskField(field, ctx: ctx, project: project)
            }
            if debug, showCandidates, let plan = s.plan {
                for c in plan.candidates where c.points.count > 1 {
                    let path = polyline(c.points, project: project)
                    ctx.stroke(path, with: .color(safetyColor(c.pSafe).opacity(0.18)), lineWidth: 1)
                }
            }
            if debug {
                drawForecasts(s, ctx: ctx, project: project)
                drawTrackHistory(s, ctx: ctx, project: project)
                drawDetections(s, ctx: ctx, fit: fit)
            }
            if let plan = s.plan {
                drawPlan(plan.best, ctx: ctx, project: project, width: debug ? 6 : 10)
                if debug, let gp = project(plan.goal) {
                    ctx.fill(Path(ellipseIn: CGRect(x: gp.x - 5, y: gp.y - 5, width: 10, height: 10)), with: .color(.blue))
                }
            }
            if debug, let hy = g.horizonY {
                let y = fit.view(CGPoint(x: 0, y: hy)).y
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.purple.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
            }
        }
        .allowsHitTesting(false)
    }

    private func polyline(_ pts: [Vec2], project: (Vec2, Double) -> CGPoint?) -> Path {
        var path = Path()
        var started = false
        for p in pts {
            guard let q = project(p, 0) else {
                started = false
                continue
            }
            if started { path.addLine(to: q) } else { path.move(to: q) }
            started = true
        }
        return path
    }

    /// 推奨経路: 速度比で緑 → 黄 → 赤。
    private func drawPlan(_ plan: PlannedPath, ctx: GraphicsContext, project: (Vec2, Double) -> CGPoint?, width: CGFloat) {
        let pts = plan.points
        guard pts.count > 1 else { return }
        for i in 1..<pts.count {
            guard let a = project(pts[i - 1], 0), let b = project(pts[i], 0) else { continue }
            var seg = Path()
            seg.move(to: a)
            seg.addLine(to: b)
            // 遠いほど細く見えるよう、奥行きに応じて線幅を変える。
            let depthScale = max(0.35, 1 - pts[i].length / 12)
            ctx.stroke(seg, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: width * depthScale + 3, lineCap: .round))
            ctx.stroke(seg, with: .color(speedColor(plan.speedRatio[i])), style: StrokeStyle(lineWidth: width * depthScale, lineCap: .round))
        }
    }

    private func drawForecasts(_ s: NavigationSnapshot, ctx: GraphicsContext, project: (Vec2, Double) -> CGPoint?) {
        let confirmed = Set(s.tracks.filter { $0.state == .confirmed && $0.hits >= 5 }.map(\.id))
        for f in s.forecasts where confirmed.contains(f.id) {
            let color = trackColor(f.id)
            let n = f.times.filter { $0 <= f.horizon }.count
            // サンプル（薄く）と、重み付き平均（太く）。表示はホライズン N まで。
            for sample in f.samples {
                ctx.stroke(polyline(Array(sample.prefix(n)), project: project), with: .color(color.opacity(0.18)), lineWidth: 1)
            }
            let mean = (0..<n).map { i in f.samples.indices.reduce(Vec2.zero) { $0 + f.samples[$1][i] * f.weights[$1] } }
            ctx.stroke(polyline(mean, project: project), with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // ホライズン N の時点の不確かさ（2σ）の円を地面上に描く。
            if let center = mean.last {
                let r = f.sigma(at: f.horizon) * 2
                var ring = Path()
                var started = false
                for i in 0...24 {
                    let a = Double(i) / 24 * 2 * .pi
                    guard let q = project(center + Vec2(cos(a), sin(a)) * r, 0) else { continue }
                    if started { ring.addLine(to: q) } else { ring.move(to: q) }
                    started = true
                }
                ctx.stroke(ring, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let p = project(f.position, 0) {
                ctx.draw(
                    Text(String(format: "#%d N=%.1fs", f.id, f.horizon)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(color),
                    at: CGPoint(x: p.x, y: p.y + 10)
                )
            }
        }
    }

    private func drawDetections(_ s: NavigationSnapshot, ctx: GraphicsContext, fit: VideoFit) {
        for p in s.persons {
            let d = p.detection
            let a = fit.view(CGPoint(x: d.minX, y: d.minY)), b = fit.view(CGPoint(x: d.maxX, y: d.maxY))
            let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            ctx.stroke(Path(rect), with: .color(.cyan.opacity(0.8)), lineWidth: 1)
            let label = String(format: "%.1fm %.0f%%", p.position.length, d.confidence * 100)
            ctx.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.cyan), at: CGPoint(x: rect.midX, y: rect.minY - 7))
        }
    }

    private func drawTrackHistory(_ s: NavigationSnapshot, ctx: GraphicsContext, project: (Vec2, Double) -> CGPoint?) {
        for t in s.tracks where t.state != .tentative {
            let path = polyline(t.history.map(\.p), project: project)
            ctx.stroke(path, with: .color(trackColor(t.id).opacity(t.state == .lost ? 0.3 : 0.9)), lineWidth: 2)
        }
    }

    private func drawRiskField(_ f: RiskField, ctx: GraphicsContext, project: (Vec2, Double) -> CGPoint?) {
        for r in 0..<f.rows {
            for c in 0..<f.columns {
                let safety = f.safety[r * f.columns + c]
                guard safety < 0.98 else { continue }
                let o = f.origin + Vec2(Double(c) * f.cellSize, Double(r) * f.cellSize)
                let corners = [o, o + Vec2(f.cellSize, 0), o + Vec2(f.cellSize, f.cellSize), o + Vec2(0, f.cellSize)]
                let qs = corners.compactMap { project($0, 0) }
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
