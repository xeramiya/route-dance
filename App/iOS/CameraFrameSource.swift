@preconcurrency import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import OSLog
import RouteDancePerception

/// iOSのライブカメラ（背面の超広角を優先、なければ広角）。ARKitは使わず、動画入力と同じ処理経路に乗せる。
/// CoreMotionの重力ベクトルをカメラ座標に変換して付ける（地面推定の事前分布に使う）。
///
/// 画角の優先順位:
/// 1. サンプルバッファに付く内部パラメータ行列（`kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`、歪み補正後・配信バッファ基準）
/// 2. `activeFormat.geometricDistortionCorrectedVideoFieldOfView`（歪み補正後の水平画角。非対応なら videoFieldOfView と同じ）
/// 仮想デバイス（DualWide など）はレンズが自動で切り替わって画角が変わるので使わず、単体のデバイスを選ぶ。
final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private let motion = CMMotionManager()
    private let log = Logger(subsystem: "route-dance", category: "camera")
    private var continuation: AsyncStream<InputFrame>.Continuation?
    /// フォーマットから求めた、正立画像の水平画角（ラジアン）。内部パラメータが取れないときの代わり。
    private var formatHorizontalFOV: Double?
    private var loggedSource = false
    private(set) var deviceDescription = ""

    enum CameraError: Error { case unavailable }

    override init() {
        super.init()
    }

    func configure() throws {
        // 超広角を優先、なければ広角。
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera], mediaType: .video, position: .back
        )
        guard let device = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera })
            ?? discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
        else { throw CameraError.unavailable }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { throw CameraError.unavailable }

        session.beginConfiguration()
        session.addInput(input)
        // 720p。使えなければ、1280×720前後で30fpsが出るフォーマットを直接選ぶ。
        var directFormat: AVCaptureDevice.Format?
        if session.canSetSessionPreset(.hd1280x720) && device.supportsSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            directFormat = Self.bestFormat(device)
            session.sessionPreset = .inputPriority
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.unavailable
        }
        session.addOutput(output)
        if let conn = output.connection(with: .video) {
            // 縦持ちで正立させる。
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            conn.preferredVideoStabilizationMode = .off  // 手ブレ補正はクロップで画角が変わるので切る
            // 内部パラメータの配信は手ブレ補正が off のときだけ使える。startRunning の前に設定する。
            if conn.isCameraIntrinsicMatrixDeliverySupported { conn.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }
        session.commitConfiguration()

        try device.lockForConfiguration()
        if let directFormat {
            device.activeFormat = directFormat
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        // 歪み補正は on のまま。off にするとたる型歪みが残ってピンホール近似が崩れる。
        if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = true }
        // ズームは使わない（画角が変わる）。
        device.videoZoomFactor = 1
        // 連続オートフォーカス。超広角は近距離（マクロ）側に寄らないよう遠景に制限する。
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .far }
        device.unlockForConfiguration()

        // 歪み補正後の水平画角（センサーの長辺方向）。縦持ちにすると、正立画像の水平画角はセンサーの短辺方向の画角になる。
        let format = device.activeFormat
        let sensorFOV = Double(format.geometricDistortionCorrectedVideoFieldOfView) * .pi / 180
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let f = Double(dims.width) / 2 / tan(sensorFOV / 2)
        formatHorizontalFOV = 2 * atan(Double(dims.height) / 2 / f)
        deviceDescription = "\(device.localizedName) \(dims.width)x\(dims.height) GDC対応=\(device.isGeometricDistortionCorrectionSupported) "
            + "センサー水平画角=\(String(format: "%.1f", Double(format.geometricDistortionCorrectedVideoFieldOfView)))度 "
            + "正立画像の水平画角(フォーマット由来)=\(String(format: "%.1f", (formatHorizontalFOV ?? 0) * 180 / .pi))度"
        log.info("カメラ設定: \(self.deviceDescription, privacy: .public)")
    }

    /// 1280×720前後で30fpsが出るフォーマット。1280幅に近く、歪み補正後の画角が広いものを優先する。
    private static func bestFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.width >= 1280 && d.width <= 1920
                    && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            .min { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                if da.width != db.width { return da.width < db.width }
                return a.geometricDistortionCorrectedVideoFieldOfView > b.geometricDistortionCorrectedVideoFieldOfView
            }
    }

    func frames() -> AsyncStream<InputFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            self.continuation = c
            if self.motion.isDeviceMotionAvailable {
                self.motion.deviceMotionUpdateInterval = 1.0 / 30
                self.motion.startDeviceMotionUpdates()
            }
            self.queue.async { self.session.startRunning() }
            c.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        queue.async { self.session.stopRunning() }
        continuation?.finish()
        continuation = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let image = CIImage(cvPixelBuffer: pb)
        let fov = horizontalFOV(sampleBuffer, uprightWidth: Double(CVPixelBufferGetWidth(pb)), uprightHeight: Double(CVPixelBufferGetHeight(pb)))
        continuation?.yield(InputFrame(image: image, timestamp: t, gravity: cameraGravity(), knownHorizontalFOV: fov))
    }

    /// 正立画像の水平画角（ラジアン）。内部パラメータを優先し、なければフォーマット由来の値。
    ///
    /// 内部パラメータは焦点距離がピクセル単位で、画素が正方形なら 90° 回転しても fx ≒ fy のまま。
    /// 行列が回転前（横長）と回転後（縦長）のどちらの座標系かは主点（cx, cy）で見分けられるが、
    /// 焦点距離はどちらでも同じなので、画角は正立画像の幅に対して 2·atan(幅/2/f) で求められる。
    private func horizontalFOV(_ sb: CMSampleBuffer, uprightWidth: Double, uprightHeight: Double) -> Double? {
        guard let data = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
              data.count >= MemoryLayout<matrix_float3x3>.size
        else { return fallbackFOV(reason: "内部パラメータなし") }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        let fx = Double(m.columns.0.x), fy = Double(m.columns.1.y)
        let cx = Double(m.columns.2.x), cy = Double(m.columns.2.y)
        guard fx > 1, fy > 1 else { return fallbackFOV(reason: "内部パラメータが不正") }
        let f = (fx + fy) / 2
        let fov = 2 * atan(uprightWidth / 2 / f)
        if !loggedSource {
            loggedSource = true
            // 主点が正立バッファの中心付近なら行列も回転後の座標系、横長バッファの中心付近なら回転前の座標系。
            let upright = abs(cx - uprightWidth / 2) < abs(cx - uprightHeight / 2)
            log.info("内部パラメータ: fx=\(fx) fy=\(fy) cx=\(cx) cy=\(cy) 画像=\(uprightWidth)x\(uprightHeight) 座標系=\(upright ? "回転後" : "回転前", privacy: .public) 水平画角=\(fov * 180 / .pi)度")
        }
        // フォーマット由来の値と大きく食い違うときは、行列の基準が想定と違うので、フォーマット側を使う。
        if let fmt = formatHorizontalFOV, abs(fov - fmt) > 0.25 * fmt {
            return fallbackFOV(reason: "内部パラメータがフォーマット由来と不一致 (内部=\(fov * 180 / .pi)度, フォーマット=\(fmt * 180 / .pi)度)")
        }
        return fov
    }

    private func fallbackFOV(reason: String) -> Double? {
        if !loggedSource {
            loggedSource = true
            log.warning("画角はフォーマット由来を使う: \(reason, privacy: .public)")
        }
        return formatHorizontalFOV
    }

    /// 端末座標の重力（x右・y上・z手前、縦持ち）を、カメラ座標（x右・y下・z前）へ。
    private func cameraGravity() -> SIMD3<Double>? {
        guard let g = motion.deviceMotion?.gravity else { return nil }
        let v = SIMD3(g.x, -g.y, -g.z)
        let n = (v * v).sum().squareRoot()
        return n > 0.1 ? v / n : nil
    }
}
