import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct RouteDanceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, sourcePicker: AnyView(IOSSourcePicker(model: model)))
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

/// iOS: カメラか、写真ライブラリの動画を選ぶ。
struct IOSSourcePicker: View {
    let model: AppModel
    @State private var item: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.drawerOpen = false
                model.start(.camera) {
                    let c = CameraFrameSource()
                    try c.configure()
                    return c
                }
            } label: {
                Label("カメラ", systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)
            PhotosPicker(selection: $item, matching: .videos, preferredItemEncoding: .current) {
                Label("動画", systemImage: "film")
            }
            .buttonStyle(.bordered)
            .disabled(loading)
            if loading { ProgressView() }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            loading = true
            Task {
                defer { loading = false }
                guard let movie = try? await newItem.loadTransferable(type: PickedMovie.self) else {
                    model.status = "動画を読み込めません"
                    return
                }
                model.drawerOpen = false
                model.start(.video(movie.url)) { VideoFileSource(url: movie.url) }
            }
        }
    }
}

/// 写真ライブラリの動画を一時ファイルにコピーして受け取る。
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
