import SwiftUI
import UniformTypeIdentifiers

@main
struct RouteDanceMacApp: App {
    @State private var model: AppModel

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, sourcePicker: AnyView(MacSourcePicker(model: model)))
                .frame(minWidth: 480, minHeight: 640)
                .onDrop(of: [.movie], isTargeted: nil) { providers in
                    _ = providers.first?.loadFileRepresentation(for: .movie, openInPlace: true) { url, _, _ in
                        guard let url else { return }
                        Task { @MainActor in model.openVideo(url) }
                    }
                    return true
                }
        }
        .defaultSize(width: 540, height: 900)
    }

    init() {
        // @State の初期値を init 内で使うには、先に State(initialValue:) で入れておく必要がある。
        let initial = AppModel()
        _model = State(initialValue: initial)
        // 開発用: 起動引数 `-openVideo <path>` で動画を自動で開く（UIの動作確認用）。
        if let i = CommandLine.arguments.firstIndex(of: "-openVideo"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let m = initial
            Task { @MainActor in m.openVideo(url) }
        }
        // 開発用: `-snapshot <path>` で、数秒ごとに画面を PNG に書き出す（画面収録の権限なしで確認するため）。
        if let i = CommandLine.arguments.firstIndex(of: "-snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let m = initial
            Task { @MainActor in
                for n in 0..<6 {
                    try? await Task.sleep(for: .seconds(2))
                    // 最後の1枚はドロワーを開いた状態を書き出す。
                    if n == 5 { m.drawerOpen = true }
                    let view = ContentView(model: m, sourcePicker: AnyView(EmptyView()), staticBackground: true).frame(width: 540, height: 900)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    r.proposedSize = ProposedViewSize(width: 540, height: 900)
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(path)-\(n).png"))
                    }
                }
            }
        }
    }
}

/// Mac: 動画ファイルを開く。
struct MacSourcePicker: View {
    let model: AppModel
    @State private var importing = false

    var body: some View {
        Button("動画を開く…") { importing = true }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie]) { result in
                if case .success(let url) = result { model.openVideo(url) }
            }
    }
}

extension AppModel {
    func openVideo(_ url: URL) {
        start(.video(url)) { VideoFileSource(url: url) }
    }
}
