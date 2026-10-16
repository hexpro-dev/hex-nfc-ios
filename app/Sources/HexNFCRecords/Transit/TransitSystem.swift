import Foundation

/// The transit "system" a card belongs to, keyed by its FeliCa system code.
///
/// All the Japanese IC transit cards this app reads — Suica, PASMO, ICOCA,
/// TOICA, manaca, SUGOCA, nimoca, Kitaca, PiTaPa, HAYAKAKEN, etc. — share the
/// single nationwide interoperable system code `0x0003` (the "Cybernetics
/// standard"). They cannot be told apart from the system code alone, so we
/// model them as one `.suicaFamily` system and present a single generic theme.
///
/// Naming the transit networks factually is fine: the brand rules forbid
/// naming competing apps and referencing game-collectible IP, and neither
/// applies here.
public enum TransitSystem: Hashable, Sendable, Codable {
    /// FeliCa system code `0x0003` — the interoperable Japanese transit family.
    case suicaFamily
    /// Any other FeliCa system code we recognise structurally but don't decode.
    case unknown(UInt16)

    public init(systemCode: UInt16) {
        switch systemCode {
        case 0x0003: self = .suicaFamily
        default: self = .unknown(systemCode)
        }
    }

    /// Raw 16-bit FeliCa system code.
    public var systemCode: UInt16 {
        switch self {
        case .suicaFamily: 0x0003
        case .unknown(let code): code
        }
    }

    /// Whether this app knows how to decode the card's history.
    public var isDecodable: Bool {
        if case .suicaFamily = self {
            return true
        }
        return false
    }
}
