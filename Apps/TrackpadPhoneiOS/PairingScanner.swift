import AVFoundation
import SwiftUI
import TrackpadProtocol

/// The camera, pointed at the QR code on the Mac's screen.
///
/// `AVCaptureMetadataOutput` rather than the newer `DataScannerViewController`: that one is
/// built for reading text out in the world and brings its own guidance overlay and its own
/// opinion about the interface. This has one job — find our own code and hand it back.
struct PairingScanner: UIViewControllerRepresentable {
    let onFound: (PairingCode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onFound: (PairingCode) -> Void
        /// One code is enough. Without this the camera keeps reporting the same square
        /// thirty times a second and pairs thirty times.
        private var found = false

        init(onFound: @escaping (PairingCode) -> Void) {
            self.onFound = onFound
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !found else { return }
            for object in objects {
                guard let readable = object as? AVMetadataMachineReadableCodeObject,
                      let text = readable.stringValue,
                      let code = PairingCode(url: text) else { continue }
                found = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task { @MainActor in self.onFound(code) }
                return
            }
        }
    }
}

/// Owns the capture session. A view controller because the preview layer has to be resized
/// with the view, and that is the one thing SwiftUI cannot do for a `CALayer`.
final class ScannerController: UIViewController {
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // The types have to be set *after* the output joins the session, or the list of
        // what it can read is still empty and setting `.qr` traps.
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Starting blocks for a moment while the camera warms up, and doing that on the
        // main thread stalls the interface exactly as the sheet is appearing.
        Task.detached { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Task.detached { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}
