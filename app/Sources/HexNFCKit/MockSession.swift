import Foundation
import HexNFCRecords

/// Lightweight in-process mock used by XCUITest under `--useSimulatedNFC`.
/// Unlike the chip-accurate simulators in `HexNFCTagSim` (which are test-only
/// and not linked into the shipping app), this mock has no per-chip fidelity —
/// it returns canned NDEF data and lets the UI flow through.
///
/// The shipping app must never call this in production. It's gated on a
/// launch argument in the app target's `ContentView`.
public final class MockTagSession: TagSession, @unchecked Sendable {
    public let scripted: [NDEFRecord]
    private var didInvalidate = false
    public private(set) var alertHistory: [String] = []

    public init(scripted: [NDEFRecord] = []) {
        self.scripted = scripted
    }

    public func start(alert: String) async throws -> ConnectedTag {
        alertHistory.append(alert)
        // Faux polling delay so the scan animation has time to settle into
        // the .polling phase before transitioning.
        try? await Task.sleep(nanoseconds: 250_000_000)
        return MockConnectedTag(records: scripted)
    }

    public func updateAlert(_ alert: String) async {
        alertHistory.append(alert)
    }

    public func invalidate(error: String?) async {
        didInvalidate = true
    }
}

public final class MockConnectedTag: ConnectedTag, @unchecked Sendable {
    public let uid: Data = .init([0x04, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
    public let chip: ChipProfile? = nil
    public let capabilities: TagCapability = [.ndefRead, .ndefWrite]
    private var records: [NDEFRecord]

    public init(records: [NDEFRecord]) {
        self.records = records
    }

    public func readNDEF() async throws -> Data {
        try await Task.sleep(nanoseconds: 200_000_000)
        return try NDEFCodec.encode(records)
    }

    public func writeNDEF(_ records: [NDEFRecord]) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        self.records = records
    }

    public func transceive(_ command: RawCommand) async throws -> Data {
        Data()
    }

    public func readMemory(range: Range<Int>) async throws -> Data {
        Data()
    }

    public func writeMemory(at offset: Int, bytes: Data) async throws {}

    // No credential or lock methods here on purpose. This mock used to answer
    // `authenticate`, `setPassword` and `permanentLock` from memory, which is the
    // shape that let four writes strand a real NTAG213 on 2026-09-04: an
    // operation answered by a conformer is an operation that never reaches the
    // wire. Two of the three were worse than a shadow, because they returned
    // `Void` where the extension defaults return `ProtectionResidue` and
    // `PermanentLockOutcome`, so which one ran depended on the call's context.
    // The extension defaults now apply, and they route through `transceive`.
    // `.github/scripts/check-shipped-frames.sh` fails the build if they come
    // back.
}

public final class MockTagSessionFactory: TagSessionFactory, @unchecked Sendable {
    private let scripted: [NDEFRecord]
    public init(scripted: [NDEFRecord] = []) {
        self.scripted = scripted
    }

    public func makeSession() -> TagSession {
        MockTagSession(scripted: scripted)
    }
}
