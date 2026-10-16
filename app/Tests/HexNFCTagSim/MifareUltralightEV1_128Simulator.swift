import Foundation
@testable import HexNFCKit

/// MIFARE Ultralight EV1, 128-byte (MF0UL2101) variant.
///
/// Same command set as `MifareUltralightEV1_48Simulator` — the only
/// observable differences are the GET_VERSION storage byte (`0x0E` → 128
/// user bytes) and the larger NDEF / page footprint.
public final class MifareUltralightEV1_128Simulator: NTAG21xSimulator, @unchecked Sendable {
    public init(
        uid: Data = MifareUltralightEV1_128Simulator.defaultUID,
        ndefMessage: Data? = nil,
        virgin: Bool = false
    ) {
        super.init(
            variant: .mifareUltralightEV1_128,
            profile: ChipCatalog.require(.mifareUltralightEV1_128),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data((0 ..< 32).map { UInt8($0 ^ 0x4C) }),
            virgin: virgin
        )
    }

    override public func versionBlock() -> Data {
        Data([0x00, 0x04, 0x03, 0x01, 0x01, 0x00, 0x0E, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0x4C, 0x4C, 0x4C, 0x4C, 0x4C, 0x48])
}
