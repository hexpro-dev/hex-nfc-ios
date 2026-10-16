import Foundation
import HexNFCKit
import HexNFCStorage

/// Translates between the kit's in-flight credential type and the storage
/// layer's persisted one.
///
/// The two are deliberately separate types: `HexNFCKit` must not depend on
/// `HexNFCStorage`, so the App is the only place that knows both. This file is
/// that place, and it is the only one.
extension TagCredential {
    /// The persistable form of this credential.
    var material: ProtectionCredential.Material {
        switch self {
        case .type2(let password, let pack):
            .type2(password: password, pack: pack)

        case .type4(let aesKey, let keySlot):
            .type4(aesKey: aesKey, keySlot: UInt8(keySlot & 0xFF))

        case .type5(let password, _):
            // One slot only. `TagCredential.type5` carries a single password for
            // what the chip treats as two, so the write slot is the one that is
            // certain. Recorded as such rather than guessed into both.
            .type5(write: password, read: nil)

        case .ultralightC(let key):
            .ultralightC(key: key.cipherOrder)
        }
    }
}

extension ProtectionCredential.Material {
    /// The in-flight form, or `nil` where the stored bytes cannot make a usable
    /// credential (a Type-5 record holding only a read password, say).
    var credential: TagCredential? {
        switch self {
        case .type2(let password, let pack):
            .type2(password: password, pack: pack)

        case .type4(let aesKey, let keySlot):
            .type4(aesKey: aesKey, keySlot: Int(keySlot))

        case .type5(let write, _):
            write.map { TagCredential.type5(password: $0, kind: .write) }

        case .ultralightC(let key):
            // A stored blob of the wrong length cannot make a key. Report that as
            // "no usable credential" rather than throwing: a malformed record must
            // not stop the caller reading the other candidates.
            (try? UltralightCKey(cipherOrder: key)).map { TagCredential.ultralightC(key: $0) }
        }
    }
}
