import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// An NFC Forum Type 4 tag from a vendor iOS does not class as MIFARE (an
/// ST25TA, an Infineon part, an Android phone emulating a tag), as the app
/// meets it on the `.iso7816` transport through the NDEF application AID.
///
/// Models the NDEF Tag Application v2 file system: a 15-byte Capability
/// Container at `E103` and one NDEF file holding `NLEN || message`. Commands are
/// plain ISO 7816 SELECT / READ BINARY / UPDATE BINARY, which is all
/// `Type4NDEFProbe` sends and all CoreNFC's own NDEF path needs.
///
/// Every command is logged in `receivedCommands`. Every UPDATE BINARY or
/// high-level NDEF write is counted in `writeCount`, and every high-level NDEF
/// read in `ndefReadCount`, so a test can prove what was and was not sent.
public class Type4NDEFSimulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public var profile: ChipProfile? {
        ChipCatalog.profile(for: .genericType4)
    }

    /// NDEF Tag Application, version 2.
    public static let ndefApplicationAID = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])

    public let capabilityContainer: Data
    public private(set) var ndefFile: Data
    public private(set) var receivedCommands: [Data] = []
    public private(set) var writeCount = 0
    /// High-level reads, which on a phone are CoreNFC's own NDEF commands and
    /// so never reach `receivedCommands` here.
    public private(set) var ndefReadCount = 0

    private let ndefFileID: UInt16
    private var applicationSelected = false
    private var selectedFile: UInt16?

    /// - Parameters:
    ///   - message: the NDEF message the tag holds (no NLEN).
    ///   - maxReadLength: the CC's MLe.
    ///   - fileSize: the NDEF file's maximum size, NLEN included.
    public init(
        uid: Data = Data([0x02, 0x82, 0x00, 0x1A, 0x2B, 0x3C, 0x4D]),
        message: Data = Data([0xD0, 0x00, 0x00]),
        maxReadLength: Int = 0xF6,
        fileSize: Int = 0x0800,
        ndefFileID: UInt16 = 0xE104,
        writeAccess: UInt8 = 0x00
    ) {
        self.uid = uid
        self.ndefFileID = ndefFileID
        capabilityContainer = Data([
            0x00, 0x0F, 0x20,
            UInt8(maxReadLength >> 8), UInt8(maxReadLength & 0xFF),
            UInt8(maxReadLength >> 8), UInt8(maxReadLength & 0xFF),
            0x04, 0x06,
            UInt8(ndefFileID >> 8), UInt8(ndefFileID & 0xFF),
            UInt8(fileSize >> 8), UInt8(fileSize & 0xFF),
            0x00, writeAccess,
        ])
        var file = Data(count: fileSize)
        file.replaceSubrange(0 ..< 2 + message.count, with: Self.nlen(message.count) + message)
        ndefFile = file
        applicationSelected = true
    }

    /// iOS SELECTs the NDEF application during discovery and hands the tag over
    /// with it selected (`initialSelectedAID`), so every activation starts there.
    public func beginActivation() {
        applicationSelected = true
        selectedFile = nil
    }

    /// The NDEF message currently in the file.
    public var message: Data {
        let length = Int(ndefFile[0]) << 8 | Int(ndefFile[1])
        return Data(ndefFile[2 ..< 2 + length])
    }

    public func handle(command: Data) -> Data {
        receivedCommands.append(command)
        let apdu = APDU.parse(command)
        guard apdu.cla == 0x00 else { return Self.sw(0x6E00) }
        switch apdu.ins {
        case 0xA4:
            return select(apdu)

        case 0xB0:
            return readBinary(apdu)

        case 0xD6:
            return updateBinary(apdu)

        default:
            return Self.sw(0x6D00)
        }
    }

    private func select(_ apdu: APDU) -> Data {
        if apdu.p1 == 0x04 {
            applicationSelected = apdu.data == Self.ndefApplicationAID
            selectedFile = nil
            return Self.sw(applicationSelected ? 0x9000 : 0x6A82)
        }
        guard applicationSelected, apdu.p1 == 0x00, let id = apdu.data, id.count == 2 else {
            return Self.sw(0x6A82)
        }
        let fileID = UInt16(id[id.startIndex]) << 8 | UInt16(id[id.startIndex + 1])
        guard fileID == 0xE103 || fileID == ndefFileID else { return Self.sw(0x6A82) }
        selectedFile = fileID
        return Self.sw(0x9000)
    }

    private func readBinary(_ apdu: APDU) -> Data {
        guard let file = selectedFileContents else { return Self.sw(0x6986) }
        let offset = Int(apdu.p1) << 8 | Int(apdu.p2)
        guard offset <= file.count else { return Self.sw(0x6B00) }
        let requested = apdu.le.map { $0 == 0 ? 256 : Int($0) } ?? 256
        let end = min(offset + requested, file.count)
        return Data(file[offset ..< end]) + Self.sw(0x9000)
    }

    private func updateBinary(_ apdu: APDU) -> Data {
        guard selectedFile == ndefFileID else { return Self.sw(0x6986) }
        guard capabilityContainer[14] == 0x00 else { return Self.sw(0x6982) }
        let offset = Int(apdu.p1) << 8 | Int(apdu.p2)
        let data = apdu.data ?? Data()
        guard offset + data.count <= ndefFile.count else { return Self.sw(0x6A84) }
        ndefFile.replaceSubrange(offset ..< offset + data.count, with: data)
        writeCount += 1
        return Self.sw(0x9000)
    }

    private var selectedFileContents: Data? {
        switch selectedFile {
        case 0xE103: capabilityContainer
        case ndefFileID: ndefFile
        default: nil
        }
    }

    // MARK: - ChipSimulator

    public func readNDEF() throws -> Data {
        ndefReadCount += 1
        return message
    }

    /// The connected-tag layer hands every simulator a Type-2 TLV envelope;
    /// a Type 4 file keeps the message behind a two-byte NLEN instead.
    public func writeNDEF(_ envelope: Data) throws {
        let message = try NDEFEnvelope.unwrap(envelope)
        guard capabilityContainer[14] == 0x00 else {
            throw TagError.lockedPermanent(diagnostics: "NDEF file write access is not granted")
        }
        guard 2 + message.count <= ndefFile.count else {
            throw TagError.writeOverflow(needed: message.count, available: ndefFile.count - 2)
        }
        ndefFile.replaceSubrange(0 ..< 2 + message.count, with: Self.nlen(message.count) + message)
        writeCount += 1
    }

    public func readMemory(range: Range<Int>) throws -> Data {
        throw TagError.capabilityUnsupported(.memoryRead)
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        throw TagError.capabilityUnsupported(.memoryWrite)
    }

    public func authenticate(password: Data) throws -> Data {
        throw TagError.capabilityUnsupported(.passwordAuth)
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw TagError.capabilityUnsupported(.passwordAuth)
    }

    public func permanentLock() throws {
        throw TagError.capabilityUnsupported(.permanentLock)
    }

    static func nlen(_ length: Int) -> Data {
        Data([UInt8(length >> 8), UInt8(length & 0xFF)])
    }

    static func sw(_ status: UInt16) -> Data {
        Data([UInt8(status >> 8), UInt8(status & 0xFF)])
    }
}

/// A personal health device speaking NFC Forum PHDC over a Type 4 tag, as a
/// published NovoPen 6 trace shows one (lcacheux/nov-open-reader,
/// `nvplib/core/nvp_datatest.txt`):
///
/// - CC `00 0F 20 01 0C 01 0C 04 06 E1 04 01 0C 00 00`: MLe and MLc 268, NDEF
///   file `E104` of 268 bytes, read and write access both granted (the manager
///   answers by writing into the same file).
/// - NLEN `00 3D`, then the 61-byte association request `associationRequest`
///   builds.
///
/// **The system ID is not the trace's.** That one belongs to somebody's pen.
/// The OUI is Novo Nordisk's (`00-14-65`, IEEE MA-L), because that is what the
/// app identifies the maker from, and the 40 manufacturer-assigned bits are
/// made up. The configuration ID is the trace's (`0x400A`).
///
/// It answers what the trace shows a pen answering and nothing more. There is
/// no model of the rest of the exchange: this app never sends the association
/// response that would start it, and a simulator that went further would be
/// inventing behaviour no capture has shown.
public final class PHDCDeviceSimulator: Type4NDEFSimulator, @unchecked Sendable {
    /// Synthetic: Novo Nordisk's OUI, then a made-up device number.
    public static let syntheticNovoSystemID = Data([0x00, 0x14, 0x65, 0x00, 0x00, 0x00, 0x00, 0x01])
    public static let novoConfigurationID: UInt16 = 0x400A

    override public var profile: ChipProfile? {
        ChipCatalog.identify(type4Probe: .personalHealthDevice(message: message))?.0
    }

    public var healthDevice: PHDAssociation? {
        PHDAssociation(ndefMessage: message)
    }

    public init(
        systemID: Data = PHDCDeviceSimulator.syntheticNovoSystemID,
        configurationID: UInt16 = PHDCDeviceSimulator.novoConfigurationID,
        uid: Data = Data([0x08, 0x5E, 0x11, 0x22])
    ) {
        super.init(
            uid: uid,
            message: Self.associationRequest(systemID: systemID, configurationID: configurationID),
            maxReadLength: 0x010C,
            fileSize: 0x010C,
            ndefFileID: 0xE104,
            writeAccess: 0x00
        )
    }

    /// The NDEF message a PHDC agent opens with: one PHD record whose payload
    /// is a header byte and an IEEE 11073-20601 AARQ. Field values other than
    /// the two parameters are the trace's.
    public static func associationRequest(systemID: Data, configurationID: UInt16) -> Data {
        func be16(_ value: Int) -> Data {
            Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        var info = Data([
            0x80, 0x00, 0x00, 0x00, // protocol-version
            0x80, 0x00, // encoding-rules
            0x80, 0x00, 0x00, 0x00, // nomenclature-version
            0x00, 0x00, 0x00, 0x00, // functional-units
            0x00, 0x80, 0x00, 0x00, // system-type: agent
        ])
        info += be16(systemID.count) + systemID
        info += be16(Int(configurationID))
        info += Data([0x00, 0x01, 0x01, 0x00]) // data-req-mode-capab
        info += Data([0x00, 0x00, 0x00, 0x00]) // option-list: empty
        let proto = be16(0x5079) + be16(info.count) + info
        let body = Data([0x80, 0x00, 0x00, 0x00]) + be16(1) + be16(proto.count) + proto
        let apdu = be16(0xE200) + be16(body.count) + body
        let payload = Data([0x00]) + apdu
        return Data([0xD1, 0x03, UInt8(payload.count)]) + Data("PHD".utf8) + payload
    }
}
