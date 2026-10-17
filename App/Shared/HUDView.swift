import RouteDanceCore
import RouteDancePerception
import SwiftUI

/// 画面上部に常に出す情報: ユーザーの歩行速度と、アルゴリズムの動作状況。
struct HUDView: View {
    let frame: ProcessedFrame?
    let fps: Double
    let status: String
    let source: InputSource
    let debug: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(speedText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("m/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                statusPill
            }
            Text(lineOne)
            if debug {
                Text(lineTwo)
                Text(lineThree)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
    }

    private var speedText: String {
        guard let s = frame?.snapshot else { return "--" }
        return String(format: "%.2f", s.userSpeed)
    }

    private var statusPill: some View {
        let ok = frame?.snapshot.egoTracking ?? false
        let ground = frame?.snapshot.groundConverged ?? false
        return HStack(spacing: 6) {
            Circle().fill(ok ? .green : .orange).frame(width: 8, height: 8)
            Text(ok ? "自己位置OK" : "自己位置ロスト")
            Circle().fill(ground ? .green : .orange).frame(width: 8, height: 8)
            Text(ground ? "地面OK" : "地面推定中")
        }
        .font(.system(size: 10, weight: .medium))
    }

    private var lineOne: String {
        guard let f = frame else { return "\(source.label)  \(status)" }
        let s = f.snapshot
        let active = s.tracks.filter { $0.state == .confirmed }.count
        let p = s.plan.map { String(format: "P_safe %.0f%%%@", $0.best.pSafe * 100, $0.best.requiresSlowdown ? " 減速" : "") } ?? "-"
        return String(format: "%.0ffps  検出%d 追跡%d  %@  予測:%@", fps, s.persons.count, active, p, s.predictorName)
    }

    private var lineTwo: String {
        guard let f = frame else { return status }
        let st = f.stats
        return String(format: "検出 %.0fms 深度 %.0fms(%.1fs前) フロー %.0fms(%d点) core %.1fms",
                      st.detectionMilliseconds, st.depthMilliseconds, min(st.depthAge, 99), st.flowMilliseconds, st.flowPoints, st.coreMilliseconds)
    }

    private var lineThree: String {
        guard let f = frame else { return "" }
        let g = f.snapshot.geometry
        return String(format: "カメラ高 %.2fm 俯角 %.1f° 画角 %.0f°  odo %d点  %@",
                      g.ground.height, g.ground.pitch * 180 / .pi, g.camera.horizontalFOV * 180 / .pi,
                      f.snapshot.odometryInliers, source.label)
    }
}

/// コンパス型の矢印。推奨経路の先読み点の方位を、端末の向き（画面の上 = 前方）を基準に指す。360°回る。
struct CompassView: View {
    /// 推奨方向（ラジアン、右回り正、0 = 端末の前方）。
    let heading: Double?
    let slowdown: Bool
    let minSpeedRatio: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            ForEach(0..<8) { i in
                Rectangle()
                    .fill(.white.opacity(i % 2 == 0 ? 0.7 : 0.35))
                    .frame(width: 2, height: i % 2 == 0 ? 8 : 5)
                    .offset(y: -38)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
            ArrowShape()
                .fill(speedColor(slowdown ? minSpeedRatio : 1))
                .overlay(ArrowShape().stroke(.black.opacity(0.4), lineWidth: 1))
                .frame(width: 34, height: 58)
                .rotationEffect(.radians(heading ?? 0))
                .opacity(heading == nil ? 0.3 : 1)
                .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: heading ?? 0)
        }
        .frame(width: 92, height: 92)
    }
}

struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.45))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.18, y: r.minY + r.height * 0.42))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.18, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - r.width * 0.18, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - r.width * 0.18, y: r.minY + r.height * 0.42))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.45))
        p.closeSubpath()
        return p
    }
}
