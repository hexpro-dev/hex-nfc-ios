import Foundation

/// The narrow seam `EPassportReader` needs from a connected tag: its UID and the
/// ability to exchange one ISO 7816 command APDU. Keeping this minimal (and free
/// of CoreNFC) is what lets the reader run identically against a live
/// `CoreNFCConnectedTag` and a `SimulatedConnectedTag` in tests — the same split
/// the transit path uses with `FeliCaReadable`.
public protocol EPassportReadable: AnyObject, Sendable {
    /// The tag UID. Passports randomise this per tap, so it is not a stable
    /// identifier — used only for diagnostics.
    var uid: Data { get }

    /// Send one command APDU and return the raw response as `data ‖ SW1 ‖ SW2`.
    func sendAPDU(_ command: Data) async throws -> Data
}
