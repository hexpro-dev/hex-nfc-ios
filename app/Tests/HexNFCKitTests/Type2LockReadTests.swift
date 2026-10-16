@testable import HexNFCKit
import HexNFCTagSim
import XCTest

/// Drives the **production** lock read against each simulator, and pairs it with
/// the production lock *write* so one shipped sequence proves the other.
///
/// The rule this file guards is the frame budget as much as the verdict: a READ
/// of a page above AUTH0 on a read-protected tag is NAKed, and a NAK returns a
/// Type-2 tag to HALT for the rest of the activation. So "sent no frame" is an
/// assertion here, not an implementation detail.
final class Type2LockReadTests: XCTestCase {
    private final class Wire: @unchecked Sendable {
        private(set) var frames: [Data] = []
        private let respond: (Data) -> Data
        init(_ respond: @escaping (Data) -> Data) {
            self.respond = respond
        }

        func transceive(_ command: RawCommand) -> Data {
            frames.append(command.bytes)
            return respond(command.bytes)
        }

        func reads(page: UInt8) -> Int {
            frames.filter { $0.count >= 2 && $0[$0.startIndex] == 0x30 && $0[$0.startIndex + 1] == page }.count
        }

        var writes: [Data] {
            frames.filter { $0.first == 0xA2 }
        }
    }

    private func driver(_ wire: Wire, uid: Data?) -> Type2LockDriver {
        Type2LockDriver(uid: uid) { wire.transceive($0) }
    }

    private func read(
        _ sim: NTAG21xSimulator, id: ChipID, provenReadablePage: Int?
    ) async throws -> (TagLockReading, Wire) {
        let wire = Wire { sim.handle(command: $0) }
        let profile = try XCTUnwrap(ChipCatalog.profile(for: id))
        let reading = await driver(wire, uid: sim.uid).readLockState(
            layout: profile.memoryLayout,
            family: profile.family,
            provenReadablePage: provenReadablePage
        )
        return (reading, wire)
    }

    // MARK: - Verdicts

    func test_factoryNTAG213_readsAsOpen() async throws {
        let (reading, wire) = try await read(NTAG213Simulator(), id: .ntag213, provenReadablePage: 41)
        XCTAssertEqual(reading.state, .open)
        XCTAssertEqual(reading.regions[.staticLock], .noneSet)
        XCTAssertEqual(reading.regions[.dynamicLock], .noneSet)
        XCTAssertEqual(wire.writes.count, 0, "a lock read never writes")
        XCTAssertEqual(wire.reads(page: 0x02), 1)
        XCTAssertEqual(wire.reads(page: 0x28), 1)
    }

    /// The shipped write proved by the shipped read. `SimulatedConnectedTag` has
    /// no `permanentLock` override, so this drives the real frames both ways.
    func test_lockedThroughTheRealDriver_readsAsLocked() async throws {
        let sim = NTAG213Simulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let lockWire = Wire { sim.handle(command: $0) }
        try await driver(lockWire, uid: sim.uid).permanentLock(
            layout: profile.memoryLayout, family: profile.family, configLayout: nil
        )

        let (reading, _) = try await read(sim, id: .ntag213, provenReadablePage: 41)
        XCTAssertEqual(reading.state, .locked)
    }

    /// NTAG215's mask byte 1 is `0x00` (entirely RFUI). An equality test against
    /// the payload would report a correctly locked NTAG215 as unlocked.
    func test_ntag215_comparesThroughTheMaskNotByEquality() async throws {
        let sim = NTAG215Simulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag215))
        let lockWire = Wire { sim.handle(command: $0) }
        try await driver(lockWire, uid: sim.uid).permanentLock(
            layout: profile.memoryLayout, family: profile.family, configLayout: nil
        )

        let (reading, _) = try await read(sim, id: .ntag215, provenReadablePage: 131)
        XCTAssertEqual(reading.regions[.dynamicLock], .allSet)
        XCTAssertEqual(reading.state, .locked)
    }

    /// Byte 3 of the dynamic lock page is RFUI and an NTAG21x reads it back as
    /// its own `BDh` without ever being written. It must not affect the verdict.
    func test_dynamicLockByte3IsIgnored() async throws {
        let mask = Type2LockWrite.dynamicLockPayload(for: .type2(.ntag213), pageSize: 4)
        XCTAssertEqual(mask, Data([0xFF, 0x0F, 0x3F, 0x00]), "guards the mask this test reasons about")

        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        for (page28, expected) in [
            (Data([0xFF, 0x0F, 0x3F, 0xBD]), TagLockFinding.allSet),
            (Data([0x00, 0x00, 0x00, 0xBD]), TagLockFinding.noneSet),
        ] {
            let wire = Wire { command in
                guard command.count >= 2, command[command.startIndex] == 0x30 else { return Data([0x00]) }
                switch command[command.startIndex + 1] {
                case 0x28: return page28 + Data(repeating: 0x00, count: 12)
                case 0x02: return Data([0x9F, 0x48, 0x00, 0x00]) + Data(repeating: 0x00, count: 12)
                default: return Data([0x00])
                }
            }
            let reading = await Type2LockDriver(uid: nil) { wire.transceive($0) }.readLockState(
                layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41
            )
            XCTAssertEqual(reading.regions[.dynamicLock], expected)
        }
    }

    /// The 2026-09-04 shape, read back off a tag rather than inferred from an
    /// outcome: static burned, dynamic still clear.
    func test_staticBurnedDynamicClear_readsAsPartlyLocked() async throws {
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let wire = Wire { command in
            guard command.count >= 2, command[command.startIndex] == 0x30 else { return Data([0x00]) }
            switch command[command.startIndex + 1] {
            case 0x28: return Data([0x00, 0x00, 0x00, 0xBD]) + Data(repeating: 0x00, count: 12)
            case 0x02: return Data([0x9F, 0x48, 0xFF, 0xFF]) + Data(repeating: 0x00, count: 12)
            default: return Data([0x00])
            }
        }
        let reading = await Type2LockDriver(uid: nil) { wire.transceive($0) }.readLockState(
            layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41
        )
        XCTAssertEqual(reading.state, .partlyLocked)
    }

    func test_partiallySetStaticBytes_readAsSomeSet() async throws {
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let wire = Wire { command in
            guard command.count >= 2, command[command.startIndex] == 0x30 else { return Data([0x00]) }
            switch command[command.startIndex + 1] {
            case 0x28: return Data([0x00, 0x00, 0x00, 0xBD]) + Data(repeating: 0x00, count: 12)
            case 0x02: return Data([0x9F, 0x48, 0x08, 0x00]) + Data(repeating: 0x00, count: 12)
            default: return Data([0x00])
            }
        }
        let reading = await Type2LockDriver(uid: nil) { wire.transceive($0) }.readLockState(
            layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41
        )
        XCTAssertEqual(reading.regions[.staticLock], .someSet)
        XCTAssertEqual(reading.state, .partlyLocked)
    }

    /// NTAG 210u has no dynamic lock page, so it can never report a partial
    /// verdict from a missing region.
    func test_ntag210Micro_reportsTheDynamicRegionAbsent() async throws {
        let sim = NTAG210MicroSimulator()
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag210Micro))
        let wire = Wire { sim.handle(command: $0) }
        let reading = await driver(wire, uid: sim.uid).readLockState(
            layout: profile.memoryLayout, family: profile.family, provenReadablePage: 3
        )
        XCTAssertEqual(reading.regions[.dynamicLock], .notPresent)
        XCTAssertEqual(reading.state, .open)
        XCTAssertEqual(wire.frames.count, 1, "one READ, and none for a page this chip does not have")
    }

    // MARK: - The frame budget

    /// A page above the one this activation has proven readable earns no frame,
    /// because a NAK would halt the chip for the rest of the tap.
    func test_pageAboveTheProvenPage_isNotAddressed() async throws {
        let (reading, wire) = try await read(NTAG213Simulator(), id: .ntag213, provenReadablePage: 3)
        XCTAssertEqual(wire.reads(page: 0x28), 0, "page 40 sits above the proven page")
        XCTAssertEqual(wire.reads(page: 0x02), 1, "page 2 sits below it")
        XCTAssertTrue(reading.regions[.dynamicLock]?.isUnread == true)
        XCTAssertEqual(reading.state, .unknown, "a clear static region is not a whole-tag verdict")
    }

    func test_nilProvenPage_sendsNoFramesAtAll() async throws {
        let (reading, wire) = try await read(NTAG213Simulator(), id: .ntag213, provenReadablePage: nil)
        XCTAssertEqual(wire.frames.count, 0)
        XCTAssertEqual(reading.state, .unknown)
    }

    /// A read-protected chip answers a READ with a roll-over to page 0. Page 2
    /// carries BCC1, so a reply that really is page 2 identifies itself, and one
    /// that does not is refused a verdict rather than bit-counted.
    func test_rolledOverStaticReplyIsRejected() async throws {
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let uid = NTAG213Simulator.defaultUID
        let signature = try XCTUnwrap(Type2Rollover.signature(forUID: uid))
        let wire = Wire { _ in signature + Data(repeating: 0x00, count: 16 - signature.count) }
        let reading = await Type2LockDriver(uid: uid) { wire.transceive($0) }.readLockState(
            layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41
        )
        XCTAssertTrue(reading.regions[.staticLock]?.isUnread == true)
        XCTAssertTrue(reading.regions[.dynamicLock]?.isUnread == true)
        XCTAssertEqual(reading.state, .unknown, "never a bit count off a page we did not get")
    }

    func test_unansweredReadIsNotRead_ratherThanClear() async throws {
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let reading = await Type2LockDriver(uid: nil) { _ in
            throw TagError.tagLost(diagnostics: "gone")
        }.readLockState(layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41)
        XCTAssertTrue(reading.regions[.staticLock]?.isUnread == true)
        XCTAssertEqual(reading.state, .unknown)
    }

    // MARK: - Lock bits versus block-locking bits

    /// A block-locking bit locks a lock *bit*, not a page. A tag whose L bits are
    /// all set refuses every write whether or not its BL bits were touched, and
    /// plenty of encoders set only the L bits. Scoring against the full write
    /// mask reported such a tag as merely partly locked.
    func test_lockBitsSetWithBlockLockingBitsClear_readsAsLocked() async throws {
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let wire = Wire { command in
            guard command.count >= 2, command[command.startIndex] == 0x30 else { return Data([0x00]) }
            // Dynamic: lock bits set (bytes 0-1), BL byte 2 left clear.
            // Static: LOCK0 bits 3-7 and all of LOCK1 set, BL bits 0-2 clear.
            switch command[command.startIndex + 1] {
            case 0x28: return Data([0xFF, 0x0F, 0x00, 0xBD]) + Data(repeating: 0x00, count: 12)
            case 0x02: return Data([0x9F, 0x48, 0xF8, 0xFF]) + Data(repeating: 0x00, count: 12)
            default: return Data([0x00])
            }
        }
        let reading = await Type2LockDriver(uid: nil) { wire.transceive($0) }.readLockState(
            layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41
        )
        XCTAssertEqual(reading.regions[.dynamicLock], .allSet)
        XCTAssertEqual(reading.regions[.staticLock], .allSet)
        XCTAssertEqual(reading.state, .locked)
    }

    /// A tag with only its Capability Container locked (LOCK0 bit 3) is a real,
    /// common state and it really is partly read-only, so it must not read as
    /// open. It must also not read as locked.
    func test_onlyTheCapabilityContainerLocked_readsAsSomeSet() async throws {
        let profile = try XCTUnwrap(ChipCatalog.profile(for: .ntag213))
        let wire = Wire { command in
            guard command.count >= 2, command[command.startIndex] == 0x30 else { return Data([0x00]) }
            switch command[command.startIndex + 1] {
            case 0x28: return Data([0x00, 0x00, 0x00, 0xBD]) + Data(repeating: 0x00, count: 12)
            case 0x02: return Data([0x9F, 0x48, 0x08, 0x00]) + Data(repeating: 0x00, count: 12)
            default: return Data([0x00])
            }
        }
        let reading = await Type2LockDriver(uid: nil) { wire.transceive($0) }.readLockState(
            layout: profile.memoryLayout, family: profile.family, provenReadablePage: 41
        )
        XCTAssertEqual(reading.regions[.staticLock], .someSet)
        XCTAssertEqual(reading.state, .partlyLocked)
    }

    /// The read mask may never expect a bit the write does not set, or a tag this
    /// app locked itself would read back as incomplete.
    func test_theReadMaskIsAlwaysASubsetOfTheWriteMask() {
        for profile in ChipCatalog.all {
            guard case .type2 = profile.family, profile.memoryLayout.dynamicLockPage != nil else { continue }
            let write = Type2LockWrite.lockBitMask(for: profile.family)
            let read = Type2LockWrite.dynamicLockBitsOnlyMask(for: profile.family)
            XCTAssertEqual(read.count, write.count, "\(profile.displayName)")
            for (index, bits) in read.enumerated() {
                XCTAssertEqual(
                    bits & write[index], bits,
                    "\(profile.displayName) byte \(index): the read expects a bit the lock never writes"
                )
            }
            XCTAssertTrue(read.contains { $0 != 0 }, "\(profile.displayName) has no readable lock bits")
        }
    }

    /// Every catalogued Type-2 chip keeps its dynamic lock page **below** the
    /// first configuration page. That relationship is what lets the scan certify
    /// the dynamic page readable from a configuration read that was answered.
    func test_everyCataloguedChipKeepsItsDynamicLockPageBelowTheConfigBlock() {
        for profile in ChipCatalog.all {
            guard case .type2 = profile.family, let dynamic = profile.memoryLayout.dynamicLockPage else { continue }
            let config = try? XCTUnwrap(profile.memoryLayout.configPages.first)
            XCTAssertNotNil(config, "\(profile.displayName) has a dynamic lock page and no config pages")
            if let config = config ?? nil {
                XCTAssertLessThan(
                    dynamic, config,
                    "\(profile.displayName): the scan certifies the dynamic lock page from the config read"
                )
            }
            XCTAssertEqual(profile.memoryLayout.lockPages.first, 2, "\(profile.displayName)")
        }
    }
}
