import Foundation
import RouteDancePerception

/// 動画ファイルを実時間で再生しながらフレームを供給する。処理が追いつかないフレームは捨てる。
final class VideoFileSource: FrameSource, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var stopped = false
    /// セキュリティスコープ付きのURL（写真ライブラリやファイル選択）を開いたか。
    private let scoped: Bool

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func frames() -> AsyncStream<InputFrame> {
        let url = url
        // 消費側が遅いときは最新の1フレームだけを残す（実時間再生）。
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let reader = try VideoFrameReader(url: url)
                    let clock = ContinuousClock()
                    let start = clock.now
                    var firstTimestamp: Double?
                    while let self, !self.isStopped, let frame = try reader.next() {
                        let t0 = firstTimestamp ?? frame.timestamp
                        firstTimestamp = t0
                        let due = start + .seconds(frame.timestamp - t0)
                        if clock.now < due { try await Task.sleep(until: due) }
                        continuation.yield(frame)
                    }
                } catch {
                    // 読み込みに失敗したら終了する。
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
