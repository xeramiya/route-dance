import CoreImage
import Foundation
import Observation
import RouteDanceCore
import RouteDancePerception

/// 入力ソース。
enum InputSource: Equatable {
    case none
    case camera
    case video(URL)

    var label: String {
        switch self {
        case .none: "なし"
        case .camera: "カメラ"
        case .video(let url): "動画: \(url.lastPathComponent)"
        }
    }
}

/// フレームの供給元。ライブカメラと動画ファイルで共通のインターフェース。
protocol FrameSource: AnyObject, Sendable {
    /// フレームを順に返す。終わったら終了する。
    func frames() -> AsyncStream<InputFrame>
    func stop()
}

/// アプリ全体の状態。UIはこれを監視して描画する。
@MainActor
@Observable
final class AppModel {
    var debugMode = true
    var showRiskField = true
    var showCandidates = true
    var drawerOpen = false
    var source: InputSource = .none
    var latest: ProcessedFrame?
    var fps: Double = 0
    var status = "入力を選んでください"
    var isRunning = false

    private let processor = FrameProcessor()
    private var frameSource: (any FrameSource)?
    private var runTask: Task<Void, Never>?
    private var fpsWindow: [Double] = []

    func start(_ source: InputSource, makeSource: () throws -> any FrameSource) {
        stop()
        self.source = source
        do {
            let fs = try makeSource()
            frameSource = fs
            isRunning = true
            status = "処理中"
            runTask = Task { [weak self, processor] in
                await processor.reset()
                for await frame in fs.frames() {
                    if Task.isCancelled { break }
                    let out = await processor.process(frame)
                    let depthStatus = await processor.depthStatus
                    await MainActor.run {
                        self?.receive(out, depthStatus: depthStatus)
                    }
                }
                await MainActor.run {
                    self?.isRunning = false
                    self?.status = "停止"
                }
            }
        } catch {
            status = "開始できません: \(error.localizedDescription)"
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        frameSource?.stop()
        frameSource = nil
        isRunning = false
        fpsWindow.removeAll()
    }

    private func receive(_ frame: ProcessedFrame, depthStatus: String?) {
        latest = frame
        let now = ProcessInfo.processInfo.systemUptime
        fpsWindow.append(now)
        fpsWindow.removeAll { now - $0 > 1 }
        fps = Double(fpsWindow.count)
        if let depthStatus { status = depthStatus }
    }
}
