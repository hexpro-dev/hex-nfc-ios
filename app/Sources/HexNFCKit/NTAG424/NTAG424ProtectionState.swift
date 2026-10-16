import Foundation
import HexNFCRecords

/// Everything a **plain, unauthenticated** probe can learn about an NTAG424
/// DNA's NDEF-file protection.
///
/// Read by `NTAG424ProtectionDriver.readState(keySlot:)` before any
/// authentication, for the same reason `Type2PasswordDriver.readState` runs
/// first on a Type-2 chip: an operation that offers a credential before it has
/// asked what the tag is gating is guessing, and the guess this driver used to
/// make was always "the factory all-zero key".
struct NTAG424ProtectionState: Hashable, Sendable {
    /// `RW | Change | R | W` nibbles, exactly as `getFileSettings` returns them.
    let accessRights: UInt16
    /// File comm mode: 0 plain, 1 MAC, 3 full.
    let commMode: UInt8
    /// Key version for the slot asked about, or `nil` when the chip did not
    /// answer `GetKeyVersion` with `91 00`.
    ///
    /// `nil` is **not** an error and must never be read as "factory". It means
    /// unverified, and every decision that matters is made by an authentication
    /// succeeding rather than by this byte.
    let keyVersion: UInt8?

    /// `true` when reads or writes are gated behind a key.
    var isGated: Bool {
        let write = accessRights & 0x0F
        let read = (accessRights >> 4) & 0x0F
        return write != NTAG424ProtectionDriver.freeNibble || read != NTAG424ProtectionDriver.freeNibble
    }

    /// `true` when the Change nibble is free (`0xE`), the one state in which the
    /// file accepts **only** a plain (unencrypted, unauthenticated)
    /// ChangeFileSettings and refuses the Full-mode one with `91 9E`.
    var changeNibbleIsFree: Bool {
        ((accessRights >> 8) & 0x0F) == NTAG424ProtectionDriver.freeNibble
    }

    /// The key slot the Write nibble names, or `nil` when writes are free.
    var writeKeySlot: Int? {
        let write = accessRights & 0x0F
        guard write != NTAG424ProtectionDriver.freeNibble else { return nil }
        return Int(write)
    }

    /// The family-agnostic projection, so a caller comparing "before" and
    /// "after" does not have to decode nibbles twice.
    var protection: TagProtection {
        NTAG424ProtectionDriver.interpret(accessRights: accessRights)
    }
}

/// Key-version bytes this app writes, so a later tap can tell a tag it
/// personalised from one at delivery.
///
/// A version is a **hint, never proof**. Another tool can program a key and
/// leave the version at `0x00`, and the chip does not stop it. This byte only
/// orders the candidate list a recovery tap walks, which saves a round trip in
/// the common case and costs nothing in the uncommon one.
///
/// `factory` is the value a delivered tag reports (NT4H2421Gx rev 3.2 §9: all
/// five keys are the all-zero AES-128 key at delivery) and the value `disable`
/// writes back. `appProgrammed` is what `enable` writes with a user key, which
/// this driver has emitted since before the value was ever read.
enum NTAG424KeyVersion {
    static let factory: UInt8 = 0x00
    static let appProgrammed: UInt8 = 0x01
}
