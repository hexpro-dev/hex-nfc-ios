@testable import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// The DESFire NDEF setup and removal, run against the frame-level simulator
/// through the shipping `ConnectedTag` entry points, with the frames read back
/// from the fault-injection log.
///
/// Three things are pinned here that a green run could otherwise hide: the
/// frames match NXP AN11004 §8.1 byte for byte, the CC write is the last write,
/// and nothing that changes a card is sent to one this app did not establish
/// as blank or its own.
final class DESFireNDEFSetupTests: XCTestCase {
    private func connect(_ simulator: DESFireEV3Simulator) async throws
        -> (FaultInjectingSessionFactory, ConnectedTag)
    {
        let factory = FaultInjectingSessionFactory(chip: simulator)
        return try await (factory, factory.makeSession().start(alert: ""))
    }

    private func tap(_ factory: FaultInjectingSessionFactory) async throws -> ConnectedTag {
        try await factory.makeSession().start(alert: "")
    }

    private static let writeInstructions: Set<UInt8> = [0xCA, 0xCD, 0x3D, 0xFC]

    private func writeFrames(_ factory: FaultInjectingSessionFactory) -> [Data] {
        factory.report.frames.map(\.request).filter {
            $0.count >= 2 && $0.first == 0x90 && Self.writeInstructions.contains($0[$0.startIndex + 1])
        }
    }

    private func assertRefused(
        _ expected: DESFireNDEFState,
        _ body: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected a refusal", file: file, line: line)
        } catch let error as DESFireNDEFError {
            XCTAssertEqual(error.reason, .refused(expected), file: file, line: line)
            XCTAssertFalse(error.wroteSomething, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Setup

    func test_setUp_onABlankCard_createsTheApplicationAndAReaderSeesIt() async throws {
        let simulator = DESFireEV3Simulator()
        let (factory, tag) = try await connect(simulator)

        let outcome = try await tag.setUpDESFireNDEF()

        XCTAssertEqual(outcome, .created(ndefFileSize: 0x1000), "a blank EV3 4K gets 4 KB")
        XCTAssertEqual(simulator.violations, [])
        let writes = writeFrames(factory)
        XCTAssertEqual(writes.map { $0[1] }, [0xCA, 0xCD, 0xCD, 0x3D, 0x3D])
        XCTAssertEqual(
            writes[0],
            Data([0x90, 0xCA, 0x00, 0x00, 0x0E, 0x01, 0x00, 0x00, 0x0F, 0x21, 0x10, 0xE1,
                  0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]),
            "AN11004 §8.1 step 2"
        )
        XCTAssertEqual(
            writes[3],
            Data([0x90, 0x3D, 0x00, 0x00, 0x09, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]),
            "AN11004 §8.1 step 7"
        )
        XCTAssertEqual(Array(writes[4].prefix(6)), [0x90, 0x3D, 0x00, 0x00, 0x16, 0x01], "the CC is written last")

        let access = try await tag.queryNDEFAccess()
        XCTAssertEqual(access, .readWrite)
        XCTAssertTrue(tag.capabilities.contains(.ndefWrite))
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]
        try await tag.writeNDEF(records)
        let readBack = try await tag.readNDEF()
        XCTAssertEqual(readBack, try NDEFCodec.encode(records))
    }

    /// The figures a factory EV3 4K gave on the bench (2026-10-30): 5120 B free,
    /// 4928 B once the application and CC file exist (what the size policy
    /// measures), and 832 B after the 4 KB NDEF file.
    func test_setUp_leavesTheFreeMemoryTheBenchMeasured() async throws {
        let simulator = DESFireEV3Simulator()
        XCTAssertEqual(simulator.freeMemoryBytes, 5120)
        let (factory, tag) = try await connect(simulator)

        _ = try await tag.setUpDESFireNDEF()

        let measured = factory.report.frames
            .filter { $0.request == Data([0x90, 0x6E, 0x00, 0x00, 0x00]) }
            .compactMap(\.response)
        XCTAssertEqual(measured, [Data([0x40, 0x13, 0x00, 0x91, 0x00])], "4928 B after the CC file")
        XCTAssertEqual(simulator.freeMemoryBytes, 832)
    }

    /// AN11004 §8.1 steps 5 and 6 use a 2048-byte NDEF file; a card with less
    /// free memory gets exactly those bytes.
    func test_setUp_framesMatchTheApplicationNoteAtTwoKilobytes() async throws {
        let simulator = DESFireEV3Simulator()
        simulator.freeMemoryBytes = 0x0800 + 256 + 32 + DESFireEV3Simulator.applicationCost
        let (factory, tag) = try await connect(simulator)

        let outcome = try await tag.setUpDESFireNDEF()

        XCTAssertEqual(outcome, .created(ndefFileSize: 0x0800))
        let writes = writeFrames(factory)
        XCTAssertEqual(
            writes[2],
            Data([0x90, 0xCD, 0x00, 0x00, 0x09, 0x02, 0x04, 0xE1, 0x00, 0xE0, 0xEE, 0x00, 0x08, 0x00, 0x00]),
            "AN11004 §8.1 step 6"
        )
        XCTAssertEqual(
            writes[4],
            Data([0x90, 0x3D, 0x00, 0x00, 0x16, 0x01, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00,
                  0x00, 0x0F, 0x20, 0x00, 0x3A, 0x00, 0x34, 0x04, 0x06, 0xE1, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00]),
            "AN11004 §8.1 step 5"
        )
    }

    func test_setUp_onACardAlreadySetUp_writesNothing() async throws {
        let simulator = DESFireEV3Simulator.ndefFormatted(ndefFileSize: 0x0800)
        let (factory, tag) = try await connect(simulator)

        let outcome = try await tag.setUpDESFireNDEF()

        XCTAssertEqual(outcome, .alreadySetUp(ndefFileSize: 0x0800))
        XCTAssertEqual(writeFrames(factory), [])
    }

    func test_setUp_refusesATransitCard_withoutAWrite() async throws {
        let (factory, tag) = try await connect(.personalised())
        await assertRefused(.otherApplications) { try await tag.setUpDESFireNDEF() }
        XCTAssertEqual(writeFrames(factory), [])
    }

    func test_setUp_refusesACardThatNeedsItsKeyToCreate() async throws {
        let simulator = DESFireEV3Simulator()
        simulator.piccKeySettings = Data([0x0B, 0x01])
        let (factory, tag) = try await connect(simulator)
        await assertRefused(.applicationsNeedKey) { try await tag.setUpDESFireNDEF() }
        XCTAssertEqual(writeFrames(factory), [])
    }

    /// A card set up by another tool can still be an NDEF card. Format leaves it
    /// alone rather than "repairing" it into this app's layout.
    func test_setUp_leavesAnotherToolsSetupAlone() async throws {
        let extraFile = DESFireEV3Simulator.ndefFormatted()
        extraFile.applications[0].files[0x03] = .init(accessRights: Data([0xE0, 0xEE]), bytes: Data(count: 32))
        let otherKeys = DESFireEV3Simulator.ndefFormatted()
        otherKeys.applications[0].keySettings1 = 0x0B
        let otherRights = DESFireEV3Simulator.ndefFormatted()
        otherRights.applications[0].files[0x01]?.accessRights = Data([0x00, 0xE0])
        // Everything else ours, but not answering to the NDEF DF name. Key
        // settings would not have caught it: an EV3 reports `0F 01` with or
        // without ISO file IDs.
        let noDFName = DESFireEV3Simulator.ndefFormatted()
        noDFName.applications[0].dfName = nil

        for simulator in [extraFile, otherKeys, otherRights, noDFName] {
            let (factory, tag) = try await connect(simulator)
            await assertRefused(.otherNDEFSetup) { try await tag.setUpDESFireNDEF() }
            XCTAssertEqual(writeFrames(factory), [])
        }
    }

    /// The simulator answers as an EV3 did on the bench (2026-10-30): the
    /// application created with key settings `0F 21` reads back `0F 01`, so a
    /// check written against the requested byte fails here as it did on silicon.
    func test_simulator_reportsApplicationKeySettingsWithoutTheISOBit() async throws {
        let (_, tag) = try await connect(.ndefFormatted())
        let select = DESFireAPDU.wrap(0x5A, DESFireNDEFDriver.applicationID)
        _ = try await tag.transceive(RawCommand(bytes: select, name: "SelectApplication 000001"))
        let settings = try await tag.transceive(RawCommand(bytes: DESFireAPDU.wrap(0x45), name: "GetKeySettings"))
        XCTAssertEqual(settings, Data([0x0F, 0x01, 0x91, 0x00]))
    }

    /// libfreefare writes MLe 003Bh. This app's structure, someone else's CC:
    /// Format will not rewrite it.
    func test_setUp_leavesAForeignCCAlone() async throws {
        let simulator = DESFireEV3Simulator.ndefFormatted()
        simulator.applications[0].files[0x01]?.bytes[4] = 0x3B
        let (factory, tag) = try await connect(simulator)
        await assertRefused(.ours(.unrecognisedContent)) { try await tag.setUpDESFireNDEF() }
        XCTAssertEqual(writeFrames(factory), [])
    }

    // MARK: - Every abort point is recoverable

    private static let setupWrites: [(String, [UInt8])] = [
        ("CreateApplication", [0x90, 0xCA]),
        ("CreateStdDataFile CC", [0x90, 0xCD, 0x00, 0x00, 0x09, 0x01]),
        ("CreateStdDataFile NDEF", [0x90, 0xCD, 0x00, 0x00, 0x09, 0x02]),
        ("WriteData NLEN", [0x90, 0x3D, 0x00, 0x00, 0x09, 0x02]),
        ("WriteData CC", [0x90, 0x3D, 0x00, 0x00, 0x16, 0x01]),
    ]

    /// A lost answer or a dropped frame at each write leaves a card the next
    /// tap finishes, at the size the first tap chose.
    func test_setUp_resumesAfterAnInterruptionAtEveryWrite() async throws {
        for effect in [TagFaultEffect.lostACK, .dropped] {
            for (name, prefix) in Self.setupWrites {
                let simulator = DESFireEV3Simulator()
                let (factory, tag) = try await connect(simulator)
                factory.arm(TagFault(.prefix(prefix, name: name), effect))

                do {
                    _ = try await tag.setUpDESFireNDEF()
                    XCTFail("\(name) \(effect): expected the run to stop")
                } catch let error as DESFireNDEFError {
                    guard case .noAnswer = error.reason else {
                        XCTFail("\(name): expected noAnswer, got \(error.reason)")
                        continue
                    }
                    XCTAssertTrue(error.wroteSomething, name)
                }

                factory.disarm()
                let second = try await tap(factory).setUpDESFireNDEF()
                switch second {
                case .created(let size), .alreadySetUp(let size):
                    XCTAssertEqual(size, 0x1000, "\(name): the size never changes on a resume")
                }
                XCTAssertEqual(simulator.ndefAccess, .readWrite, "\(name) \(effect)")
                XCTAssertEqual(simulator.violations, [], "\(name) \(effect)")
            }
        }
    }

    /// A refusal is the card answering, not a lost answer: reported as such,
    /// with the fact that the card has already changed.
    func test_setUp_reportsARefusalMidway() async throws {
        let (factory, tag) = try await connect(DESFireEV3Simulator())
        factory.arm(TagFault(
            .prefix([0x90, 0xCD, 0x00, 0x00, 0x09, 0x02]),
            .refused(response: Data([0x91, 0x0E]), halts: false)
        ))
        do {
            _ = try await tag.setUpDESFireNDEF()
            XCTFail("expected a refusal")
        } catch let error as DESFireNDEFError {
            XCTAssertEqual(error.reason, .cardRefused(.createNDEFFile, status: "91:0E"))
            XCTAssertTrue(error.wroteSomething)
        }
    }

    // MARK: - Remove

    func test_remove_returnsASetUpCardToBlank() async throws {
        let simulator = DESFireEV3Simulator()
        let (factory, tag) = try await connect(simulator)
        _ = try await tag.setUpDESFireNDEF()
        factory.resetLog()

        let outcome = try await tap(factory).removeDESFireNDEF()

        XCTAssertEqual(outcome, .removed(freeMemory: 5120))
        XCTAssertEqual(simulator.applications, [])
        XCTAssertEqual(simulator.authenticationAttempts, 1, "one attempt")
        XCTAssertEqual(simulator.violations, [])
        XCTAssertEqual(simulator.ndefAccess, .notSupported)
        let frames = factory.report.frames.map(\.request)
        XCTAssertEqual(frames.count(where: { $0.starts(with: [0x90, 0xFC]) }), 1)
    }

    func test_remove_onABlankCard_sendsNothingThatChangesIt() async throws {
        let (factory, tag) = try await connect(DESFireEV3Simulator())
        let outcome = try await tag.removeDESFireNDEF()
        XCTAssertEqual(outcome, .alreadyBlank)
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
        XCTAssertEqual(writeFrames(factory), [])
    }

    func test_remove_refusesATransitCard_withoutPresentingAKey() async throws {
        let (factory, tag) = try await connect(.personalised())
        await assertRefused(.otherApplications) { try await tag.removeDESFireNDEF() }
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
    }

    func test_remove_refusesAnotherToolsSetup_withoutPresentingAKey() async throws {
        let simulator = DESFireEV3Simulator.ndefFormatted()
        simulator.applications[0].files[0x03] = .init(accessRights: Data([0xE0, 0xEE]), bytes: Data(count: 32))
        let (factory, tag) = try await connect(simulator)
        await assertRefused(.otherNDEFSetup) { try await tag.removeDESFireNDEF() }
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
    }

    /// The transit card captured on 2026-10-30 reports master key version 01.
    /// A card like that is never sent the factory key.
    func test_remove_neverPresentsTheFactoryKeyToAChangedPICCKey() async throws {
        let simulator = DESFireEV3Simulator.ndefFormatted()
        simulator.piccKeyVersion = 0x01
        let (factory, tag) = try await connect(simulator)
        await assertReason(.piccKeyNotFactory) { try await tag.removeDESFireNDEF() }
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
        XCTAssertEqual(simulator.applications.count, 1)
    }

    /// Key 0 inside the application is also the zero key, so an authentication
    /// that landed at application level would succeed and prove nothing. The
    /// card has to answer the PICC select with `91 00` first; key settings
    /// cannot stand in for it, because an EV3's application answers `0F 01`
    /// just as its PICC does.
    func test_remove_neverAuthenticatesUnlessTheCardIsAtPICCLevel() async throws {
        let (factory, tag) = try await connect(.ndefFormatted())
        // The first PICC select opens the state read; the second precedes the key.
        factory.arm(TagFault(
            .prefix([0x90, 0x5A, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]),
            .refused(response: Data([0x91, 0x9D]), halts: false),
            on: .nth(2)
        ))
        await assertReason(.notAtPICCLevel) { try await tag.removeDESFireNDEF() }
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
    }

    /// The PICC has one key and never reports ISO file IDs, so key settings
    /// saying otherwise are not the PICC's, and no key is presented.
    func test_remove_neverAuthenticatesAgainstKeySettingsThePICCCannotHave() async throws {
        let (factory, tag) = try await connect(.ndefFormatted())
        // The first GetKeySettings is the application's, read for ownership; the
        // second is the PICC check.
        factory.arm(TagFault(
            .prefix([0x90, 0x45]),
            .refused(response: Data([0x0F, 0x21, 0x91, 0x00]), halts: false),
            on: .nth(2)
        ))
        await assertReason(.notAtPICCLevel) { try await tag.removeDESFireNDEF() }
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
    }

    func test_remove_aRefusedFactoryKey_sendsNoFormatPICC() async throws {
        let simulator = DESFireEV3Simulator.ndefFormatted()
        let (factory, tag) = try await connect(simulator)
        factory.arm(TagFault(.prefix([0x90, 0x1A]), .refused(response: Data([0x91, 0xAE]), halts: false)))
        await assertReason(.factoryKeyRefused) { try await tag.removeDESFireNDEF() }
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0xFC])))
        XCTAssertEqual(simulator.applications.count, 1)
    }

    /// FormatPICC applied, answer lost: "may already be blank", and the next
    /// tap finds it blank rather than failing.
    func test_remove_aLostAnswerOnFormatPICC_isReportedAsUnknown() async throws {
        let simulator = DESFireEV3Simulator.ndefFormatted()
        let (factory, tag) = try await connect(simulator)
        factory.arm(TagFault(.prefix([0x90, 0xFC]), .lostACK))

        await assertReason(.noAnswer(.formatPICC)) { try await tag.removeDESFireNDEF() }

        factory.disarm()
        let again = try await tap(factory).removeDESFireNDEF()
        XCTAssertEqual(again, .alreadyBlank)
    }

    /// An interrupted setup can always be removed: that is the way out the
    /// partial-setup report points to.
    func test_remove_clearsAnInterruptedSetup() async throws {
        let simulator = DESFireEV3Simulator()
        let (factory, tag) = try await connect(simulator)
        factory.arm(TagFault(.prefix([0x90, 0xCD, 0x00, 0x00, 0x09, 0x02]), .dropped))
        _ = try? await tag.setUpDESFireNDEF()
        factory.disarm()

        let outcome = try await tap(factory).removeDESFireNDEF()

        XCTAssertEqual(outcome, .removed(freeMemory: 5120))
        XCTAssertEqual(simulator.violations, [])
    }

    /// Tap 1 of Remove makes every check the removal makes before it presents
    /// the key, and sends nothing that authenticates or changes the card.
    func test_checkRemovable_isReadOnlyAndNeverAuthenticates() async throws {
        let (factory, tag) = try await connect(.ndefFormatted())
        let removable = try await tag.checkDESFireNDEFRemovable()
        XCTAssertTrue(removable)
        XCTAssertFalse(factory.report.contains(.prefix([0x90, 0x1A])))
        XCTAssertEqual(writeFrames(factory), [])

        let (_, blank) = try await connect(DESFireEV3Simulator())
        let blankIsRemovable = try await blank.checkDESFireNDEFRemovable()
        XCTAssertFalse(blankIsRemovable, "nothing to remove")

        let (_, transit) = try await connect(.personalised())
        await assertRefused(.otherApplications) { try await transit.checkDESFireNDEFRemovable() }
    }

    private func assertReason(
        _ expected: DESFireNDEFError.Reason,
        _ body: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as DESFireNDEFError {
            XCTAssertEqual(error.reason, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
