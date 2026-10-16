import Foundation

/// Map a string detected by `AVCaptureMetadataOutput` into a candidate
/// `NDEFRecord`. The dispatch table is intentionally narrow — recognise
/// the shapes QR codes commonly carry, fall back to a plain URI / Text
/// for everything else. The user always sees the result in the editor
/// before it lands on a tag.
public enum QRPayloadParser {
    public static func parse(_ raw: String) -> NDEFRecord {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .text(TextRecord(text: ""))
        }
        if let wifi = parseWiFi(trimmed) {
            return .wifiWPS(wifi)
        }
        if trimmed.uppercased().hasPrefix("BEGIN:VCARD") {
            return .contact(parseVCard(trimmed))
        }
        if let mailto = parseMailto(trimmed) {
            return .mail(mailto)
        }
        if let sms = parseSMS(trimmed) {
            return .sms(sms)
        }
        if let tel = parseTel(trimmed) {
            return .phone(tel)
        }
        if let geo = parseGeo(trimmed) {
            return .map(geo)
        }
        if isURL(trimmed) {
            return .uri(URIRecord(uri: trimmed))
        }
        return .text(TextRecord(text: trimmed))
    }

    // MARK: - Wi-Fi (`WIFI:T:WPA;S:Network;P:password;H:true;;`)

    /// Parse the Zxing/Android-style `WIFI:` payload. We don't try to be
    /// clever about partial parses — if any required component is missing
    /// we return nil so the caller falls through to a URI/Text branch.
    public static func parseWiFi(_ raw: String) -> WiFiWPSRecord? {
        guard raw.uppercased().hasPrefix("WIFI:") else { return nil }
        let body = String(raw.dropFirst("WIFI:".count))
        var fields: [Character: String] = [:]
        var key: Character?
        var value = ""
        var escaped = false
        for c in body {
            if escaped {
                value.append(c)
                escaped = false
                continue
            }
            if c == "\\" {
                escaped = true
                continue
            }
            if c == ":", key == nil, !value.isEmpty {
                key = value.first
                value = ""
                continue
            }
            if c == ";" {
                if let k = key {
                    fields[k] = value
                }
                key = nil
                value = ""
                continue
            }
            value.append(c)
        }
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        let authRaw = fields["T"]?.uppercased() ?? ""
        let auth: WiFiWPSRecord.Authentication
        let encryption: WiFiWPSRecord.Encryption
        switch authRaw {
        case "WPA", "WPA2", "WPA/WPA2":
            auth = .wpa2Personal
            encryption = .aes

        case "WPA3":
            auth = .wpa3Personal
            encryption = .aes

        case "WEP":
            auth = .wep
            encryption = .wep

        case "NOPASS", "":
            auth = .open
            encryption = .none

        default:
            auth = .wpa2Personal
            encryption = .aes
        }
        let password = fields["P"] ?? ""
        let hidden = (fields["H"]?.lowercased() == "true")
        return WiFiWPSRecord(
            ssid: ssid,
            authentication: auth,
            encryption: encryption,
            password: password,
            isHidden: hidden
        )
    }

    // MARK: - vCard

    public static func parseVCard(_ raw: String) -> VCardRecord {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var name = ""
        var org: String?
        var phones: [String] = []
        var emails: [String] = []
        var websites: [String] = []
        var addresses: [String] = []
        for line in lines {
            let upper = line.uppercased()
            let colon = line.firstIndex(of: ":") ?? line.endIndex
            guard colon != line.endIndex else { continue }
            let value = String(line[line.index(after: colon)...])
            if upper.hasPrefix("FN:") {
                name = value
            } else if upper.hasPrefix("ORG:") {
                org = value.isEmpty ? nil : value
            } else if upper.hasPrefix("TEL") {
                phones.append(value)
            } else if upper.hasPrefix("EMAIL") {
                emails.append(value)
            } else if upper.hasPrefix("URL") {
                websites.append(value)
            } else if upper.hasPrefix("ADR") {
                addresses.append(value)
            }
        }
        return VCardRecord(
            formattedName: name,
            organization: org,
            phones: phones,
            emails: emails,
            addresses: addresses,
            websites: websites
        )
    }

    // MARK: - mailto:

    public static func parseMailto(_ raw: String) -> MailRecord? {
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        let body = String(raw.dropFirst("mailto:".count))
        let (path, query) = splitQuery(body)
        let to: [String] = path.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var msg = ""
        for (k, v) in query {
            switch k.lowercased() {
            case "cc": cc = v.split(separator: ",").map { String($0) }
            case "bcc": bcc = v.split(separator: ",").map { String($0) }
            case "subject": subject = v
            case "body": msg = v
            default: break
            }
        }
        return MailRecord(to: to, cc: cc, bcc: bcc, subject: subject, body: msg)
    }

    // MARK: - sms: / smsto:

    public static func parseSMS(_ raw: String) -> SMSRecord? {
        let lower = raw.lowercased()
        let prefix: String
        if lower.hasPrefix("smsto:") {
            prefix = "smsto:"
        } else if lower.hasPrefix("sms:") {
            prefix = "sms:"
        } else {
            return nil
        }
        let body = String(raw.dropFirst(prefix.count))
        // `SMSTO:number:body` *and* `sms:number?body=...` both seen in the wild.
        if prefix == "smsto:", let colonIndex = body.firstIndex(of: ":") {
            let number = String(body[..<colonIndex])
            let message = String(body[body.index(after: colonIndex)...])
            return SMSRecord(number: number, body: message)
        }
        let (numberRaw, query) = splitQuery(body)
        let number = numberRaw
        var message = ""
        for (k, v) in query where k.lowercased() == "body" {
            message = v
        }
        return SMSRecord(number: number, body: message)
    }

    // MARK: - tel:

    public static func parseTel(_ raw: String) -> PhoneRecord? {
        guard raw.lowercased().hasPrefix("tel:") else { return nil }
        let number = String(raw.dropFirst("tel:".count))
        return PhoneRecord(number: number)
    }

    // MARK: - geo:

    public static func parseGeo(_ raw: String) -> MapRecord? {
        guard raw.lowercased().hasPrefix("geo:") else { return nil }
        let body = String(raw.dropFirst("geo:".count))
        let (coords, _) = splitQuery(body)
        let parts = coords.split(separator: ",")
        guard parts.count >= 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]) else { return nil }
        return MapRecord(source: .coordinate, latitude: lat, longitude: lon, rawURL: raw)
    }

    // MARK: - Helpers

    private static func isURL(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme else { return false }
        // Demand a scheme that's actually plausible. The NSURL parser accepts
        // bare strings as "URLs" with no scheme — we don't want plain text
        // misclassified.
        return ["http", "https", "ftp", "ftps", "tel", "mailto"].contains(scheme.lowercased())
    }

    /// Split `path?key=value&k2=v2` into `(path, [(k,v)])`.
    private static func splitQuery(_ s: String) -> (String, [(String, String)]) {
        guard let q = s.firstIndex(of: "?") else { return (s, []) }
        let path = String(s[..<q])
        let queryString = String(s[s.index(after: q)...])
        var pairs: [(String, String)] = []
        for component in queryString.split(separator: "&") {
            let parts = component.split(separator: "=", maxSplits: 1)
            let key = String(parts.first ?? "").removingPercentEncoding ?? String(parts.first ?? "")
            let value = if parts.count == 2 {
                String(parts[1]).removingPercentEncoding ?? String(parts[1])
            } else {
                ""
            }
            pairs.append((key, value))
        }
        return (path, pairs)
    }
}
