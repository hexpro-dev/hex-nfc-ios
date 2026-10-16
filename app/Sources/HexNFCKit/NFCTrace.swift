import Foundation
import os

/// Process-wide live trace of NFC traffic — every command/response that crosses
/// the `CoreNFCSession` boundary, plus the identification probes, lands here.
///
/// Two consumers read it:
///   1. **On a tethered Mac**, via `idevicesyslog` / Console.app — each event is
///      emitted to `os.Logger` (subsystem `pro.hex.nfc`, category `apdu`) with a
///      `[HEXNFC]` sentinel and **`.public`** privacy, so it shows un-redacted
///      *without* Apple's NFC sysdiagnose profile (it's our own process, so we
///      own the privacy qualifier). `nfcd`'s lower-level RF/anticollision lines
///      still need that profile; ours do not.
///   2. **In the app**, via `events()` / `snapshot()` — the Advanced Console's
///      live-trace tab renders the same stream through `HexConsole`.
///
/// ## Secrets
/// Type-2 password material — the 4-byte PWD and 2-byte PACK — is a
/// Keychain-only secret per `CLAUDE.md`; it must never reach a log, an export,
/// or the screen. Frames that carry it (`PWD_AUTH`, and writes to the PWD/PACK
/// pages) are recorded with the payload masked to `‹redacted N B›` in *both* the
/// os_log line and the in-memory buffer. The opcode is kept on the TX side so a
/// reader can still see *that* an authentication happened, never the credential.
///
/// All recording is thread-safe: frames are logged from the NFC session's
/// `DispatchQueue`, not the main thread.
public final class NFCTrace: @unchecked Sendable {
    /// Shared process-wide sink. Production wires every CoreNFC frame here.
    public static let shared = NFCTrace()

    /// One line in the trace — a TX frame, an RX frame, a note, or an error.
    public struct Event: Identifiable, Hashable, Sendable {
        public enum Direction: String, Hashable, Sendable {
            case tx
            case rx
            case note
            case error

            /// Glyph mirroring `HexConsoleEntry.prefixSymbol`, so the os_log
            /// transcript reads the way the in-app console looks.
            public var symbol: String {
                switch self {
                case .tx: "→ TX"
                case .rx: "← RX"
                case .note: "•"
                case .error: "!"
                }
            }
        }

        public let id: UUID
        public let timestamp: Date
        public let direction: Direction
        public let label: String?
        /// Colon-delimited hex for `tx`/`rx`, or a message for `note`/`error`.
        public let body: String
        /// Frame length in bytes for `tx`/`rx`, `nil` otherwise.
        public let byteCount: Int?

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            direction: Direction,
            label: String? = nil,
            body: String,
            byteCount: Int? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.direction = direction
            self.label = label
            self.body = body
            self.byteCount = byteCount
        }
    }

    private let logger = Logger(subsystem: "pro.hex.nfc", category: "apdu")
    private let lock = NSLock()
    private var buffer: [Event] = []
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private let capacity: Int
    private var _isEnabled = true

    /// Master switch. Defaults on; flip off to silence tracing entirely.
    public var isEnabled: Bool {
        get { lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set { lock.lock()
            _isEnabled = newValue
            lock.unlock()
        }
    }

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    // MARK: - Recording

    /// Record a transmitted frame. Pass `secret: true` for credential-bearing
    /// frames (PWD_AUTH, PWD/PACK writes) to mask the payload everywhere.
    public func tx(_ label: String?, _ bytes: Data, secret: Bool = false) {
        record(.tx, label: label,
               body: secret ? Self.redacted(bytes, keepingOpcode: true) : bytes.hexString,
               byteCount: bytes.count)
    }

    /// Record a received frame.
    public func rx(_ label: String?, _ bytes: Data, secret: Bool = false) {
        record(.rx, label: label,
               body: secret ? Self.redacted(bytes, keepingOpcode: false)
                   : (bytes.isEmpty ? "(empty)" : bytes.hexString),
               byteCount: bytes.count)
    }

    /// Record a context note (tag connected, profile resolved, …).
    public func note(_ message: String, label: String? = nil) {
        record(.note, label: label, body: message, byteCount: nil)
    }

    /// Record a failure line.
    public func failure(_ message: String, label: String? = nil) {
        record(.error, label: label, body: message, byteCount: nil)
    }

    private func record(_ direction: Event.Direction, label: String?, body: String, byteCount: Int?) {
        lock.lock()
        guard _isEnabled else { lock.unlock()
            return
        }
        let event = Event(direction: direction, label: label, body: body, byteCount: byteCount)
        buffer.append(event)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        let sinks = Array(continuations.values)
        lock.unlock()

        for sink in sinks {
            sink.yield(event)
        }
        emit(event)
    }

    private func emit(_ event: Event) {
        let label = event.label.map { " \($0)" } ?? ""
        let line = "[HEXNFC] \(event.direction.symbol)\(label) \(event.body)"
        switch event.direction {
        case .error: logger.error("\(line, privacy: .public)")
        default: logger.log("\(line, privacy: .public)")
        }
    }

    // MARK: - Consumption

    /// A live stream of events from the moment of subscription. The stream
    /// finishes (and detaches its continuation) when the consuming task ends.
    public func events() -> AsyncStream<Event> {
        AsyncStream(Event.self, bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    /// Buffered events, oldest first — for seeding a freshly-presented view.
    public func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Redaction

    /// Mask a secret-bearing frame, preserving its byte count. For a command we
    /// keep the opcode byte so the trace still shows *what* happened (e.g. `1B`
    /// for PWD_AUTH); for a response we mask everything.
    private static func redacted(_ bytes: Data, keepingOpcode: Bool) -> String {
        guard !bytes.isEmpty else { return "(empty)" }
        if keepingOpcode, let opcode = bytes.first {
            let hidden = bytes.count - 1
            let tail = hidden > 0 ? " ‹redacted \(hidden) B›" : ""
            return String(format: "%02X", opcode) + tail
        }
        return "‹redacted \(bytes.count) B›"
    }
}
