@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// `Type4NDEFProbe` against the Type 4 simulators: the frames it sends, what it
/// concludes, and that nothing it sends can change a tag.
///
/// The probe is the only code that talks to a health device before it is
/// recognised as one, so the frame list is asserted exactly rather than by
/// outcome alone.
final class Type4NDEFProbeTests: XCTestCase {
    private func probe(_ chip: Type4NDEFSimulator) -> Type4NDEFProbe {
        chip.beginActivation()
        return Type4NDEFProbe { command, _ in chip.handle(command: command) }
    }

    private static let selectCC = Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x03])
    private static let readCC = Data([0x00, 0xB0, 0x00, 0x00, 0x0F])
    private static let selectNDEF = Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x04])
    private static let readNLEN = Data([0x00, 0xB0, 0x00, 0x00, 0x02])

    // MARK: - A health device

    /// The pen answers the sequence a published trace shows it answering, the
    /// probe reads the whole 61-byte association request, and identification
    /// names the maker.
    func test_pen_isRecognisedFromPlainReadsAndNamed() async throws {
        let pen = PHDCDeviceSimulator()

        let outcome = await probe(pen).probe()

        XCTAssertEqual(outcome, .personalHealthDevice(message: pen.message))
        XCTAssertEqual(pen.receivedCommands, [
            Self.selectCC,
            Self.readCC,
            Self.selectNDEF,
            Self.readNLEN,
            Data([0x00, 0xB0, 0x00, 0x02, 0x10]), // the 16-byte head
            Data([0x00, 0xB0, 0x00, 0x12, 0x2D]), // the remaining 45 bytes
        ])
        let (profile, association) = try XCTUnwrap(ChipCatalog.identify(type4Probe: outcome))
        XCTAssertEqual(profile.id, .personalHealthDevice)
        XCTAssertEqual(profile.manufacturer, "Novo Nordisk")
        XCTAssertEqual(profile.capabilities, [.personalHealthDevice], "no read, write or raw capability at all")
        XCTAssertEqual(association?.maker, .novoNordisk)
    }

    /// Every frame the probe sends is a SELECT or a READ BINARY, so a health
    /// device's file is exactly as it was afterwards.
    func test_probe_neverWrites() async {
        let pen = PHDCDeviceSimulator()
        let before = pen.ndefFile

        _ = await probe(pen).probe()

        XCTAssertEqual(pen.writeCount, 0)
        XCTAssertEqual(pen.ndefFile, before)
        for command in pen.receivedCommands {
            XCTAssertTrue([0xA4, 0xB0].contains(command[1]), "unexpected INS in \(command.hexString)")
        }
    }

    /// A small MLe splits the message across several reads, and the pieces are
    /// reassembled in order.
    func test_pen_messageLongerThanMLe_isReadInChunks() async {
        let message = PHDCDeviceSimulator.associationRequest(
            systemID: PHDCDeviceSimulator.syntheticNovoSystemID,
            configurationID: PHDCDeviceSimulator.novoConfigurationID
        )
        let pen = Type4NDEFSimulator(message: message, maxReadLength: 0x14, fileSize: 0x010C)

        let outcome = await probe(pen).probe()

        XCTAssertEqual(outcome, .personalHealthDevice(message: message))
        let reads = pen.receivedCommands.filter { $0[1] == 0xB0 }.map { Int($0[4]) }
        XCTAssertEqual(reads, [15, 2, 16, 20, 20, 5], "CC, NLEN, head, then MLe-sized chunks")
    }

    /// A PHD record too long to be an association request is still a health
    /// device. It is not read in full, and it gets no maker.
    func test_overlongPHDMessage_isAHealthDeviceWithNoAssociation() async throws {
        let payload = Data(repeating: 0x00, count: 1100)
        let message = Data([0xC1, 0x03, 0x00, 0x00, 0x04, 0x4C]) + Data("PHD".utf8) + payload
        let device = Type4NDEFSimulator(message: message, fileSize: 0x0800)

        let outcome = await probe(device).probe()

        XCTAssertEqual(outcome, .personalHealthDevice(message: nil))
        let (profile, association) = try XCTUnwrap(ChipCatalog.identify(type4Probe: outcome))
        XCTAssertEqual(profile.capabilities, [.personalHealthDevice])
        XCTAssertEqual(profile.manufacturer, "Unknown")
        XCTAssertNil(association)
    }

    // MARK: - An ordinary Type 4 tag

    /// Only the head of an ordinary message is read before the probe concludes,
    /// however long the message is.
    func test_ordinaryTag_readsOnlyTheHead() async throws {
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro/" + String(repeating: "a", count: 200)))]
        let tag = try Type4NDEFSimulator(message: NDEFCodec.encode(records))

        let outcome = await probe(tag).probe()

        guard case .ndef(let head) = outcome else { return XCTFail("expected .ndef, got \(outcome)") }
        XCTAssertEqual(head, Data(tag.message.prefix(16)))
        XCTAssertEqual(tag.receivedCommands.count, 5)
        let (profile, association) = try XCTUnwrap(ChipCatalog.identify(type4Probe: outcome))
        XCTAssertEqual(profile.id, .genericType4)
        XCTAssertEqual(profile.capabilities, [.ndefRead, .ndefWrite, .rawTransceive])
        XCTAssertNil(association)
    }

    func test_emptyRecordTag_isAnOrdinaryTag() async {
        let tag = Type4NDEFSimulator(message: Data([0xD0, 0x00, 0x00]))

        let outcome = await probe(tag).probe()

        XCTAssertEqual(outcome, .ndef(head: Data([0xD0, 0x00, 0x00])))
    }

    func test_zeroLengthMessage_readsNoHead() async {
        let tag = Type4NDEFSimulator(message: Data())

        let outcome = await probe(tag).probe()

        XCTAssertEqual(outcome, .ndef(head: Data()))
        XCTAssertEqual(tag.receivedCommands.count, 4, "nothing to read past NLEN")
    }

    // MARK: - Not readable

    /// A CC that withholds read access is respected, not probed past.
    func test_readAccessDenied_isUnreadable_andTheNDEFFileIsNeverSelected() async {
        let tag = Type4NDEFSimulator(message: Data([0xD0, 0x00, 0x00]))
        let locked = LockedReadCC(tag)

        let outcome = await Type4NDEFProbe { command, _ in locked.handle(command) }.probe()

        guard case .unreadable = outcome else { return XCTFail("expected .unreadable, got \(outcome)") }
        XCTAssertNil(ChipCatalog.identify(type4Probe: outcome))
        XCTAssertFalse(tag.receivedCommands.contains(Self.selectNDEF))
    }

    func test_noCapabilityContainer_isUnreadable() async {
        let outcome = await Type4NDEFProbe { _, _ in Data([0x6A, 0x82]) }.probe()

        XCTAssertEqual(outcome, .unreadable("no Capability Container"))
    }

    func test_transportError_isUnreadable() async {
        struct Gone: Error {}
        let outcome = await Type4NDEFProbe { _, _ in throw Gone() }.probe()

        guard case .unreadable = outcome else { return XCTFail("expected .unreadable, got \(outcome)") }
    }

    /// Wraps a simulator and rewrites the CC's read-access byte to `80h`
    /// (proprietary), the way a read-protected Type 4 file declares itself.
    private final class LockedReadCC: @unchecked Sendable {
        let inner: Type4NDEFSimulator
        init(_ inner: Type4NDEFSimulator) {
            self.inner = inner
            inner.beginActivation()
        }

        func handle(_ command: Data) -> Data {
            var response = inner.handle(command: command)
            if command == Type4NDEFProbeTests.readCC, response.count == 17 {
                response[13] = 0x80
            }
            return response
        }
    }
}
