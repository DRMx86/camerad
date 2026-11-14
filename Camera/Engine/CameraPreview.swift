import SwiftUI
import AVFoundation

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Live preview with tap-to-focus, pinch-to-zoom and vertical drag for exposure.
struct CameraPreview: UIViewRepresentable {
    let model: CameraModel

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = model.session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: CameraModel
        private var startZoom: CGFloat = 1
        private var startBias: Float = 0

        init(model: CameraModel) { self.model = model }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? PreviewView else { return }
            let p = g.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            model.focus(devicePoint: devicePoint, viewPoint: p)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                startZoom = model.zoom
            case .changed:
                model.setZoom(startZoom * g.scale, ramp: false)
            default:
                break
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard model.focusPoint != nil, let view = g.view else { return }
            switch g.state {
            case .began:
                startBias = model.exposureBias
            case .changed:
                let dy = g.translation(in: view).y
                let delta = Float(-dy / (view.bounds.height * 0.25)) * 2
                model.setExposureBias(startBias + delta)
            default:
                break
            }
        }
    }
}
