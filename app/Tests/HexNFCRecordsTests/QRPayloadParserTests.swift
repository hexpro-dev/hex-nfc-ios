@testable import HexNFCRecords
import XCTest

final class QRPayloadParserTests: XCTestCase {
    func test_parseURL_yieldsURIRecord() {
        let record = QRPayloadParser.parse("https://hex.pro")
        guard case .uri(let uri) = record else { return XCTFail("expected uri, got \(record)") }
        XCTAssertEqual(uri.uri, "https://hex.pro")
    }

    func test_parsePlainText_yieldsTextRecord() {
        let record = QRPayloadParser.parse("hello world")
        guard case .text(let text) = record else { return XCTFail("expected text, got \(record)") }
        XCTAssertEqual(text.text, "hello world")
    }

    func test_parseEmpty_yieldsEmptyText() {
        let record = QRPayloadParser.parse("   ")
        guard case .text(let text) = record else { return XCTFail("expected text") }
        XCTAssertEqual(text.text, "")
    }

    // MARK: Wi-Fi

    func test_parseWiFi_wpaWithPassword() {
        let record = QRPayloadParser.parse("WIFI:T:WPA;S:OfficeNet;P:hunter2;;")
        guard case .wifiWPS(let wifi) = record else { return XCTFail("expected wifi") }
        XCTAssertEqual(wifi.ssid, "OfficeNet")
        XCTAssertEqual(wifi.password, "hunter2")
        XCTAssertEqual(wifi.authentication, .wpa2Personal)
        XCTAssertEqual(wifi.encryption, .aes)
        XCTAssertFalse(wifi.isHidden)
    }

    func test_parseWiFi_openNetwork() {
        let record = QRPayloadParser.parse("WIFI:T:nopass;S:Cafe;;")
        guard case .wifiWPS(let wifi) = record else { return XCTFail("expected wifi") }
        XCTAssertEqual(wifi.authentication, .open)
        XCTAssertEqual(wifi.password, "")
    }

    func test_parseWiFi_hiddenNetworkFlag() {
        let record = QRPayloadParser.parse("WIFI:T:WPA;S:Secret;P:pw;H:true;;")
        guard case .wifiWPS(let wifi) = record else { return XCTFail("expected wifi") }
        XCTAssertTrue(wifi.isHidden)
    }

    func test_parseWiFi_missingSSID_fallsThroughToText() {
        let record = QRPayloadParser.parse("WIFI:T:WPA;P:pw;;")
        guard case .text = record else { return XCTFail("expected text fallthrough, got \(record)") }
    }

    // MARK: vCard

    func test_parseVCard_extractsCommonFields() {
        let raw = """
        BEGIN:VCARD
        VERSION:3.0
        FN:Jane Doe
        ORG:Hex Pro
        TEL:+15551234567
        EMAIL:jane@hex.pro
        URL:https://hex.pro
        END:VCARD
        """
        let record = QRPayloadParser.parse(raw)
        guard case .contact(let v) = record else { return XCTFail("expected contact") }
        XCTAssertEqual(v.formattedName, "Jane Doe")
        XCTAssertEqual(v.organization, "Hex Pro")
        XCTAssertEqual(v.phones, ["+15551234567"])
        XCTAssertEqual(v.emails, ["jane@hex.pro"])
        XCTAssertEqual(v.websites, ["https://hex.pro"])
    }

    // MARK: tel / sms / mailto / geo

    func test_parseTel() {
        guard case .phone(let p) = QRPayloadParser.parse("tel:+15551234567") else {
            return XCTFail("expected phone")
        }
        XCTAssertEqual(p.number, "+15551234567")
    }

    func test_parseSMS_withQuery() {
        guard case .sms(let s) = QRPayloadParser.parse("sms:+15551234567?body=hello%20there") else {
            return XCTFail("expected sms")
        }
        XCTAssertEqual(s.number, "+15551234567")
        XCTAssertEqual(s.body, "hello there")
    }

    func test_parseSMS_smstoFormat() {
        guard case .sms(let s) = QRPayloadParser.parse("SMSTO:+15551234567:hello") else {
            return XCTFail("expected sms")
        }
        XCTAssertEqual(s.number, "+15551234567")
        XCTAssertEqual(s.body, "hello")
    }

    func test_parseMailto_subjectAndBody() {
        guard case .mail(let m) = QRPayloadParser.parse("mailto:a@b.com?subject=Hi&body=Hello") else {
            return XCTFail("expected mail")
        }
        XCTAssertEqual(m.to, ["a@b.com"])
        XCTAssertEqual(m.subject, "Hi")
        XCTAssertEqual(m.body, "Hello")
    }

    func test_parseGeo() {
        guard case .map(let geo) = QRPayloadParser.parse("geo:-33.8688,151.2093") else {
            return XCTFail("expected map")
        }
        XCTAssertEqual(geo.source, .coordinate)
        XCTAssertEqual(geo.latitude ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(geo.longitude ?? 0, 151.2093, accuracy: 0.0001)
    }
}
