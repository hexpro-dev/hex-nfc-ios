import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// A chip simulator presents the same surface a real chip presents to the
/// reader: every interaction goes through `handle(command:)`. Higher-level
/// access (page reads/writes, NDEF I/O) is provided as convenience methods on
/// the simulator itself — chip *behaviour* lives here, the session/protocol
/// layer above is intentionally thin.
///
/// All simulators are reference types so that mutations made by the
/// connected-tag layer (counter ticks, password attempt decrement, lock
/// bytes flipping) are visible to the test that constructed the simulator.
public protocol ChipSimulator: AnyObject {
    var uid: Data { get }
    var profile: ChipProfile? { get }

    /// Raw transceive. Production reads a 7-byte UID and an ATQA / version
    /// block out of this surface during identification; advanced-console
    /// commands hit it directly.
    func handle(command: Data) -> Data

    /// Read a byte-range (page-aligned on Type-2 chips). Returns the bytes
    /// or throws `.lockedPermanent` / `.protocolError` as appropriate.
    func readMemory(range: Range<Int>) throws -> Data

    /// Write bytes. Throws if the target pages are locked or the simulator
    /// is permanently locked.
    func writeMemory(at offset: Int, bytes: Data) throws

    /// Read the on-tag NDEF message, parsing the TLV envelope around it.
    func readNDEF() throws -> Data

    /// Write the NDEF message into the chip's NDEF region, with the
    /// `0x03 length ... 0xFE` TLV envelope. Throws on overflow or lock.
    func writeNDEF(_ message: Data) throws

    /// Provide a 4-byte password; chip returns 2-byte PACK on success.
    func authenticate(password: Data) throws -> Data

    /// Set the PWD/PACK pages.
    func setPassword(_ password: Data, pack: Data) throws

    /// Set the static + dynamic lock bytes. Irreversible.
    func permanentLock() throws

    /// Program PWD/PACK *and* enable protection (ACCESS then AUTH0). Chips
    /// without NTAG21x-style protection inherit the default below and reject it.
    func enablePasswordProtection(
        password: Data,
        pack: Data,
        protectFromPage: Int,
        readProtect: Bool,
        authLimit: Int
    ) throws

    /// Authenticate with the current password, then clear protection back to
    /// factory defaults (AUTH0 = 0xFF, PROT/AUTH_LIM cleared, PWD/PACK reset).
    func disablePasswordProtection(currentPassword: Data) throws

    /// Report the live AUTH0 / ACCESS state as `TagProtection` settings, or nil
    /// for chips without NTAG21x-style protection. Mirrors the production
    /// `CoreNFCConnectedTag.readProtectionState`.
    func readProtectionState() throws -> TagProtection?

    /// Drop everything that belongs to one activation rather than to the chip:
    /// the authentication state and the HALT flag.
    ///
    /// A real tag is re-selected from IDLE at every tap. It is unauthenticated
    /// and awake, whatever happened in the previous session. `SimulatedSession`
    /// used to hand out the *same* simulator with none of that cleared, so a
    /// test that authenticated once stayed authenticated for every later "tap",
    /// and a chip halted by a refusal woke up on its own. Multi-session flow
    /// tests were therefore checking a tag more permissive than any real one:
    /// they could not have caught a removal that left read protection behind,
    /// because their later sessions never needed the password in the first
    /// place.
    ///
    /// Chips with no such state inherit the default and do nothing.
    func beginActivation()
}

public extension ChipSimulator {
    func beginActivation() {}

    func enablePasswordProtection(
        password: Data,
        pack: Data,
        protectFromPage: Int,
        readProtect: Bool,
        authLimit: Int
    ) throws {
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "enablePasswordProtection unsupported on \(profile?.id.description ?? "unknown")"
        )
    }

    func disablePasswordProtection(currentPassword: Data) throws {
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "disablePasswordProtection unsupported on \(profile?.id.description ?? "unknown")"
        )
    }

    func readProtectionState() throws -> TagProtection? {
        nil
    }
}
