import SwiftUI
import WebKit

/// 既定で開くサイト。これを見ようとして体を傾けると、ちょうど矢印の方向を向くことになる。
let defaultWebURL = URL(string: "https://www.nicovideo.jp/watch/sm30717222")!

/// WKWebView を SwiftUI に出す（iOS / macOS 共通）。URL が変わったときだけ読み込み直す。
struct WebView {
    var url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        #if os(iOS)
        config.allowsInlineMediaPlayback = true  // iOS のみのAPI
        #endif
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: url))
        coordinator.loadedURL = url
        return web
    }

    @MainActor
    private func reloadIfNeeded(_ web: WKWebView, _ coordinator: Coordinator) {
        guard coordinator.loadedURL != url else { return }
        web.load(URLRequest(url: url))
        coordinator.loadedURL = url
    }
}

#if os(iOS)
extension WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { reloadIfNeeded(web, context.coordinator) }
}
#else
extension WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { reloadIfNeeded(web, context.coordinator) }
}
#endif

/// 推奨経路の方位（矢印）に合わせて回転する WebView。
///
/// 矢印の先がサイトの上部になるよう、矢印と同じ角度だけ回す。
/// この画面を正立で見ようとして体を傾けると、ちょうど矢印の方向を向くので、
/// 自然に他の歩行者を避ける向きへ誘導される。
struct RotatingWebView: View {
    /// 推奨方向（ラジアン、右回り正、0 = 端末の前方 = 画面の上）。
    let heading: Double?
    var url: URL = defaultWebURL

    var body: some View {
        WebView(url: url)
            .rotationEffect(.radians(heading ?? 0))
            // 回転で四隅が欠けないよう、対角線ぶんの正方形にしてから回す。
            .modifier(FitRotatedSquare())
            .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: heading ?? 0)
            .allowsHitTesting(true)
    }
}

/// 回転しても画面全体を覆えるよう、ビューを外接円の直径ぶんの正方形にする。
private struct FitRotatedSquare: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            let side = hypot(geo.size.width, geo.size.height)
            content
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
