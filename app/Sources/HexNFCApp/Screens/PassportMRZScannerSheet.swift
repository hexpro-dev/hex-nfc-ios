#if os(iOS)
import AVFoundation
import HexNFCDesign
import HexNFCRecords
import HexNFCShaders
import SwiftUI

/// Reads a passport's access key from its photo page through the camera. No
/// shutter: frames are read continuously, and the moment `MRZScanConsensus`
/// trusts a key the band locks, the tick and haptic play, and the key (with
/// any alternates) goes back to the passport prompt.
///
/// Nothing the camera sees is kept. Frames are read in memory and dropped,
/// the recognised text never reaches a log, and the screen is covered
/// whenever the app stops being active, so the app-switcher snapshot never
/// holds a photo page.
struct PassportMRZScannerSheet: View {
    let onCapture: (MRZScanConsensus.Lock) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var status = MRZScanStatus.searching
    @State private var lock: MRZScanConsensus.Lock?
    @State private var lockCount = 0
    @State private var isTorchOn = false
    @State private var isTakingLong = false
    /// The page guide's frame in window coordinates. The camera is pointed at
    /// the zone inside it and the dimming is cut around it.
    @State private var pageInWindow = CGRect.zero

    /// How long the tick holds before the sheet hands the key back.
    private static let lockHold: Duration = .milliseconds(850)
    /// When to suggest glare and light fixes.
    private static let slowHintDelay: Duration = .seconds(6)
    /// Share of the screen width the page outline may take.
    ///
    /// Holders match the page to the outline, so its size sets how far away
    /// they hold the phone. Pro iPhones cannot focus closer than 200 mm, and at
    /// 4K the zoom cannot help (upscale threshold 1.00 on an iPhone 16 Pro
    /// Max, 2026-10-27). With its 74.6 degree field of view, a page filling 92%
    /// of the screen sits at about 192 mm, inside that limit; at 72% it sits at
    /// about 250 mm. The page's height is held to 40% of the screen too, so
    /// the instructions and the captured values fit in landscape and on the
    /// smallest phones.
    private static let pageWidthShare: CGFloat = 0.72

    private var reduceMotion: Bool {
        systemReduceMotion || appReduceMotion
    }

    private var zoneInWindow: CGRect {
        pageInWindow.isEmpty ? .zero : PassportPageGuide.zone(inPage: pageInWindow)
    }

    private var guideEmphasis: PassportPageGuide.Emphasis {
        if lock != nil { return .locked }
        return status == .tracking ? .tracking : .searching
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch permission {
            case .authorized:
                scanner

            case .notDetermined:
                Color.black
                    .task { await requestAccess() }

            default:
                VStack(spacing: HexTokens.Spacing.l) {
                    PermissionRecoveryView(
                        title: "Camera access needed",
                        message: "Hex NFC reads the passport details through the camera. Nothing it sees is saved or sent anywhere. You can also type the details in."
                    )
                    HexButton("Enter details instead", variant: .ghost) { dismiss() }
                        .padding(.horizontal, HexTokens.Spacing.xl)
                }
                .background(HexTokens.Color.surface0.ignoresSafeArea())
            }

            if scenePhase != .active {
                privacyCover
            }
        }
        .hexHero(.mrzLock, trigger: lockCount)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("passport.mrzScanner")
    }

    // MARK: - Scanner

    private var scanner: some View {
        ZStack {
            MRZCameraView(
                guideInWindow: zoneInWindow,
                isTorchOn: isTorchOn,
                onStatus: { status = $0 },
                onLock: handleLock
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            dimming
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { proxy in
                VStack(spacing: HexTokens.Spacing.l) {
                    topBar
                    Spacer(minLength: 0)
                    instructions
                    pageGuide(
                        maxWidth: min(600, proxy.size.width * Self.pageWidthShare),
                        maxHeight: proxy.size.height * 0.4
                    )
                    capturedValues
                    Spacer(minLength: 0)
                    HexButton("Enter details instead", variant: .ghost) { dismiss() }
                        .opacity(lock == nil ? 1 : 0)
                        .accessibilityIdentifier("passport.mrzScanner.manual")
                }
                .padding(.horizontal, HexTokens.Spacing.l)
                .padding(.bottom, HexTokens.Spacing.l)
            }
        }
        .task {
            try? await Task.sleep(for: Self.slowHintDelay)
            if lock == nil { isTakingLong = true }
        }
    }

    private var topBar: some View {
        HStack {
            roundButton(systemImage: "xmark", label: "Close") { dismiss() }
                .accessibilityIdentifier("passport.mrzScanner.close")
            Spacer()
            if MRZCameraController.hasTorch {
                roundButton(
                    systemImage: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    label: isTorchOn ? "Turn off torch" : "Turn on torch"
                ) {
                    isTorchOn.toggle()
                }
            }
        }
        .padding(.top, HexTokens.Spacing.s)
    }

    private func roundButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HexTokens.Color.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(HexPressStyle())
        .accessibilityLabel(Text(label))
        .opacity(lock == nil ? 1 : 0)
    }

    private var instructions: some View {
        VStack(spacing: HexTokens.Spacing.s) {
            Text("Scan the photo page")
                .font(HexTokens.Font.title)
                .foregroundStyle(HexTokens.Color.textPrimary)
            Group {
                if lock != nil {
                    Text("Got it")
                } else if status == .tracking {
                    Text("Hold still")
                } else if isTakingLong, MRZCameraController.hasTorch {
                    Text("Still looking. Tilt the page away from bright lights, or try the torch.")
                } else if isTakingLong {
                    Text("Still looking. Tilt the page away from bright lights.")
                } else {
                    Text("Fit the two lines of letters and <<< at the bottom of the photo page inside the frame.")
                }
            }
            .font(HexTokens.Font.body)
            .foregroundStyle(lock != nil ? HexTokens.Color.success : HexTokens.Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: 520)
        .animation(reduceMotion ? nil : HexTokens.Motion.snappy, value: status)
    }

    /// A see-through photo page, so the holder can see what belongs in the
    /// picture, with the machine-readable zone framed along its bottom. The
    /// page's frame is reported in window coordinates; the camera reads the zone
    /// inside it (`PassportPageGuide.zone(inPage:)`), with a margin.
    private func pageGuide(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        PassportPageGuide(emphasis: guideEmphasis)
            .aspectRatio(PassportPageGuide.aspectRatio, contentMode: .fit)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .overlay {
                GeometryReader { proxy in
                    let zone = PassportPageGuide.zone(inPage: CGRect(origin: .zero, size: proxy.size))
                    if lock != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: min(56, zone.height * 0.85), weight: .semibold))
                            .foregroundStyle(HexTokens.Color.success)
                            .background(Circle().fill(HexTokens.Color.surface0).padding(6))
                            .position(x: zone.midX, y: zone.midY)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { pageInWindow = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in pageInWindow = frame }
                }
            }
            .animation(reduceMotion ? nil : HexTokens.Motion.lush, value: lock != nil)
            .animation(reduceMotion ? nil : HexTokens.Motion.standard, value: status)
            .accessibilityHidden(true)
    }

    /// Darkens everything but the page, so the eye goes where the passport
    /// should be.
    private var dimming: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let page = pageInWindow.offsetBy(dx: -origin.x, dy: -origin.y)
            let radius = page.width * PassportPageGuide.cornerRadiusShare
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                if !page.isEmpty {
                    path.addRoundedRect(in: page, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        }
    }

    /// The key that locked, so the holder sees what is going back to the
    /// prompt before the sheet closes.
    @ViewBuilder
    private var capturedValues: some View {
        if let key = lock?.key {
            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                capturedRow("Passport number", key.documentNumber)
                capturedRow("Date of birth", PassportMRZDate.display(key.dateOfBirth, isExpiry: false))
                capturedRow("Date of expiry", PassportMRZDate.display(key.dateOfExpiry, isExpiry: true))
            }
            .padding(HexTokens.Spacing.m)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HexTokens.Radius.m, style: .continuous)
                    .fill(HexTokens.Color.surface1.opacity(0.92))
            )
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        } else {
            // Holds the space so the band does not jump when the values appear.
            Color.clear.frame(height: 1)
        }
    }

    private func capturedRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            Spacer(minLength: HexTokens.Spacing.m)
            Text(verbatim: value)
                .font(HexTokens.Font.mono)
                .foregroundStyle(HexTokens.Color.textPrimary)
        }
    }

    private var privacyCover: some View {
        ZStack {
            HexTokens.Color.surface0.ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(HexTokens.Color.textSecondary)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permission = granted ? .authorized : .denied
    }

    private func handleLock(_ newLock: MRZScanConsensus.Lock) {
        guard lock == nil else { return }
        isTorchOn = false
        withAnimation(reduceMotion ? nil : HexTokens.Motion.lush) {
            lock = newLock
        }
        lockCount += 1
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Passport details captured"))
        Task {
            try? await Task.sleep(for: Self.lockHold)
            onCapture(newLock)
            dismiss()
        }
    }
}
#endif
