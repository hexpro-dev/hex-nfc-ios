import Foundation
@testable import HexNFCKit

public final class NTAG213Simulator: NTAG21xSimulator, @unchecked Sendable {
    public init(uid: Data = NTAG213Simulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .ntag213,
            profile: ChipCatalog.require(.ntag213),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data((0 ..< 32).map { UInt8($0 ^ 0x13) })
        )
    }

    override public func versionBlock() -> Data {
        // NTAG213: product=04, subType=02, storage size=0F
        Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13])
}

public final class NTAG216Simulator: NTAG21xSimulator, @unchecked Sendable {
    public init(uid: Data = NTAG216Simulator.defaultUID, ndefMessage: Data? = nil) {
        super.init(
            variant: .ntag216,
            profile: ChipCatalog.require(.ntag216),
            uid: uid,
            ndefMessage: ndefMessage,
            signature: Data((0 ..< 32).map { UInt8($0 ^ 0x16) })
        )
    }

    override public func versionBlock() -> Data {
        // NTAG216: product=04, subType=02, storage size=13
        Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03])
    }

    public static let defaultUID: Data = .init([0x04, 0x16, 0x16, 0x16, 0x16, 0x16, 0x16])
}
