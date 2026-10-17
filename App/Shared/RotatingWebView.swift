import SwiftUI
import WebKit

/// 既定で開くサイト。これを見ようとして体を傾けると、ちょうど矢印の方向を向くことになる。
let defaultWebURL = URL(string: "https://sp.nicovideo.jp/watch/sm30717222")!

/// スマホ縦持ち相当で表示するための User-Agent（iPhone Safari）。
/// これでサイトがモバイル版のレイアウトを返し、横幅が広がらなくなる。
private let mobileUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

/// WKWebView を1つだけ作って保持する箱。表示/非表示を切り替えても破棄せず使い回すことで、
/// 再生位置やログイン状態がリセットされないようにする。AppModel が持つ。
@MainActor
final class WebViewHolder {
    let webView: WKWebView

    init(url: URL = defaultWebURL) {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true  // iOS のみのAPI
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []

        // 端末幅に合わせて描画させる viewport を注入（PCサイズの広い横幅を防ぐ）。
        let viewport = """
            var m = document.createElement('meta');
            m.name = 'viewport';
            m.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
            document.head.appendChild(m);
            """
        config.userContentController.addUserScript(
            WKUserScript(source: viewport, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = mobileUserAgent
        webView.load(URLRequest(url: url))
    }
}

/// 既に作られた WKWebView を SwiftUI に出すだけのラッパー（iOS / macOS 共通）。
/// 生成・読み込みは WebViewHolder が受け持つので、ここでは何も読み込み直さない。
struct WebView {
    let webView: WKWebView
}

#if os(iOS)
extension WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ web: WKWebView, context: Context) {}
}
#else
extension WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ web: WKWebView, context: Context) {}
}
#endif

/// 推奨経路の方位（矢印）に合わせて回転する、ダイアログ風の WebView。
///
/// 矢印の先がサイトの上部になるよう、矢印と同じ角度だけ回す。
/// この画面を正立で見ようとして体を傾けると、ちょうど矢印の方向を向くので、
/// 自然に他の歩行者を避ける向きへ誘導される。
/// 見た目は「アプリ全体画面をひとまわり小さくして空中に浮かべたパネル」。
/// カード全体（WebView ＋ 枠 ＋ 影）を一つのまとまりとして回すので、中身は傾かない。
struct RotatingWebView: View {
    /// 使い回す WebView を保持する箱。
    let holder: WebViewHolder
    /// 推奨方向（ラジアン、右回り正、0 = 端末の前方 = 画面の上）。
    let heading: Double?
    /// 減速すべきか。true のときパネルを下へ大きくズラす。
    var slowdown: Bool = false
    /// 推奨経路上の最小速度比（1 = 現在速度、0 = 停止）。小さいほど大きく下げる。
    var minSpeedRatio: Double = 1

    /// 画面に対するパネルの大きさの割合（ひとまわり小さく）。
    private let scale: CGFloat = 0.88

    var body: some View {
        GeometryReader { geo in
            // 減速の強さ（0 = 不要、1 = 停止寄り）。
            let t = slowdown ? (1 - min(max(minSpeedRatio, 0), 1)) : 0

            // 画面と同じアスペクト比のまま、ひとまわり小さくする。
            // 減速するほどパネルを拡大して「迫ってくる＝ぶつかりそう」感を出す（最大 +25%）。
            let grow = 1 + 0.25 * t
            let width = geo.size.width * scale * grow
            let height = geo.size.height * scale * grow

            // 減速すべきときは垂直に下げる。拡大と比例。移動量は控えめ（最大で画面高さの約22%）。
            let drop = geo.size.height * 0.22 * t

            card
                .frame(width: width, height: height)
                .rotationEffect(.radians(heading ?? 0))
                // 回転の「後」に offset を足すので、傾きとは無関係に画面の下方向へまっすぐ動く。
                .offset(y: drop)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: heading ?? 0)
                .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: drop)
                .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: grow)
        }
        .allowsHitTesting(true)
    }

    /// WebView を角丸・枠・影でくるんだカード。これ全体を回す。
    private var card: some View {
        WebView(webView: holder.webView)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}
