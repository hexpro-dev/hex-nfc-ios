import Foundation
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// One-shot haptic engine that loads `.ahap` patterns from the bundle and
/// plays them on demand. Lifecycle:
///
///   1. `prepare()` at app launch — eager-starts `CHHapticEngine`, restarts
///      it on reset (per Apple's `resetHandler` guidance).
///   2. `play(_:)` on any thread — silent when haptics are off in Settings,
///      silent when the engine failed to start, never throws to the caller.
///
/// Patterns are referenced by `HexHapticPattern`. Each maps to a `.ahap` file
/// at `HexNFCShaders/Haptics/Patterns/<name>.ahap`. The patterns themselves
/// are authored in Phase 5 polish; for Phase 2 the engine loads whatever
/// patterns exist and falls back to a simple transient otherwise.
public final class HexHapticsEngine: @unchecked Sendable {
    public static let shared = HexHapticsEngine()

    public private(set) var isEnabled: Bool = true
    private let queue = DispatchQueue(label: "pro.hex.nfc.haptics")

    #if canImport(CoreHaptics) && os(iOS)
    private var engine: CHHapticEngine?
    #endif

    private init() {}

    public func prepare() {
        #if canImport(CoreHaptics) && os(iOS)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            engine.stoppedHandler = { _ in /* will lazily restart on next play */ }
            try engine.start()
            self.engine = engine
        } catch {
            // Engine failure is non-fatal — patterns no-op until the engine
            // recovers.
            engine = nil
        }
        #endif
    }

    public func setEnabled(_ enabled: Bool) {
        queue.sync { self.isEnabled = enabled }
    }

    public func play(_ pattern: HexHapticPattern) {
        queue.async { [weak self] in
            guard let self, isEnabled else { return }
            #if canImport(CoreHaptics) && os(iOS)
            guard let engine else { return }
            do {
                let chPattern = try loadOrSynthesize(pattern)
                let player = try engine.makePlayer(with: chPattern)
                try player.start(atTime: 0)
            } catch {
                // Silently degrade. Real production: log to os.Logger.
            }
            #endif
        }
    }

    #if canImport(CoreHaptics) && os(iOS)
    private func loadOrSynthesize(_ pattern: HexHapticPattern) throws -> CHHapticPattern {
        if let url = Bundle.module.url(forResource: pattern.fileName, withExtension: "ahap") {
            return try CHHapticPattern(contentsOf: url)
        }
        // Phase-2 fallback: a credible transient + continuous swell so the
        // moment composer feels alive even before the AHAP files land.
        return try CHHapticPattern(events: pattern.fallbackEvents, parameters: [])
    }
    #endif
}

/// Catalogue of every haptic moment the app fires. The file-name maps to
/// `Haptics/Patterns/<fileName>.ahap` in the `HexNFCShaders` bundle.
public enum HexHapticPattern: String, Sendable, CaseIterable {
    case scanIdlePulse = "scan.idle.pulse"
    case scanDetected = "scan.detected"
    case scanReading = "scan.reading"
    case scanSuccess = "scan.success"
    case writeTransmit = "write.transmit"
    case writeVerify = "write.verify"
    case writeLockIn = "write.lockin"
    case errorStab = "error.stab"
    case destructiveWarn = "destructive.warn"
    case consoleCommit = "console.commit"
    case consolePulse = "console.pulse"
    case dragSnap = "drag.snap"
    case copyTick = "copy.tick"
    case tapTick = "ui.tap"
    case commitThud = "ui.commit"

    public var fileName: String {
        rawValue
    }
}

// MARK: - Phase-2 fallback events

#if canImport(CoreHaptics) && os(iOS)
extension HexHapticPattern {
    var fallbackEvents: [CHHapticEvent] {
        switch self {
        case .scanIdlePulse:
            [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.18),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.30),
                    ],
                    relativeTime: 0,
                    duration: 1.1
                ),
            ]

        case .scanDetected:
            [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.95),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85),
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.40),
                    ],
                    relativeTime: 0.05,
                    duration: 0.35
                ),
            ]

        case .scanReading:
            tickTrain(start: 0, count: 6, gap: 0.09, intensity: 0.45, sharpness: 0.55)

        case .scanSuccess:
            [
                transient(at: 0, intensity: 0.7, sharpness: 0.5),
                transient(at: 0.08, intensity: 0.85, sharpness: 0.7),
                transient(at: 0.18, intensity: 1.0, sharpness: 0.9),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
                    ],
                    relativeTime: 0.2,
                    duration: 0.2
                ),
            ]

        case .writeTransmit:
            tickTrain(start: 0, count: 8, gap: 0.07, intensity: 0.5, sharpness: 0.6)

        case .writeVerify:
            [
                transient(at: 0, intensity: 0.4, sharpness: 0.5),
                transient(at: 0.2, intensity: 0.5, sharpness: 0.5),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.15),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                    ],
                    relativeTime: 0,
                    duration: 0.4
                ),
            ]

        case .writeLockIn:
            // Write burst: a hard launch thump, a rolling swell as the ring
            // races outward, an edge-hit accent, then a flowing swell that
            // fades with the rim glow. Tracks the `.hexWriteBurst` visual.
            [
                transient(at: 0.0, intensity: 1.0, sharpness: 0.8), // launch
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45),
                    ],
                    relativeTime: 0.02,
                    duration: 0.42
                ),
                transient(at: 0.44, intensity: 0.85, sharpness: 0.6), // ring hits edge
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.32),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                    ],
                    relativeTime: 0.46,
                    duration: 0.55
                ),
            ]

        case .errorStab:
            [
                transient(at: 0, intensity: 0.95, sharpness: 0.4),
                transient(at: 0.015, intensity: 1.0, sharpness: 1.0),
            ]

        case .destructiveWarn:
            [
                transient(at: 0.0, intensity: 0.5, sharpness: 0.6),
                transient(at: 0.2, intensity: 0.7, sharpness: 0.7),
                transient(at: 0.4, intensity: 0.9, sharpness: 0.8),
            ]

        case .consoleCommit:
            [transient(at: 0, intensity: 0.6, sharpness: 0.95)]

        case .consolePulse:
            // A hard double thump with a short decaying swell — pairs with the
            // rainbow border pulse when a command run lands.
            [
                transient(at: 0.0, intensity: 1.0, sharpness: 0.7),
                transient(at: 0.045, intensity: 0.7, sharpness: 0.9),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55),
                    ],
                    relativeTime: 0.02,
                    duration: 0.30
                ),
            ]

        case .dragSnap:
            [transient(at: 0, intensity: 0.45, sharpness: 0.5)]

        case .copyTick:
            // A crisp tap with a brief soft swell — a "lifted off the glass"
            // confirmation that something landed on the clipboard.
            [
                transient(at: 0, intensity: 0.6, sharpness: 0.85),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.22),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                    ],
                    relativeTime: 0.03,
                    duration: 0.12
                ),
            ]

        case .tapTick:
            // A single light, crisp tick — the press of a button or tile.
            [transient(at: 0, intensity: 0.5, sharpness: 0.75)]

        case .commitThud:
            // A weightier tap with a short low swell behind it — the "meaty"
            // landing of a committed action (save, add, load).
            [
                transient(at: 0, intensity: 0.85, sharpness: 0.55),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45),
                    ],
                    relativeTime: 0.02,
                    duration: 0.14
                ),
            ]
        }
    }

    private func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    private func tickTrain(start: TimeInterval, count: Int, gap: TimeInterval, intensity: Float,
                           sharpness: Float) -> [CHHapticEvent]
    {
        (0 ..< count).map { transient(at: start + Double($0) * gap, intensity: intensity, sharpness: sharpness) }
    }
}
#endif
