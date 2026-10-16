import Foundation
@testable import HexNFCKit

/// NTAG213 TT — physically identical to NTAG213 except for an anti-tamper
/// loop wired between two pads on the IC. The loop's continuity is
/// reported through opcode `0xA4` (`READ_TT_STATUS`) which returns a
/// 4-byte response: `00 00 00 00` when the loop is intact, the customer-
/// programmed `TT_MESSAGE` page bytes once it has been opened.
///
/// Datasheet: NXP NT2H1311TT Rev 1.1.
///
/// `tamperStatus` on the base class is the simulator's semantic flag
/// (`0x55` = intact, `0xAA` = broken) — tests flip it directly to drive
/// the broken-loop branch. The actual 4-byte wire response is composed
/// in the base class's opcode dispatch.
public final class NTAG213TTSimulator: NTAG21xSimulator, @unchecked Sendable {
    public init(uid: Data = NTAG213TTSimulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .ntag213TT,
            profile: ChipCatalog.require(.ntag213TT),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data((0 ..< 32).map { UInt8($0 ^ 0x77) })
        )
    }

    /// NTAG213 TT GET_VERSION: product=04, subType=05, storage=0F.
    override public func versionBlock() -> Data {
        Data([0x00, 0x04, 0x04, 0x05, 0x01, 0x00, 0x0F, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77])
}
