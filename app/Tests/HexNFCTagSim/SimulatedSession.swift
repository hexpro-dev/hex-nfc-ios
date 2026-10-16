import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// Drives a `ChipSimulator` through the `TagSession` / `ConnectedTag`
/// protocols. The harness has the same shape a CoreNFC-backed session has,
/// so consumers can be tested end-to-end without an entitled NFC session.
public final class SimulatedSession: TagSession, @unchecked Sendable {
    public enum Behaviour: Sendable {
        case ready
        case tagLost
        /// The session's time limit passed with nothing in the field.
        case timeout
        /// The user closed the system sheet with nothing in the field.
        case cancelled
        /// The user closed the system sheet after a tag had been detected and
        /// before it was handed up.
        ///
        /// What CoreNFC does when the cancel lands while identification is
        /// running: `didDetect` has fired, the tag has answered its probe
        /// frames, and then the session is invalidated with the user-cancel
        /// code, so `start` throws the same `sessionCancelled` as `.cancelled`.
        /// The difference is the one fact the session holds and the caller
        /// cannot see: a tag was in the field, so the error does not carry
        /// `endedBeforeAnyTag`. No tag response is modelled, because none
        /// reaches the caller.
        case cancelledAfterDetection
        /// The timeout counterpart of `.cancelledAfterDetection`: the session's
        /// time limit passed while a detected tag was still being identified.
        case timedOutAfterDetection
    }

    public let simulator: ChipSimulator
    public let behaviour: Behaviour
    public private(set) var alertHistory: [String] = []
    public private(set) var invalidationError: String?
    public private(set) var didInvalidate = false

    public init(chip: ChipSimulator, behaviour: Behaviour = .ready) {
        simulator = chip
        self.behaviour = behaviour
    }

    public func start(alert: String) async throws -> ConnectedTag {
        alertHistory.append(alert)
        switch behaviour {
        case .ready:
            // A new session is a new activation: the tag comes back from IDLE
            // unauthenticated and awake. See `ChipSimulator.beginActivation`.
            simulator.beginActivation()
            return SimulatedConnectedTag(simulator: simulator)

        case .tagLost:
            throw TagError.tagLost(diagnostics: "simulator behaviour=tagLost")

        // Both throw before anything is in the field, so the session can vouch
        // for that, exactly as `CoreNFCSession` does when `didDetect` never fired.
        case .timeout:
            throw TagError.sessionTimeout(diagnostics: "simulator behaviour=timeout").endingBeforeAnyTag()

        case .cancelled:
            throw TagError.sessionCancelled(diagnostics: "simulator behaviour=cancelled").endingBeforeAnyTag()

        // A tag was detected, so it was activated, and the session cannot say
        // it saw nothing.
        case .cancelledAfterDetection:
            simulator.beginActivation()
            throw TagError.sessionCancelled(diagnostics: "simulator behaviour=cancelledAfterDetection")

        case .timedOutAfterDetection:
            simulator.beginActivation()
            throw TagError.sessionTimeout(diagnostics: "simulator behaviour=timedOutAfterDetection")
        }
    }

    public func updateAlert(_ alert: String) async {
        alertHistory.append(alert)
    }

    public func invalidate(error: String?) async {
        didInvalidate = true
        invalidationError = error
    }
}

/// Adapter from `ChipSimulator` (the test surface) to `ConnectedTag` (the
/// production surface). Forwards everything to the simulator, translating
/// errors into the public `TagError` shape.
public final class SimulatedConnectedTag: ConnectedTag, @unchecked Sendable {
    public let simulator: ChipSimulator

    public init(simulator: ChipSimulator) {
        self.simulator = simulator
    }

    public var uid: Data {
        simulator.uid
    }

    public var chip: ChipProfile? {
        simulator.profile
    }

    public var capabilities: TagCapability {
        simulator.profile?.capabilities ?? []
    }

    /// Live NTAG424 EV2 session — mirrors `CoreNFCConnectedTag.ev2Session`, so an
    /// authenticated 424 routes its NDEF I/O through the driver (over `transceive`
    /// → `simulator.handle`), exercising the simulator's access-rights + secure-
    /// messaging enforcement exactly as a real chip would.
    public let ev2Session = EV2SessionHolder()
    public let ultralightCSession = UltralightCSessionHolder()
    /// Type-2 `PWD_AUTH` state, the sibling of the two above.
    ///
    /// This tag deliberately implements **none** of the Type-2 credential
    /// methods any more. They were a parallel implementation of the shipped
    /// sequence: `disableProtection` landed in the simulator's in-memory model
    /// instead of in the frame builder, so the four writes that stranded a real
    /// NTAG213 on 2026-09-04 had never once executed in CI. Everything now goes
    /// through `Type2PasswordDriver` over `transceive`, so the simulator answers
    /// the same frames production sends. The same-named methods that survive on
    /// the concrete simulators are seed-and-assert helpers for tests, never a
    /// production path.
    public let type2Session = Type2SessionHolder()

    public func readNDEF() async throws -> Data {
        if chip?.id == .ntag424DNA, let driver = ev2Session.driver, driver.isAuthenticated {
            return try await driver.readNDEFFile()
        }
        let raw = try simulator.readNDEF()
        // Mirror CoreNFC: the real read does NOT echo the on-tag bytes verbatim —
        // it reparses the message into records and re-encodes them
        // (`CoreNFCConnectedTag.readNDEF` → `encodePayloads`). So the bytes the app
        // sees are a *normalized* re-encoding, not whatever was physically written.
        // Reproduce that normalization here, otherwise a write→read-back→verify
        // round-trip is tautological in tests (it compares `encode(records)` with
        // itself) and can pass while differing on real hardware — which is exactly
        // how the empty-message (`D0 00 00`) bug slipped through. Bytes that don't
        // parse as a valid NDEF message (already empty, etc.) pass through unchanged.
        guard !raw.isEmpty, let payloads = try? NDEFCodec.decodePayloads(raw) else { return raw }
        return NDEFCodec.encodePayloads(payloads)
    }

    public func writeNDEF(_ records: [NDEFRecord]) async throws {
        if chip?.id == .ntag424DNA, let driver = ev2Session.driver, driver.isAuthenticated {
            try await driver.writeNDEFFile(records)
            return
        }
        // Mirror CoreNFC: an empty NDEF message is serialised as a single Empty
        // record (TNF 0x00) — `D0 00 00` — per the NFC Forum spec, not as zero
        // bytes. `encode([])` gives zero bytes, so substitute the Empty record
        // here; otherwise a simulated "clear the tag" read-back wouldn't match
        // what real hardware echoes, and tests would miss it.
        let message = records.isEmpty
            ? Data([0xD0, 0x00, 0x00])
            : try NDEFCodec.encode(records)
        let envelope = NDEFEnvelope.wrap(message: message)
        try simulator.writeNDEF(envelope)
    }

    public func transceive(_ command: RawCommand) async throws -> Data {
        // A Type-2 chip halted by an earlier refusal answers nothing, and CoreNFC
        // reports that as the session gone. Every frame the 2026-09-10 trace shows
        // after a refusal drew "Tag connection lost" in about 310 ms, after both
        // refusal forms, and none drew a byte. The simulators answered `00`
        // instead, which a driver reads as a fresh refusal, so a halted tag looked
        // gated rather than silent.
        //
        // Checked before `handle`, so the refusing frame keeps its own one-byte
        // answer: which form a refusal arrives in is still recorded rather than
        // encoded. Tests that call a simulator's `handle` directly keep the `00`.
        if Self.isHaltedType2(simulator) {
            throw TagError.tagLost(diagnostics: "chip is halted by an earlier refusal; no answer until re-activation")
        }
        let response = simulator.handle(command: command.bytes)
        // ISO 15693 has no NAK: a frame the tag does not process draws no
        // response at all. The Type-5 simulator models that as an empty reply
        // (wrong addressing mode on a gated command, or the invalid-password
        // lockout), and production surfaces the same silence as `tagLost`
        // (`CoreNFCSession.iso15693Failure`) — so mirror it here, or a frame
        // real silicon ignores would look like a zero-byte *answer* in CI.
        // Scoped to the Type-5 simulator: the Type-2 sims speak in NAKs and
        // use their own halt modelling.
        if response.isEmpty, simulator is Iso15693Simulator {
            throw TagError.tagLost(
                diagnostics: "ISO 15693: simulator drew no response — frame ignored "
                    + "(gated command outside Addressed/Selected mode, or POR pending after an invalid password)"
            )
        }
        return response
    }

    private static func isHaltedType2(_ simulator: ChipSimulator) -> Bool {
        if let ntag = simulator as? NTAG21xSimulator {
            return ntag.isHalted
        }
        if let ultralightC = simulator as? MifareUltralightCSimulator {
            return ultralightC.isHalted
        }
        return false
    }

    public func readMemory(range: Range<Int>) async throws -> Data {
        try simulator.readMemory(range: range)
    }

    public func writeMemory(at offset: Int, bytes: Data) async throws {
        try simulator.writeMemory(at: offset, bytes: bytes)
    }
}

/// Factory that vends `SimulatedSession`s. Wire this into `AppModel` from
/// XCUITest with `--useSimulatedNFC`.
public final class SimulatedSessionFactory: TagSessionFactory, @unchecked Sendable {
    private let makeChip: @Sendable () -> ChipSimulator
    public init(makeChip: @escaping @Sendable () -> ChipSimulator) {
        self.makeChip = makeChip
    }

    /// Every session over the **same** chip, so state carries across taps the way
    /// it does on one physical tag.
    ///
    /// The `makeChip:` form vends a *fresh* chip per session, which is the
    /// opposite of what a multi-session test wants, and three test files had each
    /// re-invented this convenience privately as a one-off factory class.
    public convenience init(chip: ChipSimulator) {
        self.init(makeChip: { chip })
    }

    public func makeSession() -> TagSession {
        SimulatedSession(chip: makeChip())
    }
}

// MARK: - NDEF TLV envelope

/// The Type-2 NDEF TLV envelope, as the shipped parser implements it.
///
/// This used to be a second, byte-identical implementation of
/// `Type2NDEF.wrap`/`unwrap`, which is precisely the shape CLAUDE.md names as
/// the defect: "a parallel in-memory implementation of a shipped sequence is
/// the defect, not a convenience". It behaved as a copy always eventually
/// behaves. When `Type2NDEF.unwrap` was fixed on 2026-09-09 to skip a reserved
/// TLV by its length rather than by one byte, this copy kept the old walk, so
/// the simulators would have gone on reading a 160-byte message out of the very
/// bytes that fix exists to handle, and every test built on them would have
/// agreed.
///
/// Kept as a name rather than deleted outright because a dozen call sites spell
/// it, and the name reads better at those sites than the shipped type's does.
/// It forwards, and it holds no logic of its own.
public enum NDEFEnvelope {
    public typealias ParseError = Type2NDEF.ParseError

    public static func wrap(message: Data) -> Data {
        Type2NDEF.wrap(message: message)
    }

    public static func unwrap(_ memory: Data) throws -> Data {
        try Type2NDEF.unwrap(memory)
    }
}
