import Foundation

// MARK: - NDEFRecord

/// Polymorphic record model. Every case carries a payload-bearing struct
/// rather than loose associated values — keeps editors easy to write and
/// the JSON encoding stable for `.hexnfc` exports.
///
/// Codable uses a flat `type` discriminator at the JSON top level:
///
///     { "type": "text", "text": "Hello", "languageCode": "en" }
///
/// This is deliberate: human-readable, hand-editable, forward-compatible.
/// Adding a case never reshuffles existing keys.
public enum NDEFRecord: Hashable, Identifiable, Sendable {
    case text(TextRecord)
    case uri(URIRecord)
    case appLink(AppLinkRecord)
    case social(SocialRecord)
    case search(SearchRecord)
    case file(FileRecord)
    case mail(MailRecord)
    case contact(VCardRecord)
    case phone(PhoneRecord)
    case sms(SMSRecord)
    case facetime(FaceTimeRecord)
    case map(MapRecord)
    case crypto(CryptoURIRecord)
    case bluetoothHandover(BTHandoverRecord)
    case wifiWPS(WiFiWPSRecord)
    case data(DataRecord)
    case shortcut(ShortcutRecord)
    case raw(RawNDEFRecord)

    public var id: UUID {
        switch self {
        case .text(let r): r.id
        case .uri(let r): r.id
        case .appLink(let r): r.id
        case .social(let r): r.id
        case .search(let r): r.id
        case .file(let r): r.id
        case .mail(let r): r.id
        case .contact(let r): r.id
        case .phone(let r): r.id
        case .sms(let r): r.id
        case .facetime(let r): r.id
        case .map(let r): r.id
        case .crypto(let r): r.id
        case .bluetoothHandover(let r): r.id
        case .wifiWPS(let r): r.id
        case .data(let r): r.id
        case .shortcut(let r): r.id
        case .raw(let r): r.id
        }
    }

    /// Stable string used in the JSON discriminator and in localized
    /// editor titles. Never localize this — it's a wire identifier.
    public var typeKey: String {
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
        case .bluetoothHandover: "bluetoothHandover"
        case .wifiWPS: "wifiWPS"
        case .data: "data"
        case .shortcut: "shortcut"
        case .raw: "raw"
        }
    }
}

// MARK: - Record payload structs

public struct TextRecord: Hashable, Identifiable, Codable, Sendable {
    public enum Encoding: String, Codable, Hashable, Sendable { case utf8, utf16 }
    public var id: UUID
    public var text: String
    public var languageCode: String
    public var encoding: Encoding

    public init(
        id: UUID = UUID(),
        text: String = "",
        languageCode: String = "en",
        encoding: Encoding = .utf8
    ) {
        self.id = id
        self.text = text
        self.languageCode = languageCode
        self.encoding = encoding
    }
}

public struct URIRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var uri: String
    public init(id: UUID = UUID(), uri: String = "") {
        self.id = id
        self.uri = uri
    }
}

public struct AppLinkRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var appStoreURL: String
    public var universalLink: String?
    public var displayName: String?
    public init(
        id: UUID = UUID(),
        appStoreURL: String = "",
        universalLink: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.appStoreURL = appStoreURL
        self.universalLink = universalLink
        self.displayName = displayName
    }
}

public enum SocialPlatform: String, Hashable, Codable, Sendable, CaseIterable {
    case facebook
    case bluesky
    case x
    case github
    case instagram
    case line
    case linkedin
    case medium
    case pinterest
    case skype
    case slack
    case snapchat
    case soundcloud
    case steam
    case telegram
    case threads
    case tiktok
    case twitch
    case vk
    case wechat
    case whatsapp
    case youtube
}

public struct SocialRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var platform: SocialPlatform
    public var handle: String
    public init(id: UUID = UUID(), platform: SocialPlatform = .x, handle: String = "") {
        self.id = id
        self.platform = platform
        self.handle = handle
    }
}

public enum SearchEngine: String, Hashable, Codable, Sendable, CaseIterable {
    case google
    case googleImages
    case bing
    case yandex
    case duckduckgo
    case youtube
    case wikipedia
}

public struct SearchRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var engine: SearchEngine
    public var query: String
    public init(id: UUID = UUID(), engine: SearchEngine = .google, query: String = "") {
        self.id = id
        self.engine = engine
        self.query = query
    }
}

public struct FileRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var path: String
    public init(id: UUID = UUID(), path: String = "") {
        self.id = id
        self.path = path
    }
}

public struct MailRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public init(
        id: UUID = UUID(),
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = ""
    ) {
        self.id = id
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }
}

public struct VCardRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var formattedName: String
    public var organization: String?
    public var phones: [String]
    public var emails: [String]
    public var addresses: [String]
    public var websites: [String]
    public var photoURL: String?
    public init(
        id: UUID = UUID(),
        formattedName: String = "",
        organization: String? = nil,
        phones: [String] = [],
        emails: [String] = [],
        addresses: [String] = [],
        websites: [String] = [],
        photoURL: String? = nil
    ) {
        self.id = id
        self.formattedName = formattedName
        self.organization = organization
        self.phones = phones
        self.emails = emails
        self.addresses = addresses
        self.websites = websites
        self.photoURL = photoURL
    }
}

public struct PhoneRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var number: String
    public init(id: UUID = UUID(), number: String = "") {
        self.id = id
        self.number = number
    }
}

public struct SMSRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var number: String
    public var body: String
    public init(id: UUID = UUID(), number: String = "", body: String = "") {
        self.id = id
        self.number = number
        self.body = body
    }
}

public struct FaceTimeRecord: Hashable, Identifiable, Codable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable { case video, audio }
    public var id: UUID
    public var target: String
    public var mode: Mode
    public init(id: UUID = UUID(), target: String = "", mode: Mode = .video) {
        self.id = id
        self.target = target
        self.mode = mode
    }
}

public struct MapRecord: Hashable, Identifiable, Codable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case coordinate
        case appleMaps
        case googleMaps
        case currentLocation
    }

    public var id: UUID
    public var source: Source
    public var latitude: Double?
    public var longitude: Double?
    public var rawURL: String?
    public var label: String?
    public init(
        id: UUID = UUID(),
        source: Source = .coordinate,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rawURL: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.source = source
        self.latitude = latitude
        self.longitude = longitude
        self.rawURL = rawURL
        self.label = label
    }
}

public enum CryptoNetwork: String, Hashable, Codable, Sendable, CaseIterable {
    case bitcoin
    case ethereum
    case monero
    case litecoin
    case dogecoin
    case solana
}

public struct CryptoURIRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var network: CryptoNetwork
    public var address: String
    public var amount: String?
    public var message: String?
    public init(
        id: UUID = UUID(),
        network: CryptoNetwork = .bitcoin,
        address: String = "",
        amount: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.network = network
        self.address = address
        self.amount = amount
        self.message = message
    }
}

public struct BTHandoverRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var deviceMAC: String
    public var deviceName: String?
    public init(id: UUID = UUID(), deviceMAC: String = "", deviceName: String? = nil) {
        self.id = id
        self.deviceMAC = deviceMAC
        self.deviceName = deviceName
    }
}

public struct WiFiWPSRecord: Hashable, Identifiable, Codable, Sendable {
    public enum Authentication: String, Codable, Hashable, Sendable {
        case open
        case wpaPersonal
        case wpa2Personal
        case wpa3Personal
        case wep
    }

    public enum Encryption: String, Codable, Hashable, Sendable {
        case none
        case wep
        case tkip
        case aes
        case tkipAes
    }

    public var id: UUID
    public var ssid: String
    public var authentication: Authentication
    public var encryption: Encryption
    public var password: String
    public var isHidden: Bool
    public init(
        id: UUID = UUID(),
        ssid: String = "",
        authentication: Authentication = .wpa2Personal,
        encryption: Encryption = .aes,
        password: String = "",
        isHidden: Bool = false
    ) {
        self.id = id
        self.ssid = ssid
        self.authentication = authentication
        self.encryption = encryption
        self.password = password
        self.isHidden = isHidden
    }
}

public struct DataRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var mimeType: String
    public var payload: Data
    public init(id: UUID = UUID(), mimeType: String = "application/octet-stream", payload: Data = Data()) {
        self.id = id
        self.mimeType = mimeType
        self.payload = payload
    }
}

public struct ShortcutRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var shortcutName: String
    public var input: String?
    public init(id: UUID = UUID(), shortcutName: String = "", input: String? = nil) {
        self.id = id
        self.shortcutName = shortcutName
        self.input = input
    }
}

/// Escape hatch — when none of the categorized cases fit. Round-trips raw
/// TNF/type/id/payload bytes verbatim.
public struct RawNDEFRecord: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var tnf: UInt8
    public var typeBytes: Data
    public var idBytes: Data
    public var payload: Data
    public init(
        id: UUID = UUID(),
        tnf: UInt8 = 0,
        typeBytes: Data = Data(),
        idBytes: Data = Data(),
        payload: Data = Data()
    ) {
        self.id = id
        self.tnf = tnf
        self.typeBytes = typeBytes
        self.idBytes = idBytes
        self.payload = payload
    }
}

// MARK: - Codable with discriminator

extension NDEFRecord: Codable {
    private enum Discriminator: CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Discriminator.self)
        let type = try container.decode(String.self, forKey: .type)
        let payloadDecoder = try decoder.singleValueContainer()

        switch type {
        case "text": self = try .text(payloadDecoder.decode(TextRecord.self))
        case "uri": self = try .uri(payloadDecoder.decode(URIRecord.self))
        case "appLink": self = try .appLink(payloadDecoder.decode(AppLinkRecord.self))
        case "social": self = try .social(payloadDecoder.decode(SocialRecord.self))
        case "search": self = try .search(payloadDecoder.decode(SearchRecord.self))
        case "file": self = try .file(payloadDecoder.decode(FileRecord.self))
        case "mail": self = try .mail(payloadDecoder.decode(MailRecord.self))
        case "contact": self = try .contact(payloadDecoder.decode(VCardRecord.self))
        case "phone": self = try .phone(payloadDecoder.decode(PhoneRecord.self))
        case "sms": self = try .sms(payloadDecoder.decode(SMSRecord.self))
        case "facetime": self = try .facetime(payloadDecoder.decode(FaceTimeRecord.self))
        case "map": self = try .map(payloadDecoder.decode(MapRecord.self))
        case "crypto": self = try .crypto(payloadDecoder.decode(CryptoURIRecord.self))
        case "bluetoothHandover": self = try .bluetoothHandover(payloadDecoder.decode(BTHandoverRecord.self))
        case "wifiWPS": self = try .wifiWPS(payloadDecoder.decode(WiFiWPSRecord.self))
        case "data": self = try .data(payloadDecoder.decode(DataRecord.self))
        case "shortcut": self = try .shortcut(payloadDecoder.decode(ShortcutRecord.self))
        case "raw": self = try .raw(payloadDecoder.decode(RawNDEFRecord.self))

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown NDEFRecord type '\(type)'"
            )
        }
    }

    /// Encoding uses a two-pass strategy: encode the payload struct directly
    /// (flat keys), then add the discriminator. JSONEncoder preserves order
    /// because the second encoder writes into the same container.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let r): try encodeBody(r, type: "text", to: encoder)
        case .uri(let r): try encodeBody(r, type: "uri", to: encoder)
        case .appLink(let r): try encodeBody(r, type: "appLink", to: encoder)
        case .social(let r): try encodeBody(r, type: "social", to: encoder)
        case .search(let r): try encodeBody(r, type: "search", to: encoder)
        case .file(let r): try encodeBody(r, type: "file", to: encoder)
        case .mail(let r): try encodeBody(r, type: "mail", to: encoder)
        case .contact(let r): try encodeBody(r, type: "contact", to: encoder)
        case .phone(let r): try encodeBody(r, type: "phone", to: encoder)
        case .sms(let r): try encodeBody(r, type: "sms", to: encoder)
        case .facetime(let r): try encodeBody(r, type: "facetime", to: encoder)
        case .map(let r): try encodeBody(r, type: "map", to: encoder)
        case .crypto(let r): try encodeBody(r, type: "crypto", to: encoder)
        case .bluetoothHandover(let r): try encodeBody(r, type: "bluetoothHandover", to: encoder)
        case .wifiWPS(let r): try encodeBody(r, type: "wifiWPS", to: encoder)
        case .data(let r): try encodeBody(r, type: "data", to: encoder)
        case .shortcut(let r): try encodeBody(r, type: "shortcut", to: encoder)
        case .raw(let r): try encodeBody(r, type: "raw", to: encoder)
        }
    }

    private func encodeBody(_ body: some Encodable, type: String, to encoder: Encoder) throws {
        try body.encode(to: encoder)
        var container = encoder.container(keyedBy: Discriminator.self)
        try container.encode(type, forKey: .type)
    }
}
