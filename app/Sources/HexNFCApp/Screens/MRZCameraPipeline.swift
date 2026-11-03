#if os(iOS)
import AVFoundation
import HexNFCDesign
import HexNFCRecords
import os
import SwiftUI
import UIKit
import Vision

/// What the passport scanner tells the holder.
enum MRZScanStatus: Equatable {
    /// Nothing zone-shaped in the band yet.
    case searching
    /// Zone-shaped text seen, not yet agreed on: keep still.
    case tracking
}

/// Timings and camera settings only. Nothing the camera read is ever logged:
/// the zone is the passport's access key. Lines carry the `[HEXNFC]` sentinel
/// at the default level, like `NFCTrace`, so the bench's `idevicesyslog -m`
/// tail picks them up (the syslog relay drops `.info`).
private let mrzLog = Logger(subsystem: "pro.hex.nfc", category: "mrz")

private func logMRZ(_ message: String) {
    mrzLog.log("[HEXNFC] mrz: \(message, privacy: .public)")
}

// MARK: - Frames

/// Everything that runs per frame, confined to one serial queue: the Vision
/// request, the consensus, and the numbers it reports.
///
/// One frame is in flight at a time. The capture output drops frames that
/// arrive while one is being read (`alwaysDiscardsLateVideoFrames`), so a
/// slower phone reads fewer frames rather than falling behind.
final class MRZFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "pro.hex.nfc.mrz.frames", qos: .userInitiated)

    /// Called on the main queue.
    var onStatus: ((MRZScanStatus) -> Void)?
    /// Called on the main queue, once.
    var onLock: ((MRZScanConsensus.Lock) -> Void)?

    // Confined to `queue`.
    private var consensus = MRZScanConsensus()
    private let request = MRZFrameProcessor.makeRequest()
    private var orientation: CGImagePropertyOrientation = .right
    private var regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var status = MRZScanStatus.searching
    private var isFinished = false
    private var device: AVCaptureDevice?
    private var metrics = Metrics()

    private struct Metrics {
        var started: CFTimeInterval?
        var firstTracking: CFTimeInterval?
        var frames = 0
        var framesWithReadings = 0
        var skippedWhileFocusing = 0
        var visionSeconds: CFTimeInterval = 0
    }

    /// `.accurate`: the fast recogniser handles long `<` runs poorly. Language
    /// correction off, because a zone is not words and "correcting" it is the
    /// last thing wanted. Revision pinned so an OS update cannot quietly change
    /// what the fuzz suite and the bench measured.
    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.revision = VNRecognizeTextRequestRevision3
        // Relative to the band's height. A zone character is about 9% of the
        // band when the zone fills it; this skips text under half that, which
        // the visual zone's small print mostly is.
        request.minimumTextHeight = 0.04
        return request
    }

    func attach(device: AVCaptureDevice) {
        queue.async { self.device = device }
    }

    func update(orientation: CGImagePropertyOrientation, regionOfInterest: CGRect) {
        queue.async {
            self.orientation = orientation
            self.regionOfInterest = regionOfInterest
        }
    }

    /// Load the recognition model before the first real frame, so the first
    /// frame with the zone in it is not also the one that pays for it.
    func warmUp() {
        queue.async {
            guard let context = CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            guard let image = context.makeImage() else { return }
            let warmUp = Self.makeRequest()
            try? VNImageRequestHandler(cgImage: image).perform([warmUp])
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isFinished, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        if metrics.started == nil { metrics.started = now }
        // A frame taken mid-refocus is soft, and a soft frame's misreads are
        // the ones most likely to repeat.
        if device?.isAdjustingFocus == true {
            metrics.skippedWhileFocusing += 1
            return
        }
        request.regionOfInterest = regionOfInterest
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return
        }
        metrics.frames += 1
        metrics.visionSeconds += CACurrentMediaTime() - now
        let observations = (request.results ?? []).map { result in
            let box = result.boundingBox
            return MRZTextObservation(
                candidates: result.topCandidates(3).map(\.string),
                minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY
            )
        }
        let readings = MRZLineReader.readings(from: observations)
        if !readings.isEmpty {
            metrics.framesWithReadings += 1
            if metrics.firstTracking == nil { metrics.firstTracking = now }
        }
        if let lock = consensus.add(readings, at: now) {
            isFinished = true
            logLock(at: CACurrentMediaTime())
            DispatchQueue.main.async { self.onLock?(lock) }
            return
        }
        let current: MRZScanStatus = consensus.isTracking(at: now) ? .tracking : .searching
        if current != status {
            status = current
            DispatchQueue.main.async { self.onStatus?(current) }
        }
    }

    private func logLock(at time: CFTimeInterval) {
        let sinceStart = metrics.started.map { time - $0 } ?? 0
        let sinceTracking = metrics.firstTracking.map { time - $0 } ?? 0
        let meanVision = metrics.frames > 0 ? metrics.visionSeconds / Double(metrics.frames) : 0
        let message = String(
            format: "lock %.2fs from open, %.2fs from first zone frame; %d frames read, %d with zone, %d skipped focusing, vision %.0fms mean",
            sinceStart, sinceTracking, metrics.frames, metrics.framesWithReadings, metrics.skippedWhileFocusing,
            meanVision * 1000
        )
        logMRZ(message)
    }
}

// MARK: - Camera

/// Owns the capture session for the passport scanner and keeps Vision, focus
/// and zoom pointed at the on-screen guide band.
final class MRZCameraController: UIViewController {
    let processor = MRZFrameProcessor()

    /// The machine-readable zone of the on-screen page guide, in window
    /// coordinates. Set from SwiftUI.
    var guideInWindow: CGRect = .zero {
        didSet {
            if guideInWindow != oldValue { applyGeometry() }
        }
    }

    var isTorchOn = false {
        didSet {
            if isTorchOn != oldValue { applyTorch() }
        }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pro.hex.nfc.mrz.session")
    private var device: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var bufferSize = CGSize(width: 1920, height: 1080)
    /// What was last sent to the device. Setting the focus point re-arms
    /// autofocus, so sending the same values again on every layout pass would
    /// make the lens hunt.
    private var appliedZoom: CGFloat?
    private var appliedFocusPoint: CGPoint?

    /// Whether this phone has the back wide-angle camera the scanner uses.
    /// Asked once: hardware does not change while the app runs.
    static let isAvailable = backCamera() != nil

    static let hasTorch = backCamera()?.hasTorch == true

    /// The wide-angle camera only. The multi-camera devices hop to the
    /// ultra-wide for close-ups mid-scan, which brings a field-of-view jump, a
    /// refocus and barrel distortion at the edges, exactly where a 44-character
    /// line runs.
    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isTorchOn = false
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        applyGeometry()
    }

    private func configureSession() {
        guard let device = Self.backCamera(), let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.device = device
        session.beginConfiguration()
        // 4K where the phone offers it: at 1080p a zone character is only about
        // 15 pixels tall in portrait. Vision's cost follows the band, not the
        // frame, so the larger buffer costs little.
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            bufferSize = CGSize(width: 3840, height: 2160)
        } else {
            session.sessionPreset = .hd1920x1080
            bufferSize = CGSize(width: 1920, height: 1080)
        }
        if session.canAddInput(input) { session.addInput(input) }
        // No audio input: an audio session would mute the lock haptic.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.setSampleBufferDelegate(processor, queue: processor.queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let connection = output.connection(with: .video), connection.isVideoStabilizationSupported {
            // Stabilisation crops and shifts the frame after the fact, which
            // moves the zone out from under the band.
            connection.preferredVideoStabilizationMode = .off
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        configureFocus(device)
        processor.attach(device: device)
        processor.warmUp()

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyGeometry() }
        }
    }

    private func configureFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }

    /// Point Vision, focus, exposure and zoom at the band for the current
    /// orientation.
    private func applyGeometry() {
        guard let device, let preview = previewLayer, let coordinator = rotationCoordinator,
              view.bounds.width > 0 else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let guide = guideInWindow.isEmpty ? view.bounds : view.convert(guideInWindow, from: nil)
        let upright = MRZScanGeometry.uprightSize(buffer: bufferSize, previewRotationAngle: angle)
        processor.update(
            orientation: MRZScanGeometry.orientation(forPreviewRotationAngle: angle),
            regionOfInterest: MRZScanGeometry.regionOfInterest(
                guide: MRZScanGeometry.readingRegion(zone: guide), layer: view.bounds.size, uprightImage: upright
            )
        )
        let format = device.activeFormat
        let zoom = MRZScanGeometry.zoomFactor(
            minimumFocusDistance: device.minimumFocusDistance,
            fieldOfView: format.videoFieldOfView,
            buffer: bufferSize,
            previewRotationAngle: angle,
            layer: view.bounds.size,
            // The zone runs the page's full width, so the page is the subject.
            guideWidth: guide.width,
            subjectWidthMillimetres: Double(PassportPageGuide.pageWidthMillimetres),
            maximum: min(format.videoZoomFactorUpscaleThreshold, device.maxAvailableVideoZoomFactor)
        )
        let focusPoint = preview.captureDevicePointConverted(fromLayerPoint: CGPoint(x: guide.midX, y: guide.midY))
        guard zoom != appliedZoom || focusPoint != appliedFocusPoint else { return }
        if zoom != appliedZoom {
            logMRZ(String(
                format: "camera %.0fx%.0f, angle %.0f, min focus %d mm, fov %.1f deg, zoom %.2f (cap %.2f), band %.0fx%.0f pt",
                bufferSize.width, bufferSize.height, angle, device.minimumFocusDistance, format.videoFieldOfView,
                zoom, min(format.videoZoomFactorUpscaleThreshold, device.maxAvailableVideoZoomFactor),
                guide.width, guide.height
            ))
        }
        appliedZoom = zoom
        appliedFocusPoint = focusPoint
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = zoom
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = focusPoint
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func applyTorch() {
        guard let device, device.hasTorch else { return }
        let on = isTorchOn
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.torchMode = on ? .on : .off
        }
    }
}

/// SwiftUI bridge. The controller is created once by `makeUIViewController`
/// and lives as long as the view, so SwiftUI re-evaluating the scanner sheet
/// never rebuilds the capture session (the same failure `ScanSheet` documents
/// for its flow model).
struct MRZCameraView: UIViewControllerRepresentable {
    var guideInWindow: CGRect
    var isTorchOn: Bool
    var onStatus: (MRZScanStatus) -> Void
    var onLock: (MRZScanConsensus.Lock) -> Void

    func makeUIViewController(context: Context) -> MRZCameraController {
        let controller = MRZCameraController()
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: MRZCameraController, context: Context) {
        update(controller)
    }

    private func update(_ controller: MRZCameraController) {
        controller.processor.onStatus = onStatus
        controller.processor.onLock = onLock
        controller.guideInWindow = guideInWindow
        controller.isTorchOn = isTorchOn
    }
}
#endif
