#if os(iOS)
import AVFoundation
import HexNFCDesign
import HexNFCRecords
import SwiftUI

/// Live-camera QR scanner. Detects payload → parses via `QRPayloadParser`
/// → returns the candidate `NDEFRecord` to the caller. Camera permission
/// flow falls back to `PermissionRecoveryView` on `.denied`.
struct QRImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCandidate: (NDEFRecord) -> Void

    @State private var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var lastDetected: String?

    var body: some View {
        NavigationStack {
            Group {
                switch permission {
                case .authorized:
                    QRScannerContainer { payload in
                        guard lastDetected != payload else { return }
                        lastDetected = payload
                        let record = QRPayloadParser.parse(payload)
                        onCandidate(record)
                        dismiss()
                    }
                    .ignoresSafeArea()

                case .notDetermined:
                    requestPermissionView

                case .denied, .restricted:
                    PermissionRecoveryView(
                        title: "Camera access needed",
                        message: "Hex NFC reads QR codes through the camera. The camera frame is never saved or sent anywhere."
                    )

                @unknown default:
                    requestPermissionView
                }
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Scan a QR code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    private var requestPermissionView: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(HexTokens.Color.primaryLight)
            Text("Allow camera to scan a QR")
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Text("The frame is processed on-device. Nothing is uploaded.")
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HexTokens.Spacing.l)
            Button {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        permission = granted ? .authorized : .denied
                    }
                }
            } label: {
                Text("Allow camera")
                    .font(HexTokens.Font.heading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HexTokens.Spacing.m)
                    .background(
                        LinearGradient(
                            colors: [HexTokens.Color.primaryLight, HexTokens.Color.primary],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
            }
            .padding(.horizontal, HexTokens.Spacing.xxl)
            Spacer()
        }
        .padding(HexTokens.Spacing.l)
    }
}

// MARK: - Camera bridge

private struct QRScannerContainer: UIViewControllerRepresentable {
    let onDetect: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onDetect = onDetect
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onDetect = onDetect
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    var onDetect: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection)
    {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        onDetect?(value)
    }
}

// MARK: - Permission recovery

struct PermissionRecoveryView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 72))
                .foregroundStyle(HexTokens.Color.warning)
            Text(title)
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Text(message)
                .font(HexTokens.Font.body)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HexTokens.Spacing.l)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(HexTokens.Font.heading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HexTokens.Spacing.m)
                    .background(
                        LinearGradient(
                            colors: [HexTokens.Color.primaryLight, HexTokens.Color.primary],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous))
            }
            .padding(.horizontal, HexTokens.Spacing.xxl)
            Spacer()
        }
        .padding(HexTokens.Spacing.l)
    }
}
#endif
