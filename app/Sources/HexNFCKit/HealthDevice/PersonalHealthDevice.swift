import Foundation
import HexNFCRecords

/// What a personal health device says about itself in the first message it
/// leaves in its NDEF file: the IEEE 11073-20601 association request (AARQ)
/// that an NFC Forum PHDC agent opens every exchange with.
///
/// **Read once and never answered.** A PHDC manager replies with an
/// association response written back into the same file, and only then does
/// the device stream its data. This app writes nothing back, so the device's
/// state is never changed and its measurements (an insulin pen's dose history)
/// never leave it. The device stops waiting on its own, exactly as it does when
/// a phone is pulled away halfway through a read.
///
/// Layout, as a published NovoPen 6 trace shows it (a 61-byte NDEF message;
/// lcacheux/nov-open-reader, `nvplib/core/nvp_datatest.txt`):
///
///     D1 03 37 50 48 44     NDEF header: MB ME SR, well-known, type "PHD"
///     00                    PHD header byte, sequence counter in the low nibble
///     E2 00 00 32           APDU: aarq-chosen, 50 bytes
///     80 00 00 00           assoc-version
///     00 01 00 2A           data-proto-list: one entry, 42 bytes
///     50 79 00 26           data-proto-id 20601, 38 bytes of association info
///     80 00 00 00           protocol-version
///     80 00                 encoding-rules
///     80 00 00 00           nomenclature-version
///     00 00 00 00           functional-units
///     00 80 00 00           system-type: agent
///     00 08 xx xx .. xx     system-id: an EUI-64, OUI first
///     40 0A                 dev-config-id
///     00 01 01 00           data-req-mode-capab
///     00 00 00 00           option-list: empty
///
/// The field order from `protocol-version` down is IEEE 11073-20601's
/// `PhdAssociationInformation`; the byte counts above add up to the 38 the
/// data-proto entry declares.
public struct PHDAssociation: Hashable, Sendable {
    /// The device's system ID. IEEE 11073-20601 makes this an EUI-64: a 24-bit
    /// IEEE organisationally unique identifier followed by 40 bits the
    /// manufacturer assigns.
    public let systemID: Data
    /// The device configuration the agent proposes. Values from `0x4000` up are
    /// extended (vendor-defined) configurations.
    public let configurationID: UInt16

    public init(systemID: Data, configurationID: UInt16) {
        self.systemID = systemID
        self.configurationID = configurationID
    }

    /// The IEEE OUI leading an EUI-64 system ID, or `nil` when the ID is not
    /// eight bytes long and so is not one.
    public var organizationID: Data? {
        systemID.count == 8 ? Data(systemID.prefix(3)) : nil
    }

    /// The maker the system ID's OUI is registered to, when it is one this app
    /// knows. Read off the device's own bytes, never inferred from anything else.
    public var maker: HealthDeviceMaker? {
        organizationID.flatMap(HealthDeviceMaker.init(oui:))
    }

    /// Whether an NDEF message, or just its opening bytes, starts with a PHD
    /// record: TNF well-known (`01`) and type `"PHD"`.
    ///
    /// Takes a prefix on purpose. Identification reads only the head of a Type 4
    /// tag's NDEF file before deciding, so an ordinary tag holding a long
    /// message costs a few bytes rather than the whole file.
    public static func startsWithPHDRecord(_ head: Data) -> Bool {
        let bytes = [UInt8](head)
        guard bytes.count >= 3 else { return false }
        let header = bytes[0]
        guard header & 0x07 == 0x01 else { return false }
        let typeLength = Int(bytes[1])
        let shortRecord = header & 0x10 != 0
        let hasID = header & 0x08 != 0
        let typeStart = 2 + (shortRecord ? 1 : 4) + (hasID ? 1 : 0)
        guard typeLength == phdRecordType.count, bytes.count >= typeStart + typeLength else { return false }
        return Data(bytes[typeStart ..< typeStart + typeLength]) == phdRecordType
    }

    /// Parse the association request out of a whole NDEF message. `nil` when
    /// the first record is not a PHD record or its payload is not an AARQ that
    /// carries a 20601 association.
    public init?(ndefMessage: Data) {
        guard let first = try? NDEFCodec.decodePayloads(ndefMessage).first,
              first.tnf == 0x01, first.type == Self.phdRecordType
        else { return nil }
        self.init(phdPayload: first.payload)
    }

    /// Parse a PHD record's payload: one header byte, then the 20601 APDU.
    init?(phdPayload: Data) {
        var reader = BigEndianReader(phdPayload)
        guard reader.skip(1), // PHD header byte
              reader.readUInt16() == Self.aarqChosen,
              let apduLength = reader.readUInt16(),
              var apdu = reader.read(Int(apduLength)).map(BigEndianReader.init),
              apdu.skip(4), // assoc-version
              let protocolCount = apdu.readUInt16(),
              apdu.skip(2) // data-proto-list length
        else { return nil }
        var association: (Data, UInt16)?
        for _ in 0 ..< protocolCount {
            guard let protocolID = apdu.readUInt16(),
                  let infoLength = apdu.readUInt16(),
                  let info = apdu.read(Int(infoLength))
            else { return nil }
            guard protocolID == Self.dataProtocol20601 else { continue }
            var fields = BigEndianReader(info)
            // protocol-version, encoding-rules, nomenclature-version,
            // functional-units and system-type: 4 + 2 + 4 + 4 + 4 bytes.
            guard fields.skip(18),
                  let systemIDLength = fields.readUInt16(),
                  let systemID = fields.read(Int(systemIDLength)),
                  let configurationID = fields.readUInt16()
            else { return nil }
            association = (systemID, configurationID)
            break
        }
        guard let (systemID, configurationID) = association else { return nil }
        self.init(systemID: systemID, configurationID: configurationID)
    }

    /// NFC Forum well-known record type of a PHDC message.
    static let phdRecordType = Data("PHD".utf8)
    /// IEEE 11073-20601 APDU choice for an association request.
    static let aarqChosen: UInt16 = 0xE200
    /// IEEE 11073-20601 `data-proto-id-20601`.
    static let dataProtocol20601: UInt16 = 0x5079
}

/// A health device maker this app can name from its IEEE OUI.
///
/// Only makers with a registered OUI and a device this app has seen evidence
/// of belong here. The list drives which device gets a named result and, in
/// the app, a referral to software that reads it in full.
public enum HealthDeviceMaker: String, Hashable, Sendable, CaseIterable {
    /// IEEE MA-L `00-14-65`, "Novo Nordisk A/S" (registry checked 2026-10-22).
    /// Its system IDs lead every NovoPen 6 and NovoPen Echo Plus association.
    case novoNordisk

    public init?(oui: Data) {
        guard let maker = Self.allCases.first(where: { $0.oui == oui }) else { return nil }
        self = maker
    }

    public var oui: Data {
        switch self {
        case .novoNordisk: Data([0x00, 0x14, 0x65])
        }
    }

    /// The registered company name, shortened the way the company writes it.
    public var name: String {
        switch self {
        case .novoNordisk: "Novo Nordisk"
        }
    }
}

/// Bounds-checked big-endian cursor over a byte buffer.
struct BigEndianReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int {
        bytes.count - cursor
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        cursor += count
        return true
    }

    mutating func read(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { cursor += count }
        return Data(bytes[cursor ..< cursor + count])
    }

    mutating func readUInt16() -> UInt16? {
        guard let pair = read(2) else { return nil }
        return UInt16(pair[pair.startIndex]) << 8 | UInt16(pair[pair.startIndex + 1])
    }
}
