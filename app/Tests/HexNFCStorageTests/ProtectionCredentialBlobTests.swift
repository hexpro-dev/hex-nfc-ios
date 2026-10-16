@testable import HexNFCStorage
import XCTest

/// Guards the Keychain blob format: a bare 6-byte legacy blob must still decode
/// as Type-2, and the tagged forms for all three families must round-trip without
/// colliding with the legacy length.
final class ProtectionCredentialBlobTests: XCTestCase {
    func test_decodesLegacy6ByteBlob_asType2() {
        let legacy = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x12, 0x34]) // PWD(4) ++ PACK(2)
        let cred = ProtectionCredentialBlob.decode(legacy)
        guard case .type2(let pwd, let pack)? = cred?.material else {
            return XCTFail("legacy 6-byte blob must decode as .type2")
        }
        XCTAssertEqual(pwd, Data([0xCA, 0xFE, 0xBA, 0xBE]))
        XCTAssertEqual(pack, Data([0x12, 0x34]))
    }

    func test_type2_roundTrips_andIsNeverSixBytes() {
        let cred = ProtectionCredential(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        let blob = ProtectionCredentialBlob.encode(cred)
        XCTAssertNotEqual(blob.count, 6, "tagged Type-2 must not be 6 bytes (would alias legacy)")
        XCTAssertEqual(blob.count, 8)
        XCTAssertEqual(ProtectionCredentialBlob.decode(blob), cred)
    }

    func test_type4_roundTrips() {
        let key = Data((0 ..< 16).map { UInt8($0) })
        let cred = ProtectionCredential(aesKey: key, keySlot: 1)
        let blob = ProtectionCredentialBlob.encode(cred)
        let back = ProtectionCredentialBlob.decode(blob)
        guard case .type4(let aesKey, let slot)? = back?.material else {
            return XCTFail("expected .type4")
        }
        XCTAssertEqual(aesKey, key)
        XCTAssertEqual(slot, 1)
    }

    func test_type5_writeOnly_roundTrips() {
        let cred = ProtectionCredential(slixWrite: Data([0xAA, 0xBB, 0xCC, 0xDD]), slixRead: nil)
        let back = ProtectionCredentialBlob.decode(ProtectionCredentialBlob.encode(cred))
        guard case .type5(let write, let read)? = back?.material else {
            return XCTFail("expected .type5")
        }
        XCTAssertEqual(write, Data([0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertNil(read)
    }

    func test_type5_readAndWrite_roundTrips() {
        let cred = ProtectionCredential(slixWrite: Data([1, 1, 1, 1]), slixRead: Data([2, 2, 2, 2]))
        let back = ProtectionCredentialBlob.decode(ProtectionCredentialBlob.encode(cred))
        guard case .type5(let write, let read)? = back?.material else {
            return XCTFail("expected .type5")
        }
        XCTAssertEqual(write, Data([1, 1, 1, 1]))
        XCTAssertEqual(read, Data([2, 2, 2, 2]))
    }

    func test_garbageBlob_returnsNil() {
        XCTAssertNil(ProtectionCredentialBlob.decode(Data([0x99, 0x00]))) // bad version
        XCTAssertNil(ProtectionCredentialBlob.decode(Data([0x01]))) // truncated
        XCTAssertNil(ProtectionCredentialBlob.decode(Data([0x01, 0x04, 0x00]))) // type4 missing key
    }

    func test_inMemoryStore_roundTripsType4() throws {
        let store = InMemoryProtectionCredentialStore()
        let id = UUID()
        let cred = ProtectionCredential(aesKey: Data(repeating: 0xAB, count: 16), keySlot: 2)
        try store.save(cred, for: id)
        XCTAssertEqual(store.load(for: id), cred)
    }
}
