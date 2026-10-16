@testable import HexNFCApp
import HexNFCRecords
import XCTest

/// What the record screens offer for 1.0, and what they no longer do.
///
/// App Review held 1.0 under Guideline 2.1. Five record types had no form and
/// opened as JSON under a note saying a specialised editor was "not yet
/// available", the Location form offered a "Current location" that found
/// nothing, and the Info.plist asked for contacts, location and Bluetooth
/// access the app never requests. `AddRecordSheet` and `RecordEditorSheet`
/// open with `#if os(iOS)`, so the lists they show live in `RecordOffering`,
/// where these tests can reach them; the wiring inside the screens is read off
/// disk, in the idiom of `EditorWriteGateSourceTests`.
final class RecordOfferingTests: XCTestCase {
    private static let appRoot = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/RecordOfferingTests.swift
        .deletingLastPathComponent() // …/HexNFCAppTests
        .deletingLastPathComponent() // …/Tests
        .deletingLastPathComponent() // …/app

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// A screen with its comment lines dropped, so a guard never passes or
    /// fails on prose.
    private static func screen(_ name: String) throws -> String {
        try read("Sources/HexNFCApp/Screens/\(name)")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            .joined(separator: "\n")
    }

    private static func section(
        of text: String,
        from start: String,
        to end: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let after = try XCTUnwrap(
            text.components(separatedBy: start).dropFirst().first,
            "`\(start)` moved or was renamed, and this guard is now inert",
            file: file, line: line
        )
        return after.components(separatedBy: end)[0]
    }

    private static let withoutAForm: [AddRecordKind] = [.appLink, .bluetooth, .data, .shortcut, .raw]

    // MARK: - Add record

    func test_theAddSheetOffersTheThirteenKindsWithAForm() {
        XCTAssertEqual(
            AddRecordKind.offered,
            [.text, .uri, .social, .search, .file, .mail, .contact, .phone, .sms, .facetime, .map, .crypto, .wifi]
        )
    }

    func test_theFiveKindsWithoutAForm_areNotOffered() {
        for kind in Self.withoutAForm {
            XCTAssertFalse(AddRecordKind.offered.contains(kind), "\(kind) opens as JSON and is not offered for 1.0")
        }
    }

    /// The sheet draws its tiles from the list above and nothing else.
    func test_theAddSheetDrawsItsTilesFromTheOfferedList() throws {
        let text = try Self.screen("AddRecordSheet.swift")
        XCTAssertTrue(text.contains("ForEach(AddRecordKind.offered, id: \\.self)"))
        XCTAssertFalse(text.contains("static let options"), "a second list is how the two drift apart")
    }

    /// Hiding a tile is not dropping a type. All eighteen kinds still make a
    /// record of their own type, one each, so a record of a hidden type that
    /// arrives from a tag, a preset or a history row is still a first-class
    /// record.
    func test_everyKindStillMakesItsOwnRecordType() {
        let all: [AddRecordKind] = AddRecordKind.offered + Self.withoutAForm
        let types = all.map { $0.makeRecord().typeKey }
        XCTAssertEqual(Set(types).count, 18, "one record type per kind: \(types.sorted())")
    }

    /// Every offered kind opens in a form of its own, and the five hidden ones
    /// are exactly the ones that fall through to the JSON editor.
    ///
    /// If a form is written for one of the five, the second assertion fails on
    /// purpose: that type can be offered again, and `AddRecordKind.offered` is
    /// the place to do it.
    func test_everyOfferedKindOpensInAFormOfItsOwn() throws {
        let text = try Self.screen("RecordEditorSheet.swift")
        let router = try Self.section(of: text, from: "switch working {", to: "default:")
        for kind in AddRecordKind.offered {
            let type = kind.makeRecord().typeKey
            XCTAssertTrue(router.contains("case .\(type)(let r):"), "\(type) is offered, so it needs a form")
        }
        for kind in Self.withoutAForm {
            let type = kind.makeRecord().typeKey
            XCTAssertFalse(router.contains("case .\(type)(let r):"), "\(type) has a form now; offer it again?")
        }
    }

    /// The JSON editor's note describes what the editor does, not what the app
    /// has not got round to, and not how it is built.
    func test_theJSONEditorNote_isNeutral() throws {
        let text = try Self.screen("RecordEditorSheet.swift")
        let body = try Self.section(of: text, from: "private struct GenericJSONEditorBody", to: "TextEditor(")
        for phrase in ["not yet", "Codable", "round-trip", "Specialised"] {
            XCTAssertFalse(body.contains(phrase), "\"\(phrase)\" is back in the JSON editor's note")
        }
        XCTAssertTrue(
            body.contains(
                "\"This record type is edited as JSON. While the text is not a valid record, Save keeps the last valid version.\""
            )
        )
    }

    // MARK: - Location source

    func test_theSourcePickerDoesNotOfferCurrentLocation() {
        XCTAssertEqual(MapSourceChoice.allCases.map(\.source), [.coordinate, .appleMaps, .googleMaps])
        XCTAssertFalse(MapSourceChoice.allCases.map(\.source).contains(.currentLocation))
    }

    func test_theSourcePickerIsBuiltFromTheChoices() throws {
        let text = try Self.screen("RecordEditorSheet.swift")
        let map = try Self.section(of: text, from: "private struct MapEditorBody", to: "private struct FileEditorBody")
        XCTAssertTrue(map.contains("ForEach(MapSourceChoice.allCases, id: \\.self)"))
        XCTAssertFalse(text.contains("currentLocation"), "the editor names the withdrawn source nowhere")
        XCTAssertTrue(
            text.contains("_working = State(initialValue: MapSourceChoice.editable(initial))"),
            "a legacy record has to be moved onto an offered source before the picker sees it"
        )
    }

    /// The usual legacy record: "Current location" selected and nothing pasted.
    /// It opens under Coordinates with both fields empty, and the form's note
    /// asks for a location, because there is none to show.
    func test_aLegacyCurrentLocationRecord_opensUnderCoordinates() {
        let legacy = MapRecord(source: .currentLocation)
        guard case .map(let opened) = MapSourceChoice.editable(.map(legacy)) else {
            return XCTFail("still a map record")
        }
        XCTAssertEqual(opened.source, .coordinate)
        XCTAssertNil(opened.latitude)
        XCTAssertNil(opened.longitude)
        XCTAssertEqual(opened.id, legacy.id, "the same record, so Save replaces it in the list")
        XCTAssertFalse(opened.hasLocation)
    }

    /// The same source with a link pasted into it: the old form showed the Map
    /// URL field for it, so the link is what it holds, and it opens there.
    func test_aLegacyCurrentLocationRecordWithALink_opensUnderAMapURL() {
        let legacy = MapRecord(source: .currentLocation, rawURL: "https://maps.apple.com/?ll=1,2")
        guard case .map(let opened) = MapSourceChoice.editable(.map(legacy)) else {
            return XCTFail("still a map record")
        }
        XCTAssertEqual(opened.source, .appleMaps)
        XCTAssertEqual(opened.rawURL, "https://maps.apple.com/?ll=1,2")
        XCTAssertTrue(opened.hasLocation)
    }

    func test_everythingElse_opensAsItIs() {
        let records: [NDEFRecord] = [
            .map(MapRecord(source: .coordinate, latitude: 1, longitude: 2)),
            .map(MapRecord(source: .googleMaps, rawURL: "https://maps.google.com/?q=x")),
            .map(MapRecord()),
            .text(TextRecord(text: "hello")),
            .raw(RawNDEFRecord()),
        ]
        for record in records {
            XCTAssertEqual(MapSourceChoice.editable(record), record)
        }
    }

    // MARK: - Coordinates

    func test_aCoordinateWithADecimalPoint_reads() {
        XCTAssertEqual(CoordinateEntry.value(from: "-33.8688"), -33.8688)
        XCTAssertEqual(CoordinateEntry.value(from: " 151.2093 "), 151.2093)
        XCTAssertEqual(CoordinateEntry.value(from: "48"), 48)
    }

    /// The fields keep what was typed on screen, so a decimal comma read as
    /// nothing would sit visibly in the field under a note asking for a
    /// latitude, and Write would then say the coordinates were missing.
    func test_aCoordinateWithADecimalComma_readsTheSame() {
        XCTAssertEqual(CoordinateEntry.value(from: "48,8566"), 48.8566)
        XCTAssertEqual(CoordinateEntry.value(from: "-22,9068"), -22.9068)
        XCTAssertEqual(CoordinateEntry.value(from: " 2,3522 "), 2.3522)
    }

    func test_textThatIsNotOneNumber_readsAsNothing() {
        let notOneNumber = [
            "", " ", "-", ",", "1,234.5", "1.234,5", "1,2,3", "48.8566, 2.3522", "north", "nan", "inf", "-inf",
        ]
        for text in notOneNumber {
            XCTAssertNil(CoordinateEntry.value(from: text), "\"\(text)\"")
        }
    }

    func test_theLocationFormReadsItsFieldsThroughCoordinateEntry() throws {
        let text = try Self.screen("RecordEditorSheet.swift")
        let map = try Self.section(of: text, from: "private struct MapEditorBody", to: "private struct FileEditorBody")
        XCTAssertTrue(map.contains("record.latitude = CoordinateEntry.value(from: newValue)"))
        XCTAssertTrue(map.contains("record.longitude = CoordinateEntry.value(from: newValue)"))
        XCTAssertFalse(map.contains("Double("), "a second parser is how a comma stops reading again")
    }

    // MARK: - Presets

    /// A saved preset cannot be changed, so a preset holding a location the
    /// write flow refuses would be refused on every write, with nothing the
    /// user could do about it but rebuild it. Save as preset refuses it
    /// instead, by the write flow's own rule, and says why.
    func test_savingAPresetWithALocationThatPointsNowhere_isRefused() throws {
        let text = try Self.screen("SavePresetSheet.swift")
        let rule = try Self.section(
            of: text,
            from: "private var holdsLocationWithNowhereToPoint: Bool {",
            to: "}"
        )
        XCTAssertTrue(rule.contains("WriteFlowModel.locationsWithNowhereToPoint(in: .replace(records)) != nil"))

        let canSave = try Self.section(of: text, from: "private var canSave: Bool {", to: "private var")
        XCTAssertTrue(canSave.contains("guard !holdsLocationWithNowhereToPoint else { return false }"))

        let form = try Self.section(of: text, from: "Section(\"Records\") {", to: "if protection.passwordProtect {")
        XCTAssertTrue(form.contains("if holdsLocationWithNowhereToPoint {"), "the refusal says why")
    }

    /// The rule the sheet borrows, on the records a preset would hold.
    @MainActor
    func test_thePresetRule_matchesWhatTheWriteFlowRefuses() {
        let unplaced = NDEFRecord.map(MapRecord())
        let legacy = NDEFRecord.map(MapRecord(source: .currentLocation))
        let placed = NDEFRecord.map(MapRecord(source: .coordinate, latitude: 48.8566, longitude: 2.3522))
        let text = NDEFRecord.text(TextRecord(text: "hello"))
        XCTAssertNotNil(WriteFlowModel.locationsWithNowhereToPoint(in: .replace([text, unplaced])))
        XCTAssertNotNil(WriteFlowModel.locationsWithNowhereToPoint(in: .replace([legacy])))
        XCTAssertNil(WriteFlowModel.locationsWithNowhereToPoint(in: .replace([text, placed])))
        XCTAssertNil(WriteFlowModel.locationsWithNowhereToPoint(in: .replace([])), "a protection-only preset")
    }

    // MARK: - Strings

    func test_theWithdrawnStrings_areGoneFromTheCatalogue_andTheNewOnesAreIn() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("HexNFC/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = try Set(XCTUnwrap(root["strings"] as? [String: Any]).keys)

        for gone in [
            "Specialised editor not yet available for this record type. Edit the JSON directly. It round-trips through the Codable representation.",
            "Current location",
        ] {
            XCTAssertFalse(keys.contains(gone), "withdrawn and unused: \(gone)")
        }
        for new in [
            "This record type is edited as JSON. While the text is not a valid record, Save keeps the last valid version.",
            "Enter a latitude and a longitude, or a map URL. Until then, this record cannot be written to a tag.",
            "A location record is missing its coordinates or map URL. Nothing was written to the tag.",
            "No location",
            "A location record has no coordinates or map URL, so this preset could never be written to a tag. Fill it in or delete it on the Tag screen, then save.",
        ] {
            XCTAssertTrue(keys.contains(new), "missing from the catalogue: \(new)")
        }
    }

    // MARK: - Permissions

    /// A purpose string is a claim that the app asks for that access, and App
    /// Review reads it as one. These three had no code behind them: nothing in
    /// the app links CoreLocation, Contacts or CoreBluetooth. The pairing is the
    /// point. Whoever adds one of those frameworks back fails the first half
    /// and has to restore the matching key on purpose.
    func test_noPurposeStringForAPermissionTheAppNeverRequests() throws {
        let withdrawn = [
            "NSLocationWhenInUseUsageDescription",
            "NSContactsUsageDescription",
            "NSBluetoothAlwaysUsageDescription",
        ]
        let kept = ["NSCameraUsageDescription", "NFCReaderUsageDescription"]

        let project = try Self.read("HexNFC.xcodeproj/project.pbxproj")
        let plist = try Self.read("HexNFC/Info.plist")
        let strings = try Self.read("HexNFC/InfoPlist.xcstrings")
        for key in withdrawn {
            XCTAssertFalse(project.contains(key), "\(key) is back in the build settings")
            XCTAssertFalse(plist.contains(key), "\(key) is back in Info.plist")
            XCTAssertFalse(strings.contains(key), "\(key) is back in InfoPlist.xcstrings")
        }
        for key in kept {
            XCTAssertEqual(
                project.components(separatedBy: "INFOPLIST_KEY_\(key) =").count - 1, 2,
                "\(key) is still asked for, in both Debug and Release"
            )
            XCTAssertTrue(strings.contains("\"\(key)\""), "\(key) keeps its translations")
        }

        var scanned = 0
        for folder in ["Sources", "HexNFC"] {
            let root = Self.appRoot.appendingPathComponent(folder)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let code = try Self.codeLines(of: String(contentsOf: url, encoding: .utf8))
                scanned += 1
                if let found = Self.permissionFramework(importedBy: code) {
                    XCTFail("\(folder): \(url.lastPathComponent) imports \(found); restore its purpose string")
                }
                // MapKit re-exports CoreLocation, and SwiftUI's map views can
                // ask for the user's position without importing it at all.
                for symbol in Self.permissionSymbols where code.contains(symbol) {
                    XCTFail("\(folder): \(url.lastPathComponent) uses \(symbol); restore its purpose string")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found the sources, so a clean result means something")
    }

    /// The framework `code` imports that needs a withdrawn purpose string, in
    /// any spelling of the import: plain, with attributes such as
    /// `@preconcurrency`, or of a single declaration (`import struct
    /// CoreLocation.CLLocationCoordinate2D`).
    static func permissionFramework(importedBy code: String) -> String? {
        let pattern = #"(?m)^\s*(?:@\w+\s+)*import\s+(?:\w+\s+)?(CoreLocation|CoreLocationUI|Contacts|ContactsUI|CoreBluetooth)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let name = Range(match.range(at: 1), in: code)
        else { return nil }
        return String(code[name])
    }

    /// APIs that reach location, contacts or Bluetooth without an import of
    /// their own framework in the same file.
    static let permissionSymbols = [
        "CLLocationManager", "CNContactStore", "CNContactPicker", "ContactAccessButton",
        "CBCentralManager", "CBPeripheralManager",
        "showsUserLocation", "UserAnnotation(", "MapUserLocationButton", "userTrackingMode",
    ]

    /// `text` with its comment lines dropped and its line endings made plain,
    /// so a guard never trips on prose or misses a file saved with CRLF.
    private static func codeLines(of text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The guard above has to catch every spelling it claims to, or a clean
    /// scan proves nothing.
    func test_thePermissionGuard_catchesEveryImportSpelling() {
        let caught = [
            "import CoreLocation\n",
            "import CoreLocation",
            "import CoreLocation\r\n",
            "  import Contacts\n",
            "@preconcurrency import CoreBluetooth\n",
            "@_exported @preconcurrency import ContactsUI\n",
            "import struct CoreLocation.CLLocationCoordinate2D\n",
            "import class Contacts.CNContactStore\n",
            "import CoreLocationUI\n",
            "import Foundation\nimport CoreLocation\n",
        ]
        for code in caught {
            XCTAssertNotNil(Self.permissionFramework(importedBy: code), code.debugDescription)
        }
        let missed = [
            "import Foundation\n",
            "import ContactsKit\n",
            "import CoreLocationish\n",
            "let x = 1 // import CoreLocation\n",
            "let text = \"import CoreLocation\"\n",
        ]
        for code in missed {
            XCTAssertNil(Self.permissionFramework(importedBy: code), code.debugDescription)
        }
    }
}
