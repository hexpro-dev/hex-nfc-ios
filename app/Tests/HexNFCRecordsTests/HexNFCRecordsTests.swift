@testable import HexNFCRecords
import XCTest

final class HexNFCRecordsTests: XCTestCase {
    func test_moduleMarker() {
        XCTAssertEqual(HexNFCRecords.moduleName, "HexNFCRecords")
    }

    // MARK: - URI prefix table

    func test_uriPrefix_shortestMatch_picksLongest() {
        let (code, remainder) = URIPrefixTable.shortest(matchingPrefixFor: "https://www.hex.pro")
        XCTAssertEqual(code, 0x02)
        XCTAssertEqual(remainder, "hex.pro")
    }

    func test_uriPrefix_noMatch_returnsZero() {
        let (code, remainder) = URIPrefixTable.shortest(matchingPrefixFor: "bitcoin:bc1qxyz")
        XCTAssertEqual(code, 0x00)
        XCTAssertEqual(remainder, "bitcoin:bc1qxyz")
    }

    func test_uriPrefix_roundTrip() {
        for raw in ["https://hex.pro", "http://www.example.com", "mailto:someone@example.com", "tel:+15551234"] {
            let (code, remainder) = URIPrefixTable.shortest(matchingPrefixFor: raw)
            let reconstructed = URIPrefixTable.prefix(for: code) + remainder
            XCTAssertEqual(reconstructed, raw, "round trip failed for \(raw)")
        }
    }

    // MARK: - Template engine

    func test_template_uid_default() throws {
        let uid = Data([0x04, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6])
        let context = TemplateContext(uid: uid, counter: 42, now: Date(timeIntervalSince1970: 0))
        let result = try TemplateEngine.render("Tag {uid}", context: context)
        XCTAssertEqual(result, "Tag 04A1B2C3D4E5F6")
    }

    func test_template_uid_withColonFormat() throws {
        let uid = Data([0x04, 0xA1, 0xB2])
        let context = TemplateContext(uid: uid)
        XCTAssertEqual(try TemplateEngine.render("{uid:colon}", context: context), "04:A1:B2")
    }

    func test_template_counter_zeroPadded() throws {
        let context = TemplateContext(uid: Data(), counter: 5)
        XCTAssertEqual(try TemplateEngine.render("#{counter}", context: context), "#000005")
    }

    func test_template_unknownPlaceholder_throws() {
        let context = TemplateContext(uid: Data())
        XCTAssertThrowsError(try TemplateEngine.render("{nonsense}", context: context)) { error in
            guard case TemplateEngine.RenderError.unknownPlaceholder(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "nonsense")
        }
    }

    func test_template_random_isLengthControlled() throws {
        let bytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let context = TemplateContext(uid: Data(), randomBytes: { _ in bytes })
        let result = try TemplateEngine.render("{random:4}", context: context)
        XCTAssertEqual(result, "AABBCCDD")
    }

    // MARK: - NDEF codec round trips

    func test_text_roundTrip() throws {
        let record = NDEFRecord.text(TextRecord(text: "Hello, world", languageCode: "en", encoding: .utf8))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        XCTAssertEqual(decoded.count, 1)
        guard case .text(let textRecord) = decoded[0] else { return XCTFail("expected text") }
        XCTAssertEqual(textRecord.text, "Hello, world")
        XCTAssertEqual(textRecord.languageCode, "en")
        XCTAssertEqual(textRecord.encoding, .utf8)
    }

    func test_uri_roundTrip() throws {
        let record = NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))
        let encoded = try NDEFCodec.encode([record])
        XCTAssertLessThan(encoded.count, 32, "URI prefix shortening should keep this tiny")
        let decoded = try NDEFCodec.decode(encoded)
        guard case .uri(let uriRecord) = decoded[0] else { return XCTFail("expected uri") }
        XCTAssertEqual(uriRecord.uri, "https://hex.pro")
    }

    func test_phoneURI_classifiesAsPhone() throws {
        let record = NDEFRecord.phone(PhoneRecord(number: "+15551234"))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        guard case .phone(let phone) = decoded[0] else { return XCTFail("expected phone") }
        XCTAssertEqual(phone.number, "+15551234")
    }

    func test_mailURI_classifiesAsMail() throws {
        let record = NDEFRecord.mail(MailRecord(to: ["someone@example.com"], subject: "Hi", body: "How are you?"))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        guard case .mail(let mail) = decoded[0] else { return XCTFail("expected mail") }
        XCTAssertEqual(mail.to, ["someone@example.com"])
        XCTAssertEqual(mail.subject, "Hi")
        XCTAssertEqual(mail.body, "How are you?")
    }

    func test_smsURI_classifiesAsSMS() throws {
        let record = NDEFRecord.sms(SMSRecord(number: "+15551234", body: "Hello"))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        guard case .sms(let sms) = decoded[0] else { return XCTFail("expected sms") }
        XCTAssertEqual(sms.number, "+15551234")
        XCTAssertEqual(sms.body, "Hello")
    }

    func test_vCard_roundTrip() throws {
        let record = NDEFRecord.contact(VCardRecord(
            formattedName: "Matthew Scott",
            organization: "Hex Pro",
            phones: ["+61400000000"],
            emails: ["someone@example.com"],
            websites: ["https://hex.pro"]
        ))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        guard case .contact(let card) = decoded[0] else { return XCTFail("expected contact") }
        XCTAssertEqual(card.formattedName, "Matthew Scott")
        XCTAssertEqual(card.organization, "Hex Pro")
        XCTAssertEqual(card.phones, ["+61400000000"])
        XCTAssertEqual(card.emails, ["someone@example.com"])
        XCTAssertEqual(card.websites, ["https://hex.pro"])
    }

    func test_wifiWPS_roundTrip() throws {
        let record = NDEFRecord.wifiWPS(WiFiWPSRecord(
            ssid: "HexProGuest",
            authentication: .wpa2Personal,
            encryption: .aes,
            password: "supersecret"
        ))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        guard case .wifiWPS(let wifi) = decoded[0] else { return XCTFail("expected wifi") }
        XCTAssertEqual(wifi.ssid, "HexProGuest")
        XCTAssertEqual(wifi.authentication, .wpa2Personal)
        XCTAssertEqual(wifi.encryption, .aes)
        XCTAssertEqual(wifi.password, "supersecret")
    }

    func test_crypto_roundTrip() throws {
        let record = NDEFRecord.crypto(CryptoURIRecord(
            network: .bitcoin,
            address: "bc1qxyz",
            amount: "0.001",
            message: "thanks"
        ))
        let encoded = try NDEFCodec.encode([record])
        let decoded = try NDEFCodec.decode(encoded)
        guard case .crypto(let crypto) = decoded[0] else { return XCTFail("expected crypto") }
        XCTAssertEqual(crypto.network, .bitcoin)
        XCTAssertEqual(crypto.address, "bc1qxyz")
        XCTAssertEqual(crypto.amount, "0.001")
        XCTAssertEqual(crypto.message, "thanks")
    }

    func test_multiRecord_messageBeginEnd() throws {
        let records: [NDEFRecord] = [
            .text(TextRecord(text: "First")),
            .uri(URIRecord(uri: "https://hex.pro")),
            .text(TextRecord(text: "Last")),
        ]
        let encoded = try NDEFCodec.encode(records)
        XCTAssertTrue((encoded[0] & 0x80) != 0, "MB must be set on first record")
        let decoded = try NDEFCodec.decode(encoded)
        XCTAssertEqual(decoded.count, 3)
    }

    func test_codec_decodeRejectsTruncated() {
        let almostEmpty = Data([0xD1, 0x01]) // header + type length, no payload-length / type / payload
        XCTAssertThrowsError(try NDEFCodec.decodePayloads(almostEmpty))
    }

    // MARK: - Empty (TNF 0x00) records — formatted-but-blank tags

    func test_decode_dropsLoneEmptyRecord() throws {
        // A blank-but-formatted Type-2/4/5 tag reads back as a single NFC Forum
        // Empty record `D0 00 00`, NOT as zero bytes. It carries no user data, so
        // the scan card must show ZERO records — not a phantom empty "Raw" entry.
        let emptyMessage = Data([0xD0, 0x00, 0x00])
        let decoded = try NDEFCodec.decode(emptyMessage)
        XCTAssertEqual(decoded.count, 0, "lone Empty record must decode to zero user records")
        // It is still structurally an empty message for write/erase verification.
        XCTAssertTrue(NDEFCodec.isEmptyMessage(emptyMessage))
        // And the low-level payload view still sees it (the bridge re-encodes it).
        XCTAssertEqual(try NDEFCodec.decodePayloads(emptyMessage).count, 1)
    }

    func test_decode_dropsEmptyRecordButKeepsRealOnes() throws {
        // A trailing/interleaved Empty record alongside real content is structural
        // padding — drop only the empties, keep the user records intact.
        let payloads = [
            NDEFPayload(tnf: NDEFPayload.tnfEmpty, type: Data(), payload: Data()),
            NDEFPayload(tnf: NDEFPayload.tnfWellKnown, type: NDEFPayload.typeURI,
                        payload: Data([0x04]) + Data("hex.pro".utf8)), // 0x04 = https://
            NDEFPayload(tnf: NDEFPayload.tnfEmpty, type: Data(), payload: Data()),
        ]
        let decoded = try NDEFCodec.decode(NDEFCodec.encodePayloads(payloads))
        XCTAssertEqual(decoded.count, 1, "only the real URI record survives")
        guard case .uri = decoded[0] else { return XCTFail("expected the surviving record to be the URI") }
    }

    func test_isEmptyRecord_predicate() {
        XCTAssertTrue(NDEFPayload(tnf: 0x00, type: Data(), payload: Data()).isEmptyRecord)
        // A non-zero TNF, or any type/payload bytes, means it carries content.
        XCTAssertFalse(NDEFPayload(tnf: 0x01, type: Data(), payload: Data()).isEmptyRecord)
        XCTAssertFalse(NDEFPayload(tnf: 0x00, type: Data("T".utf8), payload: Data()).isEmptyRecord)
        XCTAssertFalse(NDEFPayload(tnf: 0x00, type: Data(), payload: Data([0x01])).isEmptyRecord)
    }

    // MARK: - JSON discriminator

    func test_jsonEncoding_carriesTypeDiscriminator() throws {
        let record = NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(record)
        let asString = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(asString.contains(#""type":"uri""#), "got: \(asString)")
        XCTAssertTrue(asString.contains(#""uri":"https:\/\/hex.pro""#), "got: \(asString)")

        let decoder = JSONDecoder()
        let round = try decoder.decode(NDEFRecord.self, from: json)
        guard case .uri(let r) = round else { return XCTFail("type discriminator mis-routed") }
        XCTAssertEqual(r.uri, "https://hex.pro")
    }
}
