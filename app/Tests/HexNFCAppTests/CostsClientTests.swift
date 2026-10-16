@testable import HexNFCApp
import XCTest

final class CostsClientTests: XCTestCase {
    private func httpResponse(status: Int) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: CostsClient.endpoint,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        ) else {
            fatalError("HTTPURLResponse rejected status \(status) for \(CostsClient.endpoint)")
        }
        return response
    }

    func test_decode_validPayload_mapsFields() {
        let json = #"{"slug":"hex-nfc","currency":"AUD","totalCost":280.02,"totalDonations":30,"lineItems":[]}"#
        let result = CostsClient.decode(
            data: Data(json.utf8),
            response: httpResponse(status: 200)
        )
        XCTAssertEqual(result, DonationProgress(donated: 30, total: 280.02, currency: "AUD"))
    }

    func test_decode_non200_returnsFallback() {
        let json = #"{"currency":"USD","totalCost":999,"totalDonations":500}"#
        let result = CostsClient.decode(
            data: Data(json.utf8),
            response: httpResponse(status: 503)
        )
        XCTAssertEqual(result, .fallback)
    }

    func test_decode_malformedData_returnsFallback() {
        let result = CostsClient.decode(
            data: Data("not json".utf8),
            response: httpResponse(status: 200)
        )
        XCTAssertEqual(result, .fallback)
    }

    func test_decode_nilResponse_returnsFallback() {
        let result = CostsClient.decode(data: Data(), response: nil)
        XCTAssertEqual(result, .fallback)
    }

    func test_fallback_isZeroOfTwoEighty() {
        XCTAssertEqual(DonationProgress.fallback.donated, 0)
        XCTAssertEqual(DonationProgress.fallback.total, 280.02)
        XCTAssertEqual(DonationProgress.fallback.percent, 0)
        XCTAssertEqual(DonationProgress.fallback.fraction, 0, accuracy: 0.0001)
    }

    func test_fraction_clampsAndHandlesZeroTotal() {
        XCTAssertEqual(DonationProgress(donated: 5, total: 0, currency: "AUD").fraction, 0)
        XCTAssertEqual(DonationProgress(donated: 300, total: 150, currency: "AUD").fraction, 1)
    }
}
