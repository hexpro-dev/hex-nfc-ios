import Foundation

// MARK: - NDEFPayload wire model

/// A single NDEF record exactly as it sits on the wire. The codec encodes
/// `[NDEFRecord]` to `[NDEFPayload]` to `Data`, and reverses the chain on read.
///
/// `HexNFCKit` (and only `HexNFCKit`) bridges `NDEFPayload` to CoreNFC's
/// `NFCNDEFPayload`. Keeping that bridge outside this target preserves the
/// invariant that `HexNFCRecords` is pure value types with no CoreNFC dep.
public struct NDEFPayload: Hashable, Sendable, Codable {
    /// 3-bit Type Name Format. 0x01 = well-known, 0x02 = media, 0x04 = external.
    public let tnf: UInt8
    public let type: Data
    public let id: Data
    public let payload: Data

    public init(tnf: UInt8, type: Data, id: Data = Data(), payload: Data) {
        self.tnf = tnf & 0x07
        self.type = type
        self.id = id
        self.payload = payload
    }

    /// An NFC Forum **Empty** record — TNF 0x00 with no type, id or payload.
    /// It carries no application data: the spec uses it purely as the "this
    /// message has no content" marker (a blank-but-formatted tag reads back as a
    /// single one, `D0 00 00`). It is never a user-facing record, so the
    /// high-level `decode` drops it, and `isEmptyMessage` treats a message made
    /// only of these as empty. Both go through this one predicate so the two
    /// notions of "empty" can never drift.
    public var isEmptyRecord: Bool {
        tnf == NDEFPayload.tnfEmpty && type.isEmpty && payload.isEmpty
    }

    // Common TNF values.
    public static let tnfEmpty: UInt8 = 0x00
    public static let tnfWellKnown: UInt8 = 0x01
    public static let tnfMedia: UInt8 = 0x02
    public static let tnfAbsoluteURI: UInt8 = 0x03
    public static let tnfExternal: UInt8 = 0x04
    public static let tnfUnknown: UInt8 = 0x05
    public static let tnfUnchanged: UInt8 = 0x06

    public static let typeText: Data = .init("T".utf8)
    public static let typeURI: Data = .init("U".utf8)
    public static let typeVCard: Data = .init("text/vcard".utf8)
    public static let typeWPS: Data = .init("application/vnd.wfa.wsc".utf8)
    public static let typeBTOOB: Data = .init("application/vnd.bluetooth.ep.oob".utf8)
}

// MARK: - NDEF binary stream

public enum NDEFCodec {
    public enum DecodeError: Error, Hashable, Sendable {
        case truncated
        case unsupportedChunkedMessage
        case overflow
        case missingMessageBegin
        case missingMessageEnd
    }

    /// Decode a raw NDEF message into a stream of `NDEFPayload` items.
    /// Strict: any malformed header throws — partial decodes are not exposed.
    public static func decodePayloads(_ message: Data) throws -> [NDEFPayload] {
        var cursor = 0
        var payloads: [NDEFPayload] = []
        var sawBegin = false
        var sawEnd = false

        while cursor < message.count {
            guard cursor + 1 <= message.count else { throw DecodeError.truncated }
            let header = message[message.startIndex + cursor]
            cursor += 1

            let mb = (header & 0x80) != 0
            let me = (header & 0x40) != 0
            let cf = (header & 0x20) != 0
            let sr = (header & 0x10) != 0
            let il = (header & 0x08) != 0
            let tnf = header & 0x07

            if cf {
                throw DecodeError.unsupportedChunkedMessage
            }
            if payloads.isEmpty {
                if !mb {
                    throw DecodeError.missingMessageBegin
                }
                sawBegin = true
            }

            guard cursor + 1 <= message.count else { throw DecodeError.truncated }
            let typeLength = Int(message[message.startIndex + cursor])
            cursor += 1

            let payloadLength: Int
            if sr {
                guard cursor + 1 <= message.count else { throw DecodeError.truncated }
                payloadLength = Int(message[message.startIndex + cursor])
                cursor += 1
            } else {
                guard cursor + 4 <= message.count else { throw DecodeError.truncated }
                let bytes = message[message.startIndex + cursor ..< message.startIndex + cursor + 4]
                payloadLength =
                    (Int(bytes[bytes.startIndex]) << 24) |
                    (Int(bytes[bytes.startIndex + 1]) << 16) |
                    (Int(bytes[bytes.startIndex + 2]) << 8) |
                    Int(bytes[bytes.startIndex + 3])
                cursor += 4
            }

            let idLength: Int
            if il {
                guard cursor + 1 <= message.count else { throw DecodeError.truncated }
                idLength = Int(message[message.startIndex + cursor])
                cursor += 1
            } else {
                idLength = 0
            }

            guard cursor + typeLength + idLength + payloadLength <= message.count else {
                throw DecodeError.truncated
            }

            let typeBytes = message
                .subdata(in: (message.startIndex + cursor) ..< (message.startIndex + cursor + typeLength))
            cursor += typeLength
            let idBytes = message
                .subdata(in: (message.startIndex + cursor) ..< (message.startIndex + cursor + idLength))
            cursor += idLength
            let payloadBytes = message
                .subdata(in: (message.startIndex + cursor) ..< (message.startIndex + cursor + payloadLength))
            cursor += payloadLength

            payloads.append(NDEFPayload(tnf: tnf, type: typeBytes, id: idBytes, payload: payloadBytes))
            if me {
                sawEnd = true
                break
            }
        }

        if !sawBegin {
            throw DecodeError.missingMessageBegin
        }
        if !sawEnd, !payloads.isEmpty {
            throw DecodeError.missingMessageEnd
        }
        return payloads
    }

    /// Encode a stream of `NDEFPayload` into the NDEF binary format. Sets
    /// MB on the first record, ME on the last. Uses the short-record form
    /// (SR=1) for payloads ≤255 bytes.
    public static func encodePayloads(_ payloads: [NDEFPayload]) -> Data {
        var bytes = Data()
        for (index, payload) in payloads.enumerated() {
            let mb = index == 0
            let me = index == payloads.count - 1
            let sr = payload.payload.count <= 0xFF
            let il = !payload.id.isEmpty

            var header: UInt8 = payload.tnf & 0x07
            if mb {
                header |= 0x80
            }
            if me {
                header |= 0x40
            }
            if sr {
                header |= 0x10
            }
            if il {
                header |= 0x08
            }
            bytes.append(header)

            bytes.append(UInt8(payload.type.count))

            if sr {
                bytes.append(UInt8(payload.payload.count))
            } else {
                let length = UInt32(payload.payload.count)
                bytes.append(UInt8((length >> 24) & 0xFF))
                bytes.append(UInt8((length >> 16) & 0xFF))
                bytes.append(UInt8((length >> 8) & 0xFF))
                bytes.append(UInt8(length & 0xFF))
            }
            if il {
                bytes.append(UInt8(payload.id.count))
            }
            bytes.append(payload.type)
            if il {
                bytes.append(payload.id)
            }
            bytes.append(payload.payload)
        }
        return bytes
    }
}

// MARK: - NDEFRecord ↔ NDEFPayload

public extension NDEFCodec {
    static func decode(_ message: Data) throws -> [NDEFRecord] {
        // Drop NFC Forum Empty records (`D0 00 00`): a blank-but-formatted tag
        // reads back as a single one, and it is structural, not a user record —
        // surfacing it as an empty "Raw" record would be a phantom entry on every
        // erased Type-2/4/5 tag. Genuinely unformatted tags already read as zero
        // bytes upstream; this makes formatted-but-empty consistent with them.
        try decodePayloads(message)
            .filter { !$0.isEmptyRecord }
            .map(record(from:))
    }

    static func encode(_ records: [NDEFRecord]) throws -> Data {
        let payloads = try records.map(payload(from:))
        return encodePayloads(payloads)
    }

    /// Whether `message` carries no user records — an *empty* NDEF message.
    ///
    /// A cleared or freshly-erased tag surfaces "empty" in one of two
    /// spec-equivalent wire forms, depending on the chip and CoreNFC:
    ///   • zero bytes (a TLV of length 0, or CoreNFC's zero-length read), or
    ///   • a single **Empty** record — TNF 0x00, no type/id/payload, i.e.
    ///     `D0 00 00` — which is how CoreNFC actually serialises an empty
    ///     message per the NFC Forum spec, and what real tags echo back.
    ///
    /// `encode([])` produces the *zero-byte* form, so write/erase verification
    /// must use this rather than a byte-for-byte compare — otherwise a faithful
    /// "clear the tag" write fails its read-back on real hardware.
    static func isEmptyMessage(_ message: Data) -> Bool {
        if message.isEmpty {
            return true
        }
        guard let payloads = try? decodePayloads(message) else { return false }
        return payloads.allSatisfy(\.isEmptyRecord)
    }

    static func payload(from record: NDEFRecord) throws -> NDEFPayload {
        switch record {
        case .text(let r): encodeText(r)
        case .uri(let r): encodeURI(r.uri)
        case .appLink(let r): encodeURI(r.appStoreURL)
        case .social(let r): encodeURI(SocialURLBuilder.url(for: r))
        case .search(let r): encodeURI(SearchURLBuilder.url(for: r))
        case .file(let r): encodeURI(prefixedFilePath(r.path))
        case .mail(let r): encodeURI(MailURLBuilder.url(for: r))
        case .phone(let r): encodeURI("tel:\(r.number)")
        case .sms(let r): encodeURI(SMSURLBuilder.url(for: r))
        case .facetime(let r): encodeURI(FaceTimeURLBuilder.url(for: r))
        case .map(let r): encodeURI(MapURLBuilder.url(for: r))
        case .crypto(let r): encodeURI(CryptoURLBuilder.url(for: r))
        case .shortcut(let r): encodeURI(ShortcutURLBuilder.url(for: r))
        case .contact(let r): encodeVCard(r)
        case .bluetoothHandover(let r): encodeBTHandover(r)
        case .wifiWPS(let r): encodeWiFiWPS(r)

        case .data(let r): NDEFPayload(
                tnf: NDEFPayload.tnfMedia,
                type: Data(r.mimeType.utf8),
                payload: r.payload
            )

        case .raw(let r): NDEFPayload(
                tnf: r.tnf,
                type: r.typeBytes,
                id: r.idBytes,
                payload: r.payload
            )
        }
    }

    static func record(from payload: NDEFPayload) -> NDEFRecord {
        // Well-known types (TNF 0x01)
        if payload.tnf == NDEFPayload.tnfWellKnown {
            if payload.type == NDEFPayload.typeText {
                return decodeText(payload.payload)
            }
            if payload.type == NDEFPayload.typeURI {
                let uri = decodeURIString(payload.payload)
                return classifyURI(uri)
            }
        }

        // Media types (TNF 0x02)
        if payload.tnf == NDEFPayload.tnfMedia {
            let mimeType = String(data: payload.type, encoding: .utf8) ?? ""
            switch mimeType {
            case "text/vcard", "text/x-vcard":
                return decodeVCard(payload.payload)

            case "application/vnd.wfa.wsc":
                return decodeWiFiWPS(payload.payload)

            case "application/vnd.bluetooth.ep.oob":
                return decodeBTHandover(payload.payload)

            default:
                return .data(DataRecord(mimeType: mimeType, payload: payload.payload))
            }
        }

        // Everything else round-trips as a Raw record. Includes external types,
        // absolute URIs, unknown, etc. — they keep their full TNF + type + id
        // + payload, so re-encoding produces bit-identical bytes.
        return .raw(RawNDEFRecord(
            tnf: payload.tnf,
            typeBytes: payload.type,
            idBytes: payload.id,
            payload: payload.payload
        ))
    }
}

// MARK: - Text

private extension NDEFCodec {
    static func encodeText(_ record: TextRecord) -> NDEFPayload {
        let langBytes = Array(record.languageCode.utf8)
        var status = UInt8(langBytes.count & 0x3F)
        if record.encoding == .utf16 {
            status |= 0x80
        }
        var payload = Data([status])
        payload.append(contentsOf: langBytes)
        switch record.encoding {
        case .utf8:
            payload.append(Data(record.text.utf8))

        case .utf16:
            let utf16 = Array(record.text.utf16)
            for codeUnit in utf16 {
                payload.append(UInt8((codeUnit >> 8) & 0xFF))
                payload.append(UInt8(codeUnit & 0xFF))
            }
        }
        return NDEFPayload(tnf: NDEFPayload.tnfWellKnown, type: NDEFPayload.typeText, payload: payload)
    }

    static func decodeText(_ payload: Data) -> NDEFRecord {
        guard !payload.isEmpty else { return .text(TextRecord()) }
        let status = payload[payload.startIndex]
        let langLength = Int(status & 0x3F)
        let isUTF16 = (status & 0x80) != 0
        let langStart = payload.startIndex + 1
        let textStart = langStart + langLength
        guard textStart <= payload.endIndex else { return .text(TextRecord()) }
        let langBytes = payload.subdata(in: langStart ..< textStart)
        let textBytes = payload.subdata(in: textStart ..< payload.endIndex)
        let lang = String(data: langBytes, encoding: .utf8) ?? "en"

        let text = if isUTF16 {
            String(data: textBytes, encoding: .utf16BigEndian)
                ?? String(data: textBytes, encoding: .utf16) ?? ""
        } else {
            String(data: textBytes, encoding: .utf8) ?? ""
        }
        return .text(TextRecord(text: text, languageCode: lang, encoding: isUTF16 ? .utf16 : .utf8))
    }
}

// MARK: - URI

private extension NDEFCodec {
    static func encodeURI(_ uri: String) -> NDEFPayload {
        let (code, remainder) = URIPrefixTable.shortest(matchingPrefixFor: uri)
        var payload = Data([code])
        payload.append(Data(remainder.utf8))
        return NDEFPayload(tnf: NDEFPayload.tnfWellKnown, type: NDEFPayload.typeURI, payload: payload)
    }

    static func decodeURIString(_ payload: Data) -> String {
        guard !payload.isEmpty else { return "" }
        let prefixByte = payload[payload.startIndex]
        let remainder = payload.subdata(in: (payload.startIndex + 1) ..< payload.endIndex)
        let remainderString = String(data: remainder, encoding: .utf8) ?? ""
        return URIPrefixTable.prefix(for: prefixByte) + remainderString
    }

    /// Inspect the URI scheme and route to the most specific record case.
    /// Anything that doesn't match falls back to a plain `.uri` — never
    /// `.raw`, because URIs are a well-known type and re-encode losslessly.
    static func classifyURI(_ uri: String) -> NDEFRecord {
        let scheme = uri.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        switch scheme {
        case "tel":
            return .phone(PhoneRecord(number: String(uri.dropFirst("tel:".count))))

        case "sms", "smsto":
            return SMSURLBuilder.record(from: uri)

        case "mailto":
            return MailURLBuilder.record(from: uri)

        case "facetime", "facetime-audio":
            return FaceTimeURLBuilder.record(from: uri)

        case "geo":
            return MapURLBuilder.record(from: uri)

        case "bitcoin", "ethereum", "monero", "litecoin", "dogecoin", "solana":
            return CryptoURLBuilder.record(from: uri, scheme: scheme)

        case "shortcuts":
            return ShortcutURLBuilder.record(from: uri)

        case "file":
            return .file(FileRecord(path: String(uri.dropFirst("file://".count))))

        default:
            return .uri(URIRecord(uri: uri))
        }
    }

    static func prefixedFilePath(_ path: String) -> String {
        if path.hasPrefix("file://") {
            return path
        }
        return "file://" + (path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}

// MARK: - vCard

private extension NDEFCodec {
    static func encodeVCard(_ record: VCardRecord) -> NDEFPayload {
        var lines = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "FN:\(record.formattedName)",
        ]
        if let org = record.organization, !org.isEmpty {
            lines.append("ORG:\(org)")
        }
        for tel in record.phones {
            lines.append("TEL:\(tel)")
        }
        for email in record.emails {
            lines.append("EMAIL:\(email)")
        }
        for url in record.websites {
            lines.append("URL:\(url)")
        }
        for adr in record.addresses {
            lines.append("ADR:;;\(adr);;;;")
        }
        if let photoURL = record.photoURL, !photoURL.isEmpty {
            lines.append("PHOTO;VALUE=URI:\(photoURL)")
        }
        lines.append("END:VCARD")
        let body = lines.joined(separator: "\r\n")
        return NDEFPayload(tnf: NDEFPayload.tnfMedia, type: NDEFPayload.typeVCard, payload: Data(body.utf8))
    }

    static func decodeVCard(_ payload: Data) -> NDEFRecord {
        let body = String(data: payload, encoding: .utf8) ?? ""
        var record = VCardRecord()
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { continue }
            // Strip any vCard "parameters" after a semicolon in the key half.
            let keyHalf = String(trimmed[..<colon])
            let value = String(trimmed[trimmed.index(after: colon)...])
            let key = (keyHalf.components(separatedBy: ";").first ?? keyHalf).uppercased()
            switch key {
            case "FN": record.formattedName = value
            case "ORG": record.organization = value
            case "TEL": record.phones.append(value)
            case "EMAIL": record.emails.append(value)
            case "URL": record.websites.append(value)

            case "ADR":
                let pieces = value.components(separatedBy: ";")
                if pieces.count > 2 {
                    record.addresses.append(pieces[2])
                }

            case "PHOTO": record.photoURL = value
            default: break
            }
        }
        return .contact(record)
    }
}

// MARK: - Wi-Fi WPS

/// Wi-Fi Simple Configuration (`application/vnd.wfa.wsc`) uses a TLV-coded
/// "credential" attribute (`0x100E`) wrapping SSID, auth, encryption, network
/// key, MAC address. We encode a minimal subset; full WSC support is a
/// Phase 3 task.
private extension NDEFCodec {
    static func encodeWiFiWPS(_ record: WiFiWPSRecord) -> NDEFPayload {
        var credentialAttrs = Data()
        credentialAttrs.append(wpsTLV(0x1045, value: Data(record.ssid.utf8))) // SSID
        credentialAttrs.append(wpsTLV(0x1003, value: wpsAuthType(record.authentication))) // Authentication
        credentialAttrs.append(wpsTLV(0x100F, value: wpsEncryptionType(record.encryption))) // Encryption
        credentialAttrs.append(wpsTLV(0x1027, value: Data(record.password.utf8))) // Network key
        credentialAttrs.append(wpsTLV(0x1020, value: Data([0, 0, 0, 0, 0, 0]))) // MAC (zeros: broadcast)
        let credential = wpsTLV(0x100E, value: credentialAttrs)
        return NDEFPayload(tnf: NDEFPayload.tnfMedia, type: NDEFPayload.typeWPS, payload: credential)
    }

    static func decodeWiFiWPS(_ payload: Data) -> NDEFRecord {
        var record = WiFiWPSRecord()
        // Walk into the credential attribute, then walk its inner TLVs.
        let outer = parseWPSAttributes(payload)
        guard let credentialBytes = outer.first(where: { $0.type == 0x100E })?.value else {
            return .wifiWPS(record)
        }
        for attr in parseWPSAttributes(credentialBytes) {
            switch attr.type {
            case 0x1045:
                record.ssid = String(data: attr.value, encoding: .utf8) ?? ""

            case 0x1027:
                record.password = String(data: attr.value, encoding: .utf8) ?? ""

            case 0x1003:
                record.authentication = wpsAuthFromBytes(attr.value)

            case 0x100F:
                record.encryption = wpsEncryptionFromBytes(attr.value)

            default:
                break
            }
        }
        return .wifiWPS(record)
    }

    static func wpsTLV(_ type: UInt16, value: Data) -> Data {
        var data = Data()
        data.append(UInt8((type >> 8) & 0xFF))
        data.append(UInt8(type & 0xFF))
        let length = UInt16(value.count)
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(value)
        return data
    }

    static func parseWPSAttributes(_ payload: Data) -> [(type: UInt16, value: Data)] {
        var attrs: [(UInt16, Data)] = []
        var cursor = payload.startIndex
        while cursor + 4 <= payload.endIndex {
            let type = (UInt16(payload[cursor]) << 8) | UInt16(payload[cursor + 1])
            let length = (UInt16(payload[cursor + 2]) << 8) | UInt16(payload[cursor + 3])
            let valueStart = cursor + 4
            let valueEnd = valueStart + Int(length)
            guard valueEnd <= payload.endIndex else { break }
            attrs.append((type, payload.subdata(in: valueStart ..< valueEnd)))
            cursor = valueEnd
        }
        return attrs
    }

    static func wpsAuthType(_ auth: WiFiWPSRecord.Authentication) -> Data {
        // 16-bit big-endian per the WSC spec; we use the canonical bitfield values.
        let value: UInt16 = switch auth {
        case .open: 0x0001
        case .wpaPersonal: 0x0002
        case .wpa2Personal: 0x0020
        case .wpa3Personal: 0x0040 // WPA3 / SAE
        case .wep: 0x0008
        }
        return Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func wpsAuthFromBytes(_ data: Data) -> WiFiWPSRecord.Authentication {
        guard data.count == 2 else { return .open }
        let value = (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.startIndex + 1])
        switch value {
        case 0x0002: return .wpaPersonal
        case 0x0020: return .wpa2Personal
        case 0x0040: return .wpa3Personal
        case 0x0008: return .wep
        default: return .open
        }
    }

    static func wpsEncryptionType(_ enc: WiFiWPSRecord.Encryption) -> Data {
        let value: UInt16 = switch enc {
        case .none: 0x0001
        case .wep: 0x0002
        case .tkip: 0x0004
        case .aes: 0x0008
        case .tkipAes: 0x000C
        }
        return Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func wpsEncryptionFromBytes(_ data: Data) -> WiFiWPSRecord.Encryption {
        guard data.count == 2 else { return .none }
        let value = (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.startIndex + 1])
        switch value {
        case 0x0002: return .wep
        case 0x0004: return .tkip
        case 0x0008: return .aes
        case 0x000C: return .tkipAes
        default: return .none
        }
    }
}

// MARK: - BT handover

/// Bluetooth OOB pairing records use a length-prefixed sequence of EIR
/// fields. We encode the address + optional name; full carrier-config
/// support (RandR/RandLR, class-of-device) is a Phase 3 task.
private extension NDEFCodec {
    static func encodeBTHandover(_ record: BTHandoverRecord) -> NDEFPayload {
        let mac = parseMAC(record.deviceMAC)
        var oob = Data()
        // 2-byte length-of-OOB-data placeholder; filled after the rest.
        oob.append(contentsOf: [0, 0])
        oob.append(mac)
        if let name = record.deviceName, !name.isEmpty {
            let nameBytes = Data(name.utf8)
            // EIR field: length, type 0x09 = complete local name
            oob.append(UInt8(nameBytes.count + 1))
            oob.append(0x09)
            oob.append(nameBytes)
        }
        // Fill the length prefix (little-endian per the spec).
        let length = UInt16(oob.count)
        oob[oob.startIndex] = UInt8(length & 0xFF)
        oob[oob.startIndex + 1] = UInt8((length >> 8) & 0xFF)
        return NDEFPayload(tnf: NDEFPayload.tnfMedia, type: NDEFPayload.typeBTOOB, payload: oob)
    }

    static func decodeBTHandover(_ payload: Data) -> NDEFRecord {
        guard payload.count >= 8 else { return .bluetoothHandover(BTHandoverRecord()) }
        // Skip 2-byte length prefix, read 6-byte MAC (little-endian on the wire,
        // big-endian when displayed).
        let macBytes = payload.subdata(in: (payload.startIndex + 2) ..< (payload.startIndex + 8))
        let mac = macBytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")

        var name: String?
        var cursor = payload.startIndex + 8
        while cursor < payload.endIndex {
            let length = Int(payload[cursor])
            guard length > 0, cursor + 1 + length <= payload.endIndex else { break }
            let type = payload[cursor + 1]
            let value = payload.subdata(in: (cursor + 2) ..< (cursor + 1 + length))
            if type == 0x09 || type == 0x08 { // complete or short name
                name = String(data: value, encoding: .utf8)
            }
            cursor += 1 + length
        }
        return .bluetoothHandover(BTHandoverRecord(deviceMAC: mac, deviceName: name))
    }

    static func parseMAC(_ mac: String) -> Data {
        let cleaned = mac.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex, let nextIndex = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) {
            let pair = cleaned[index ..< nextIndex]
            if let byte = UInt8(pair, radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        // Wire order is little-endian, displayed colon-form is big-endian.
        bytes.reverse()
        // Pad to 6 bytes.
        while bytes.count < 6 {
            bytes.append(0)
        }
        return Data(bytes.prefix(6))
    }
}

// MARK: - URI scheme builders

enum SocialURLBuilder {
    static func url(for record: SocialRecord) -> String {
        let handle = record.handle
        switch record.platform {
        case .facebook: return "https://facebook.com/\(handle)"
        case .bluesky: return "https://bsky.app/profile/\(handle)"
        case .x: return "https://x.com/\(handle)"
        case .github: return "https://github.com/\(handle)"
        case .instagram: return "https://instagram.com/\(handle)"
        case .line: return "https://line.me/ti/p/~\(handle)"
        case .linkedin: return "https://linkedin.com/in/\(handle)"
        case .medium: return "https://medium.com/@\(handle)"
        case .pinterest: return "https://pinterest.com/\(handle)"
        case .skype: return "skype:\(handle)?call"
        case .slack: return "https://\(handle).slack.com"
        case .snapchat: return "https://snapchat.com/add/\(handle)"
        case .soundcloud: return "https://soundcloud.com/\(handle)"
        case .steam: return "https://steamcommunity.com/id/\(handle)"
        case .telegram: return "https://t.me/\(handle)"
        case .threads: return "https://threads.net/@\(handle)"
        case .tiktok: return "https://tiktok.com/@\(handle)"
        case .twitch: return "https://twitch.tv/\(handle)"
        case .vk: return "https://vk.com/\(handle)"
        case .wechat: return "weixin://dl/chat?\(handle)"
        case .whatsapp: return "https://wa.me/\(handle)"
        case .youtube: return "https://youtube.com/@\(handle)"
        }
    }
}

enum SearchURLBuilder {
    static func url(for record: SearchRecord) -> String {
        let encoded = record.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? record.query
        switch record.engine {
        case .google: return "https://www.google.com/search?q=\(encoded)"
        case .googleImages: return "https://www.google.com/images?q=\(encoded)"
        case .bing: return "https://www.bing.com/search?q=\(encoded)"
        case .yandex: return "https://yandex.com/search/?text=\(encoded)"
        case .duckduckgo: return "https://duckduckgo.com/?q=\(encoded)"
        case .youtube: return "https://www.youtube.com/results?search_query=\(encoded)"
        case .wikipedia: return "https://en.wikipedia.org/wiki/Special:Search?search=\(encoded)"
        }
    }
}

enum MailURLBuilder {
    static func url(for record: MailRecord) -> String {
        var url = "mailto:" + record.to.joined(separator: ",")
        var query: [String] = []
        if !record.cc.isEmpty {
            query.append("cc=\(percentEncoded(record.cc.joined(separator: ",")))")
        }
        if !record.bcc.isEmpty {
            query.append("bcc=\(percentEncoded(record.bcc.joined(separator: ",")))")
        }
        if !record.subject.isEmpty {
            query.append("subject=\(percentEncoded(record.subject))")
        }
        if !record.body.isEmpty {
            query.append("body=\(percentEncoded(record.body))")
        }
        if !query.isEmpty {
            url += "?" + query.joined(separator: "&")
        }
        return url
    }

    static func record(from uri: String) -> NDEFRecord {
        let trimmed = uri.dropFirst("mailto:".count)
        let parts = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let to = parts.first.map { $0.split(separator: ",").map(String.init) } ?? []
        var record = MailRecord(to: to)
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let value = percentDecoded(String(kv[1]))
                switch kv[0] {
                case "cc": record.cc = value.split(separator: ",").map(String.init)
                case "bcc": record.bcc = value.split(separator: ",").map(String.init)
                case "subject": record.subject = value
                case "body": record.body = value
                default: break
                }
            }
        }
        return .mail(record)
    }
}

enum SMSURLBuilder {
    static func url(for record: SMSRecord) -> String {
        let base = "sms:\(record.number)"
        guard !record.body.isEmpty else { return base }
        return "\(base)?body=\(percentEncoded(record.body))"
    }

    static func record(from uri: String) -> NDEFRecord {
        let prefix = uri.hasPrefix("smsto:") ? "smsto:" : "sms:"
        let trimmed = String(uri.dropFirst(prefix.count))
        let parts = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let number = parts.first.map(String.init) ?? ""
        var body = ""
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "body" {
                    body = percentDecoded(String(kv[1]))
                }
            }
        }
        return .sms(SMSRecord(number: number, body: body))
    }
}

enum FaceTimeURLBuilder {
    static func url(for record: FaceTimeRecord) -> String {
        let scheme = record.mode == .audio ? "facetime-audio" : "facetime"
        return "\(scheme):\(record.target)"
    }

    static func record(from uri: String) -> NDEFRecord {
        let mode: FaceTimeRecord.Mode = uri.hasPrefix("facetime-audio:") ? .audio : .video
        let target = String(uri.split(separator: ":", maxSplits: 1).dropFirst().first ?? "")
        return .facetime(FaceTimeRecord(target: target, mode: mode))
    }
}

public extension MapRecord {
    /// Whether this record says where it points: a map URL, or both a
    /// latitude and a longitude.
    ///
    /// Follows `MapURLBuilder.url(for:)` branch for branch, so it answers for
    /// what would actually go onto a tag. The builder fills a missing
    /// coordinate with 0, so a record with neither a URL nor both coordinates
    /// comes out as `geo:0,0` or a point on the equator or the prime meridian:
    /// real places, which a reading phone opens as if they were meant. Two
    /// kinds of record get there. One is a Location added and never filled
    /// in. The other was saved with the withdrawn `.currentLocation` source,
    /// which never carried coordinates, because the app has no location
    /// access to fill them from. `WriteFlowModel` refuses both before a
    /// session opens.
    var hasLocation: Bool {
        if let raw = rawURL, !raw.isEmpty {
            return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return latitude != nil && longitude != nil
    }
}

enum MapURLBuilder {
    static func url(for record: MapRecord) -> String {
        if let raw = record.rawURL, !raw.isEmpty {
            return raw
        }
        let lat = record.latitude ?? 0
        let lon = record.longitude ?? 0
        return String(format: "geo:%.6f,%.6f", lat, lon)
    }

    static func record(from uri: String) -> NDEFRecord {
        // geo:LAT,LON or geo:LAT,LON?q=...
        let trimmed = uri.dropFirst("geo:".count).split(separator: "?", maxSplits: 1).first ?? ""
        let coords = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
        if coords.count == 2, let lat = Double(coords[0]), let lon = Double(coords[1]) {
            return .map(MapRecord(source: .coordinate, latitude: lat, longitude: lon))
        }
        return .map(MapRecord(source: .appleMaps, rawURL: uri))
    }
}

enum CryptoURLBuilder {
    static func url(for record: CryptoURIRecord) -> String {
        let scheme = switch record.network {
        case .bitcoin: "bitcoin"
        case .ethereum: "ethereum"
        case .monero: "monero"
        case .litecoin: "litecoin"
        case .dogecoin: "dogecoin"
        case .solana: "solana"
        }
        var url = "\(scheme):\(record.address)"
        var query: [String] = []
        if let amount = record.amount, !amount.isEmpty {
            query.append("amount=\(percentEncoded(amount))")
        }
        if let message = record.message, !message.isEmpty {
            query.append("message=\(percentEncoded(message))")
        }
        if !query.isEmpty {
            url += "?" + query.joined(separator: "&")
        }
        return url
    }

    static func record(from uri: String, scheme: String) -> NDEFRecord {
        let network: CryptoNetwork = switch scheme {
        case "bitcoin": .bitcoin
        case "ethereum": .ethereum
        case "monero": .monero
        case "litecoin": .litecoin
        case "dogecoin": .dogecoin
        case "solana": .solana
        default: .bitcoin
        }
        let trimmed = uri.dropFirst(scheme.count + 1)
        let parts = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let address = parts.first.map(String.init) ?? ""
        var amount: String?
        var message: String?
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let value = percentDecoded(String(kv[1]))
                switch kv[0] {
                case "amount": amount = value
                case "message": message = value
                default: break
                }
            }
        }
        return .crypto(CryptoURIRecord(network: network, address: address, amount: amount, message: message))
    }
}

enum ShortcutURLBuilder {
    static func url(for record: ShortcutRecord) -> String {
        let name = percentEncoded(record.shortcutName)
        if let input = record.input, !input.isEmpty {
            return "shortcuts://run-shortcut?name=\(name)&input=\(percentEncoded(input))"
        }
        return "shortcuts://run-shortcut?name=\(name)"
    }

    static func record(from uri: String) -> NDEFRecord {
        // shortcuts://run-shortcut?name=NAME&input=INPUT
        guard let queryStart = uri.firstIndex(of: "?") else {
            return .shortcut(ShortcutRecord())
        }
        var name = ""
        var input: String?
        for pair in uri[uri.index(after: queryStart)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = percentDecoded(String(kv[1]))
            switch kv[0] {
            case "name": name = value
            case "input": input = value
            default: break
            }
        }
        return .shortcut(ShortcutRecord(shortcutName: name, input: input))
    }
}

// MARK: - Local helpers

private func percentEncoded(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}

private func percentDecoded(_ s: String) -> String {
    s.removingPercentEncoding ?? s
}
