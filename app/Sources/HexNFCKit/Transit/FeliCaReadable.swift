import Foundation

/// A tag that can answer FeliCa "Read Without Encryption" requests.
///
/// This is the narrow transport seam between CoreNFC and the pure transit
/// orchestration (`TransitReader`). The production session conforms its
/// `CoreNFCConnectedTag` to this when it wraps an `NFCFeliCaTag`; the test
/// simulator conforms its connected tag the same way. Neither `TransitReader`
/// nor anything above it touches CoreNFC.
public protocol FeliCaReadable: AnyObject, Sendable {
    /// The FeliCa system code selected during polling (e.g. `0x0003` for the
    /// Japanese transit family).
    var systemCode: UInt16 { get }

    /// The card's 8-byte manufacture ID (IDm).
    var idm: Data { get }

    /// Read a contiguous range of 16-byte blocks from a single service, without
    /// encryption. Implementations are responsible for the FeliCa block-list /
    /// service-list framing and for translating a non-zero status flag into a
    /// thrown `TagError`. Returns one `Data` (16 bytes) per requested block, in
    /// order.
    func readWithoutEncryption(serviceCode: UInt16, blocks: Range<Int>) async throws -> [Data]
}
