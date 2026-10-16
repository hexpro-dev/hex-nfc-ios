@testable import HexNFCStorage
import XCTest

final class HexNFCStorageTests: XCTestCase {
    func test_moduleMarker() {
        XCTAssertEqual(HexNFCStorage.moduleName, "HexNFCStorage")
    }
}
