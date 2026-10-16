import HexNFCRecords
import SwiftUI

// What the record screens offer the user to create, and how they read what
// is typed, kept apart from the screens themselves. `AddRecordSheet` and
// `RecordEditorSheet` both open with `#if os(iOS)`, so `swift test` on macOS
// compiles neither; the lists and rules live here so the tests can pin them.

/// A tile on the Add record sheet: a kind of record the user can start from
/// empty. There is one case per `NDEFRecord` case, and each makes an empty
/// record of that type.
enum AddRecordKind: Hashable {
    case text
    case uri
    case appLink
    case social
    case search
    case file
    case mail
    case contact
    case phone
    case sms
    case facetime
    case map
    case crypto
    case bluetooth
    case wifi
    case data
    case shortcut
    case raw

    /// The tiles the Add record sheet shows, in order.
    ///
    /// Thirteen of the eighteen, each with a form of its own in
    /// `RecordEditorSheet`. App link, Bluetooth, Data, Shortcut and Raw are not
    /// offered: they have no form, and the JSON editor they would open is not
    /// something to build a record in from scratch. Their cases, record types
    /// and codecs all stay, because a record of any of them still arrives from
    /// a scanned tag, a saved preset or a history row, and has to open, edit
    /// and write back like any other.
    static let offered: [AddRecordKind] = [
        .text, .uri, .social, .search, .file,
        .mail, .contact, .phone, .sms, .facetime, .map,
        .crypto, .wifi,
    ]

    var title: LocalizedStringKey {
        switch self {
        case .text: "Text"
        case .uri: "URL"
        case .appLink: "App link"
        case .social: "Social"
        case .search: "Search"
        case .file: "File"
        case .mail: "Email"
        case .contact: "Contact"
        case .phone: "Phone"
        case .sms: "Text message"
        case .facetime: "FaceTime"
        case .map: "Location"
        case .crypto: "Crypto"
        case .bluetooth: "Bluetooth"
        case .wifi: "Wi-Fi"
        case .data: "Data"
        case .shortcut: "Shortcut"
        case .raw: "Raw"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .uri: "link"
        case .appLink: "app.badge"
        case .social: "person.circle"
        case .search: "magnifyingglass"
        case .file: "doc"
        case .mail: "envelope"
        case .contact: "person.crop.rectangle"
        case .phone: "phone"
        case .sms: "message"
        case .facetime: "video"
        case .map: "map"
        case .crypto: "bitcoinsign.circle"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .wifi: "wifi"
        case .data: "doc.zipper"
        case .shortcut: "bolt.fill"
        case .raw: "chevron.left.slash.chevron.right"
        }
    }

    var identifier: String {
        switch self {
        case .text: "text"
        case .uri: "uri"
        case .appLink: "appLink"
        case .social: "social"
        case .search: "search"
        case .file: "file"
        case .mail: "mail"
        case .contact: "contact"
        case .phone: "phone"
        case .sms: "sms"
        case .facetime: "facetime"
        case .map: "map"
        case .crypto: "crypto"
        case .bluetooth: "bluetooth"
        case .wifi: "wifi"
        case .data: "data"
        case .shortcut: "shortcut"
        case .raw: "raw"
        }
    }

    func makeRecord() -> NDEFRecord {
        switch self {
        case .text: .text(TextRecord())
        case .uri: .uri(URIRecord())
        case .appLink: .appLink(AppLinkRecord())
        case .social: .social(SocialRecord())
        case .search: .search(SearchRecord())
        case .file: .file(FileRecord())
        case .mail: .mail(MailRecord())
        case .contact: .contact(VCardRecord())
        case .phone: .phone(PhoneRecord())
        case .sms: .sms(SMSRecord())
        case .facetime: .facetime(FaceTimeRecord())
        case .map: .map(MapRecord())
        case .crypto: .crypto(CryptoURIRecord())
        case .bluetooth: .bluetoothHandover(BTHandoverRecord())
        case .wifi: .wifiWPS(WiFiWPSRecord())
        case .data: .data(DataRecord())
        case .shortcut: .shortcut(ShortcutRecord())
        case .raw: .raw(RawNDEFRecord())
        }
    }
}

/// An entry in the Location form's Source picker.
///
/// `MapRecord.Source` has a fourth case, `.currentLocation`, which is no longer
/// offered. It never found anything: the app has no location access, so the
/// option only relabelled the Map URL field, and a record saved with it and
/// nothing pasted went onto the tag as `geo:0,0`. The case stays in the record
/// model so presets and history saved with it still decode; this type has no
/// entry for it, so the picker cannot offer it.
enum MapSourceChoice: CaseIterable, Hashable {
    case coordinates
    case appleMapsURL
    case googleMapsURL

    var source: MapRecord.Source {
        switch self {
        case .coordinates: .coordinate
        case .appleMapsURL: .appleMaps
        case .googleMapsURL: .googleMaps
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .coordinates: "Coordinates"
        case .appleMapsURL: "Apple Maps URL"
        case .googleMapsURL: "Google Maps URL"
        }
    }

    /// `record` as the record editor opens it.
    ///
    /// A location saved with `.currentLocation` would otherwise open with a
    /// picker selection that has no row. It opens under the choice that shows
    /// what it holds instead: a pasted link under Apple Maps URL, which is also
    /// where the codec files a map link it reads off a tag, and anything else
    /// under Coordinates, where the fields show whatever is there. For the usual
    /// legacy record that is nothing, so the form's note asks for a location.
    /// Nothing changes unless the user saves.
    static func editable(_ record: NDEFRecord) -> NDEFRecord {
        guard case .map(var map) = record, map.source == .currentLocation else { return record }
        map.source = map.rawURL?.isEmpty == false ? .appleMaps : .coordinate
        return .map(map)
    }
}

/// How the Location form reads a typed latitude or longitude.
enum CoordinateEntry {
    /// The number `text` spells, or `nil` when it spells none.
    ///
    /// A lone comma is read as the decimal mark, so "48,8566" is 48.8566.
    /// French, Spanish and Brazilian Portuguese write decimals that way, and
    /// the field keeps showing what was typed, so a comma read as nothing
    /// would leave a visible "48,8566" under a note asking for a latitude.
    /// Text with a point and a comma, or with two commas, is not one number
    /// and stays unread. Infinity and NaN parse as `Double` but are not
    /// places, so they are refused too.
    static func value(from text: String) -> Double? {
        var number = text.trimmingCharacters(in: .whitespaces)
        if !number.contains("."), number.components(separatedBy: ",").count == 2 {
            number = number.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(number), value.isFinite else { return nil }
        return value
    }
}
