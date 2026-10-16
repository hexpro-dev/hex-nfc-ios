import Foundation
import Security

/// Substitutes `{name}` and `{name:format}` placeholders at write time.
///
/// Templates round-trip through Codable un-rendered — the editor keeps
/// `"Tag {uid}"` in storage and only resolves to bytes when the record is
/// written to a specific chip. That preserves variables across edits.
///
/// Supported placeholders:
///   - `{uid}`         — hex, no separators (e.g. `04A1B2C30406`)
///   - `{tagId}`       — alias of `{uid}`
///   - `{uid:colon}`   — hex with colon separators (e.g. `04:A1:B2:...`)
///   - `{counter}`     — zero-padded 6-digit decimal
///   - `{year}` / `{month}` / `{day}` — current calendar fields, ISO format
///   - `{iso8601}`     — current date in ISO 8601
///   - `{random}`      — 4 hex chars of secure random
public struct TemplateContext: Sendable {
    public let uid: Data
    public let counter: Int
    public let now: Date
    public let randomBytes: @Sendable (Int) -> Data

    public init(
        uid: Data,
        counter: Int = 0,
        now: Date = Date(),
        randomBytes: @escaping @Sendable (Int) -> Data = TemplateContext.defaultRandomBytes
    ) {
        self.uid = uid
        self.counter = counter
        self.now = now
        self.randomBytes = randomBytes
    }

    public static let defaultRandomBytes: @Sendable (Int) -> Data = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        // `baseAddress` is nil for an empty buffer, so the force unwrap this
        // replaces crashed on `randomBytes(0)`. Nothing asks for zero bytes
        // today, but a template placeholder taking a length is one edit away
        // from doing so.
        _ = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecSuccess }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return Data(bytes)
    }
}

public enum TemplateEngine {
    public enum RenderError: Error, Hashable, Sendable {
        case unknownPlaceholder(String)
    }

    /// Renders `{...}` placeholders in `template` against `context`.
    /// Unknown placeholders throw rather than being silently dropped — the
    /// editor surfaces this as a "no resolver for {foo}" warning at validation.
    public static func render(_ template: String, context: TemplateContext) throws -> String {
        // Single regex pass: `{name}` or `{name:format}`. Both name and format
        // are simple identifiers; we don't allow nested braces.
        let pattern = #"\{([A-Za-z][A-Za-z0-9]*)(?::([A-Za-z0-9]+))?\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(template.startIndex..., in: template)
        var result = ""
        var cursor = template.startIndex

        for match in regex.matches(in: template, range: range) {
            guard let matchRange = Range(match.range, in: template),
                  let nameRange = Range(match.range(at: 1), in: template) else { continue }
            let formatRange = match.range(at: 2)
            let format: String? = formatRange.location == NSNotFound
                ? nil
                : Range(formatRange, in: template).map { String(template[$0]) }

            result.append(contentsOf: template[cursor ..< matchRange.lowerBound])
            let name = String(template[nameRange])
            try result.append(resolve(name: name, format: format, context: context))
            cursor = matchRange.upperBound
        }
        result.append(contentsOf: template[cursor...])
        return result
    }

    private static func resolve(name: String, format: String?, context: TemplateContext) throws -> String {
        switch name {
        case "uid", "tagId":
            return formattedUID(context.uid, format: format)

        case "counter":
            return String(format: "%06d", context.counter)

        case "year":
            return calendarComponent(.year, from: context.now, width: 4)

        case "month":
            return calendarComponent(.month, from: context.now, width: 2)

        case "day":
            return calendarComponent(.day, from: context.now, width: 2)

        case "iso8601":
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: context.now)

        case "random":
            let count = Int(format ?? "2") ?? 2
            return context.randomBytes(count).map { String(format: "%02X", $0) }.joined()

        default:
            throw RenderError.unknownPlaceholder(name)
        }
    }

    private static func formattedUID(_ uid: Data, format: String?) -> String {
        let hex = uid.map { String(format: "%02X", $0) }
        switch format {
        case "colon"?: return hex.joined(separator: ":")
        case "dash"?: return hex.joined(separator: "-")
        case "space"?: return hex.joined(separator: " ")
        case nil: return hex.joined()
        default: return hex.joined()
        }
    }

    private static func calendarComponent(_ component: Calendar.Component, from date: Date, width: Int) -> String {
        let value = Calendar(identifier: .gregorian).component(component, from: date)
        return String(format: "%0\(width)d", value)
    }
}
