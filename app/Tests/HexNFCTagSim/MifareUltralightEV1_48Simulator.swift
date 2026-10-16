import Foundation
@testable import HexNFCKit

/// MIFARE Ultralight EV1, 48-byte (MF0UL1101) variant.
///
/// Datasheet: NXP MF0UL1101 rev 3.3. The EV1 silicon is a Type-2 superset
/// of NTAG, sharing the read/write/PWD_AUTH opcodes — added on top:
///
///   - Three independent 24-bit counters (`CNT0..2`) handled by the base
///     class via the `nfcCounters` array. NTAG ticks counter 0 on every
///     read; EV1 counters change only via `INCR_CNT`.
///   - `0xA5` `INCR_CNT <index> <3B LE value>` — base class handles this
///     when `isMifareUltralightEV1 == true`.
///   - `0x1A` legacy 3DES `AUTHENTICATE` — the simulator returns a canned
///     NAK; tests document the limitation.
///   - `0x3E` `CHECK_TEARING_EVENT <index>` — 1 byte, `0xBD` when clean.
///
/// Unlike NTAG21x, EV1 ships **without** an NDEF Capability Container: page 3
/// (OTP) is blank from the factory. Pass `virgin: true` for that state.
///
/// GET_VERSION subType `0x01`, storage size `0x0B` → 48 user bytes.
public final class MifareUltralightEV1_48Simulator: NTAG21xSimulator, @unchecked Sendable {
    public init(
        uid: Data = MifareUltralightEV1_48Simulator.defaultUID,
        ndefMessage: Data? = nil,
        virgin: Bool = false
    ) {
        super.init(
            variant: .mifareUltralightEV1_48,
            profile: ChipCatalog.require(.mifareUltralightEV1_48),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data((0 ..< 32).map { UInt8($0 ^ 0x4B) }),
            virgin: virgin
        )
    }

    override public func versionBlock() -> Data {
        Data([0x00, 0x04, 0x03, 0x01, 0x01, 0x00, 0x0B, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0x4B, 0x4B, 0x4B, 0x4B, 0x4B, 0x48])
}
