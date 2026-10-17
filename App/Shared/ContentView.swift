import RouteDanceCore
import RouteDancePerception
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    /// 入力ソースを選ぶボタン（プラットフォームごとに中身が違う）。
    var sourcePicker: AnyView
    /// 画像書き出し用: Metal ではなく SwiftUI の Image で映像を描く（ImageRenderer は Metal のビューを描けないため）。
    var staticBackground = false

    var body: some View {
        ZStack {
            if staticBackground {
                StaticVideoView(image: model.latest?.image, washedOut: model.debugMode)
            } else {
                VideoLayerView(image: model.latest?.image, washedOut: model.debugMode)
                    .ignoresSafeArea()
            }
            if let f = model.latest {
                OverlayView(frame: f, debug: model.debugMode, showRiskField: model.showRiskField, showCandidates: model.showCandidates)
                    .ignoresSafeArea()
            }
            if model.showWebView {
                RotatingWebView(
                    holder: model.webViewHolder,
                    heading: model.latest?.snapshot.plan?.best.lookaheadHeading,
                    slowdown: model.latest?.snapshot.plan?.best.requiresSlowdown ?? false,
                    minSpeedRatio: model.latest?.snapshot.plan?.best.speedRatio.min() ?? 1
                )
                .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                HUDView(frame: model.latest, fps: model.fps, status: model.status, source: model.source, debug: model.debugMode)
                Spacer()
                HStack(alignment: .bottom) {
                    menuButton
                    webViewButton
                    Spacer()
                    CompassView(
                        heading: model.latest?.snapshot.plan?.best.lookaheadHeading,
                        slowdown: model.latest?.snapshot.plan?.best.requiresSlowdown ?? false,
                        minSpeedRatio: model.latest?.snapshot.plan?.best.speedRatio.min() ?? 1
                    )
                }
                .padding(16)
            }
            if model.latest == nil {
                VStack(spacing: 12) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 44))
                    Text(model.status)
                    sourcePicker
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            DrawerView(model: model, sourcePicker: sourcePicker)
        }
    }

    private var menuButton: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { model.drawerOpen.toggle() }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("メニュー")
    }

    /// 矢印に合わせて回る WebView の表示・非表示を切り替える、ブラウザ風ボタン。
    private var webViewButton: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { model.showWebView.toggle() }
        } label: {
            Image(systemName: model.showWebView ? "safari.fill" : "safari")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(model.showWebView ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.showWebView ? "回る画面を隠す" : "回る画面を表示")
    }
}

/// 下からせり上がるドロワー。オプションを格納する。
struct DrawerView: View {
    @Bindable var model: AppModel
    var sourcePicker: AnyView

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.drawerOpen {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 14) {
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 40, height: 5)
                        .frame(maxWidth: .infinity)
                    Text("オプション").font(.headline)
                    Toggle("デバッグモード", isOn: $model.debugMode)
                    if model.debugMode {
                        Toggle("衝突確率のヒートマップ", isOn: $model.showRiskField)
                            .padding(.leading, 16)
                        Toggle("候補経路", isOn: $model.showCandidates)
                            .padding(.leading, 16)
                    }
                    Divider()
                    HStack {
                        Text("入力")
                        Spacer()
                        Text(model.source.label).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack {
                        sourcePicker
                        if model.isRunning {
                            Button("停止", role: .destructive) { model.stop() }
                        }
                    }
                    if case .video = model.source {
                        Button {
                            model.restartVideo()
                        } label: {
                            Label("動画を最初から再生", systemImage: "arrow.counterclockwise")
                        }
                    }
                    legend
                }
                .padding(20)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .transition(.move(edge: .bottom))
                .gesture(DragGesture().onEnded { if $0.translation.height > 60 { close() } })
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(speedColor(1), "現在の速度")
            legendItem(speedColor(0.7), "減速")
            legendItem(speedColor(0.2), "大きく減速")
        }
        .font(.caption)
    }

    private func legendItem(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 18, height: 6)
            Text(s)
        }
    }

    private func close() {
        withAnimation(.spring(duration: 0.35)) { model.drawerOpen = false }
    }
}
