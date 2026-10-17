@preconcurrency import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import RouteDancePerception

/// iOSのライブカメラ（背面広角）。ARKitは使わず、動画入力と同じ処理経路に乗せる。
/// CoreMotionの重力ベクトルをカメラ座標に変換して付ける（地面推定の事前分布に使う）。
final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private let motion = CMMotionManager()
    private var continuation: AsyncStream<InputFrame>.Continuation?
    private var horizontalFOV: Double?

    enum CameraError: Error { case unavailable }

    override init() {
        super.init()
    }

    func configure() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else { throw CameraError.unavailable }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.unavailable }
        session.addOutput(output)
        if let conn = output.connection(with: .video) {
            // 縦持ちで正立させる。
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            conn.preferredVideoStabilizationMode = .off  // 手ブレ補正はクロップで画角が変わるので切る
        }
        session.commitConfiguration()
        // 横向きセンサーの水平画角。縦持ちにすると、これが画像の縦方向の画角になる。
        let sensorFOV = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let f = Double(dims.width) / 2 / tan(sensorFOV / 2)
        horizontalFOV = 2 * atan(Double(dims.height) / 2 / f)
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
        continuation?.yield(InputFrame(image: image, timestamp: t, gravity: cameraGravity(), knownHorizontalFOV: horizontalFOV))
    }

    /// 端末座標の重力（x右・y上・z手前、縦持ち）を、カメラ座標（x右・y下・z前）へ。
    private func cameraGravity() -> SIMD3<Double>? {
        guard let g = motion.deviceMotion?.gravity else { return nil }
        let v = SIMD3(g.x, -g.y, -g.z)
        let n = (v * v).sum().squareRoot()
        return n > 0.1 ? v / n : nil
    }
}
