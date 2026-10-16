import Foundation
import HexNFCRecords

/// User-facing presentation for a record case — a title, a representative
/// SF Symbol, and a one-line truncated subtitle. Keeps the formatting
/// concerns out of `RecordRow` and `RecordEditor`.
enum RecordLocalization {
    static func title(for record: NDEFRecord) -> String {
        switch record {
        case .text: String(localized: "Text")
        case .uri: String(localized: "URL")
        case .appLink: String(localized: "App link")
        case .social: String(localized: "Social")
        case .search: String(localized: "Search")
        case .file: String(localized: "File")
        case .mail: String(localized: "Email")
        case .contact: String(localized: "Contact")
        case .phone: String(localized: "Phone")
        case .sms: String(localized: "Text message")
        case .facetime: String(localized: "FaceTime")
        case .map: String(localized: "Location")
        case .crypto: String(localized: "Crypto")
        case .bluetoothHandover: String(localized: "Bluetooth")
        case .wifiWPS: String(localized: "Wi-Fi")
        case .data: String(localized: "Data")
        case .shortcut: String(localized: "Shortcut")
        case .raw: String(localized: "Raw")
        }
    }

    static func subtitle(for record: NDEFRecord) -> String {
        switch record {
        case .text(let r): r.text
        case .uri(let r): r.uri
        case .appLink(let r): r.appStoreURL
        case .social(let r): r.handle
        case .search(let r): r.query
        case .file(let r): r.path
        case .mail(let r): r.to.joined(separator: ", ")
        case .contact(let r): r.formattedName
        case .phone(let r): r.number
        case .sms(let r): r.number
        case .facetime(let r): r.target
        case .map(let r): mapSubtitle(r)
        case .crypto(let r): r.address
        case .bluetoothHandover(let r): r.deviceName ?? r.deviceMAC
        case .wifiWPS(let r): r.ssid
        case .data(let r): r.mimeType
        case .shortcut(let r): r.shortcutName
        case .raw(let r): r.payload.map { String(format: "%02X", $0) }.prefix(16).joined()
        }
    }

    /// A location with nowhere to point says so, rather than showing the
    /// "0.0, 0.0" its missing coordinates used to read as. It is the row the
    /// write refusal is about, and this is how the user finds it in the list.
    private static func mapSubtitle(_ record: MapRecord) -> String {
        guard record.hasLocation else { return String(localized: "No location") }
        if let label = record.label, !label.isEmpty {
            return label
        }
        if let raw = record.rawURL, !raw.isEmpty {
            return raw
        }
        return "\(record.latitude ?? 0), \(record.longitude ?? 0)"
    }

    static func icon(for record: NDEFRecord) -> String {
        switch record {
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
        case .bluetoothHandover: "antenna.radiowaves.left.and.right"
        case .wifiWPS: "wifi"
        case .data: "doc.zipper"
        case .shortcut: "bolt.fill"
        case .raw: "chevron.left.slash.chevron.right"
        }
    }
}
