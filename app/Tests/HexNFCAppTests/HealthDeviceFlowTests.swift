@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// A personal health device (an insulin pen) through every route a user can
/// take it down: scanned, it lands on a read-only result that names the maker
/// and points at an app that reads it; written, erased or sent commands, it is
/// refused before a single frame reaches it.
///
/// `PHDCDeviceSimulator` accepts writes, because a pen does: the manager side of
/// PHDC answers by writing into the same file. So every refusal here is the
/// app's, and each test checks the simulator saw nothing at all.
@MainActor
final class HealthDeviceFlowTests: XCTestCase {
    private let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

    // MARK: - Scan

    func test_scan_routesToTheHealthDeviceResult_withTheMakerAndAReferral() async throws {
        let pen = PHDCDeviceSimulator()
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: pen))

        await model.begin()

        XCTAssertEqual(model.phase, .ready)
        let device = try XCTUnwrap(model.healthDevice)
        XCTAssertEqual(device.maker, .novoNordisk)
        XCTAssertEqual(device.systemIDHex, PHDCDeviceSimulator.syntheticNovoSystemID.hexString)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.transitCard)
        XCTAssertNil(model.passportData)
        let info = try XCTUnwrap(model.scannedTagInfo)
        XCTAssertEqual(info.manufacturer, "Novo Nordisk")
        XCTAssertNil(info.capabilitySummary, "the card must not list Read, Write or Raw commands")
    }

    /// Identification read the association request; the scan itself sends
    /// nothing more. No NDEF read, no protection or lock probe, no diagnostics.
    func test_scan_sendsTheDeviceNothing() async {
        let pen = PHDCDeviceSimulator()
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: pen))

        await model.begin()

        XCTAssertEqual(pen.receivedCommands, [])
        XCTAssertEqual(pen.writeCount, 0)
        XCTAssertEqual(pen.ndefReadCount, 0, "not even CoreNFC's own NDEF read")
    }

    /// Session-only, like a passport. A History row would record that this
    /// person scanned an insulin pen.
    func test_scan_isNeverPersisted() async throws {
        let library = try LibraryRepository(stack: SwiftDataStack.inMemory())
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: PHDCDeviceSimulator()), library: library)

        await model.begin()

        XCTAssertNotNil(model.healthDevice)
        XCTAssertEqual(try library.fetchHistory().count, 0)
    }

    func test_reset_dropsTheHealthDevice() async {
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: PHDCDeviceSimulator()))
        await model.begin()

        model.reset()

        XCTAssertNil(model.healthDevice)
    }

    /// A health device whose maker the app cannot name still routes to the
    /// health result, with no referral rather than a guessed one.
    func test_unnamedMaker_routesWithoutAReferral() async throws {
        let device = PHDCDeviceSimulator(systemID: Data([0xAC, 0xDE, 0x48, 0x00, 0x00, 0x00, 0x00, 0x07]))
        let model = ScanFlowModel(factory: SimulatedSessionFactory(chip: device))

        await model.begin()

        let scan = try XCTUnwrap(model.healthDevice)
        XCTAssertNil(scan.maker)
        XCTAssertNil(scan.referral)
    }

    // MARK: - Referral

    /// The App Store link is storefront-neutral, so a reader in any country
    /// lands in their own store.
    func test_novoReferral_isMySugrInEveryStorefront_plusNovosOwnList() {
        let referral = HealthDeviceReferral(maker: .novoNordisk)

        XCTAssertEqual(referral.appName, "mySugr")
        XCTAssertEqual(referral.appStoreURL.absoluteString, "https://apps.apple.com/app/id516509211")
        XCTAssertFalse(referral.appStoreURL.path.contains("/us/"))
        XCTAssertEqual(referral.compatibleAppsURL.absoluteString, "https://www.novonordisk.com/novopenapps")
    }

    // MARK: - Refusals

    func test_write_isRefusedBeforeAnyFrame() async {
        let pen = PHDCDeviceSimulator()
        let model = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: pen), dataArea: .replace(records),
            credentials: InMemoryTagCredentialStore(), uidConfirmation: .required
        )

        await model.begin()
        await until {
            if case .error = model.phase {
                true
            } else {
                false
            }
        }

        guard case .error(let message, _) = model.phase else {
            return XCTFail("expected a refusal, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("health device"), message)
        XCTAssertEqual(pen.receivedCommands, [])
        XCTAssertEqual(pen.writeCount, 0)
        XCTAssertEqual(pen.ndefReadCount, 0, "not even CoreNFC's own NDEF read")
    }

    func test_erase_isRefusedBeforeAnyFrame() async {
        let pen = PHDCDeviceSimulator()
        let model = OperationsFlowModel(
            factory: SimulatedSessionFactory(chip: pen), operation: .erase, credentials: InMemoryTagCredentialStore()
        )

        await model.begin()
        await until {
            if case .error = model.phase {
                true
            } else {
                false
            }
        }

        guard case .error(let message, _) = model.phase else {
            return XCTFail("expected a refusal, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("health device"), message)
        XCTAssertEqual(pen.receivedCommands, [])
        XCTAssertEqual(pen.writeCount, 0)
        XCTAssertEqual(pen.ndefReadCount, 0, "not even CoreNFC's own NDEF read")
    }

    func test_consoleCommand_isRefusedBeforeAnyFrame() async {
        let pen = PHDCDeviceSimulator()
        let model = AdvancedConsoleModel(factory: SimulatedSessionFactory(chip: pen))
        // An UPDATE BINARY into the NDEF file: exactly what a PHDC manager would
        // send, and exactly what must never come from here.
        model.input = "00:D6:00:00:03:D0:00:00"

        await model.run()

        XCTAssertFalse(
            model.entries.contains { $0.kind == .tx },
            "no TX line: nothing was sent, and the log must not say otherwise"
        )
        let errors = model.entries.filter { $0.kind == .error }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.body.contains("health device") ?? false, "\(model.entries.map(\.body))")
        XCTAssertEqual(pen.receivedCommands, [])
        XCTAssertEqual(pen.writeCount, 0)
        XCTAssertEqual(pen.ndefReadCount, 0, "not even CoreNFC's own NDEF read")
    }

    /// The backstop under the flows: each write primitive on the connected tag
    /// refuses on its own, so a route added later cannot forget.
    func test_connectedTag_refusesEveryWritePrimitive() async throws {
        let pen = PHDCDeviceSimulator()
        let tag = try await SimulatedSession(chip: pen).start(alert: "")

        await assertRefused { try await tag.writeNDEF(self.records) }
        await assertRefused { _ = try await tag.transceive(RawCommand(bytes: Data([0x00, 0xB0, 0x00, 0x00, 0x02]))) }
        await assertRefused { try await tag.writeMemory(at: 0, bytes: Data(count: 4)) }
        XCTAssertEqual(pen.receivedCommands, [])
        XCTAssertEqual(pen.writeCount, 0)
        XCTAssertEqual(pen.ndefReadCount, 0, "not even CoreNFC's own NDEF read")
    }

    func test_preamble_refusesAHealthDevice() async throws {
        let tag = try await SimulatedSession(chip: PHDCDeviceSimulator()).start(alert: "")

        await assertRefused {
            _ = try await TagPreamble.establish(on: tag, TagPreamble.Request(
                intent: .readsGatedPages, heldCredential: nil, stagedStyle: nil, writesAllowed: false
            ))
        }
    }

    // MARK: - An ordinary Type 4 tag is unaffected

    /// Level 1 on its own: a Type 4 tag from a vendor iOS does not class as
    /// MIFARE scans its records and takes a write like any other tag.
    func test_genericType4_scansAndWrites() async throws {
        let tag = try Type4NDEFSimulator(message: NDEFCodec.encode(records))
        let scan = ScanFlowModel(factory: SimulatedSessionFactory(chip: tag))

        await scan.begin()

        XCTAssertEqual(scan.phase, .ready)
        XCTAssertNil(scan.healthDevice)
        // Records carry a fresh identity each; the bytes are what the tag held.
        XCTAssertEqual(try NDEFCodec.encode(scan.records), try NDEFCodec.encode(records))
        XCTAssertEqual(scan.detectedChipName, "NFC Forum Type 4")

        let replacement: [NDEFRecord] = [.uri(URIRecord(uri: "https://apps.hex.pro"))]
        let write = WriteFlowModel(
            factory: SimulatedSessionFactory(chip: tag), dataArea: .replace(replacement),
            credentials: InMemoryTagCredentialStore(), uidConfirmation: .notRequired
        )
        await write.begin()
        await until { write.phase == .done || {
            if case .error = write.phase {
                true
            } else {
                false
            }
        }() }

        XCTAssertEqual(write.phase, .done)
        XCTAssertEqual(tag.message, try NDEFCodec.encode(replacement))
    }

    // MARK: - Helpers

    private func assertRefused(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected a refusal", file: file, line: line)
        } catch let error as TagError {
            XCTAssertEqual(error.kind.isCapabilityUnsupported, true, file: file, line: line)
            XCTAssertTrue(
                error.diagnostics.contains("personal health device"),
                error.diagnostics,
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private extension TagError.Kind {
    var isCapabilityUnsupported: Bool {
        if case .capabilityUnsupported = self {
            true
        } else {
            false
        }
    }
}

@MainActor
private func until(timeout: Duration = .seconds(2), _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}
