import CoreImage
import MetalKit
import SwiftUI

/// カメラ・動画のフレームを Metal で描く。デバッグ時はコントラストを下げて白っぽくする。
///
/// 画像はビューいっぱいにアスペクト比を保って表示する（はみ出す側を切る aspect fill）。
/// オーバーレイ側も同じ変換（`VideoFit`）で座標を合わせる。
final class VideoRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    var image: CIImage?
    var washedOut = true

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        var out = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1)).cropped(to: CGRect(origin: .zero, size: size))
        if let image {
            let fit = VideoFit(imageSize: image.extent.size, viewSize: size)
            var img = image
                .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: fit.scale, y: fit.scale))
            // CoreImage は左下原点なので、上下のオフセットは反転して与える。
            img = img.transformed(by: CGAffineTransform(translationX: fit.offset.x, y: size.height - fit.offset.y - image.extent.height * fit.scale))
            if washedOut {
                // コントラストを下げ、白を混ぜる。
                img = img.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 0.55, kCIInputSaturationKey: 0.5, kCIInputBrightnessKey: 0.28,
                ])
            }
            out = img.composited(over: out)
        }
        let dest = CIRenderDestination(
            width: Int(size.width), height: Int(size.height), pixelFormat: view.colorPixelFormat,
            commandBuffer: buffer, mtlTextureProvider: { drawable.texture }
        )
        _ = try? context.startTask(toRender: out, to: dest)
        buffer.present(drawable)
        buffer.commit()
    }
}

/// 画像をビューに aspect fill で置くときの変換（左上原点、ポイント単位またはピクセル単位）。
struct VideoFit {
    var scale: CGFloat
    var offset: CGPoint

    init(imageSize: CGSize, viewSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            scale = 1
            offset = .zero
            return
        }
        scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        offset = CGPoint(
            x: (viewSize.width - imageSize.width * scale) / 2,
            y: (viewSize.height - imageSize.height * scale) / 2
        )
    }

    func view(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }
}

#if os(iOS)
struct VideoLayerView: UIViewRepresentable {
    var image: CIImage?
    var washedOut: Bool

    func makeCoordinator() -> VideoRenderer? { VideoRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator?.device)
        configure(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator?.image = image
        context.coordinator?.washedOut = washedOut
        v.setNeedsDisplay()
    }
}
#else
struct VideoLayerView: NSViewRepresentable {
    var image: CIImage?
    var washedOut: Bool

    func makeCoordinator() -> VideoRenderer? { VideoRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator?.device)
        configure(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator?.image = image
        context.coordinator?.washedOut = washedOut
        v.needsDisplay = true
    }
}
#endif

@MainActor
private func configure(_ v: MTKView, _ r: VideoRenderer?) {
    v.delegate = r
    v.framebufferOnly = false
    v.colorPixelFormat = .bgra8Unorm
    v.enableSetNeedsDisplay = true
    v.isPaused = true
}

/// 映像を SwiftUI の Image で描く（画像書き出し用）。見た目は VideoRenderer と同じ。
struct StaticVideoView: View {
    var image: CIImage?
    var washedOut: Bool
    private static let context = CIContext()

    var body: some View {
        GeometryReader { geo in
            if let image, let cg = Self.render(image, washedOut: washedOut) {
                let fit = VideoFit(imageSize: image.extent.size, viewSize: geo.size)
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .frame(width: image.extent.width * fit.scale, height: image.extent.height * fit.scale)
                    .offset(x: fit.offset.x, y: fit.offset.y)
            } else {
                Color(red: 0.08, green: 0.08, blue: 0.1)
            }
        }
    }

    static func render(_ image: CIImage, washedOut: Bool) -> CGImage? {
        var img = image
        if washedOut {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 0.55, kCIInputSaturationKey: 0.5, kCIInputBrightnessKey: 0.28,
            ])
        }
        return context.createCGImage(img, from: image.extent)
    }
}
