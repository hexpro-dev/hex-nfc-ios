import Foundation

/// A fully-decoded snapshot of a Japanese transit IC card (Suica family).
///
/// Built by `TransitReader` (in `HexNFCKit`) from a card's history service and
/// handed up to the UI for a read-only presentation. These cards can be read
/// but never written or edited by this app, so there is no mutable counterpart.
public struct TransitCard: Hashable, Sendable, Codable, Identifiable {
    /// The card's FeliCa manufacture ID (IDm), colon-delimited hex.
    public let idmHex: String
    public let system: TransitSystem
    /// Current balance in yen — the post-transaction balance of the newest
    /// history entry, or `0` for a brand-new card with no history.
    public let balanceYen: Int
    /// Transaction history, newest first. Empty if the card has no readable
    /// history (or all history blocks were blank).
    public let transactions: [TransitTransaction]

    public init(
        idmHex: String,
        system: TransitSystem,
        balanceYen: Int,
        transactions: [TransitTransaction]
    ) {
        self.idmHex = idmHex
        self.system = system
        self.balanceYen = balanceYen
        self.transactions = transactions
    }

    /// `Identifiable` via the IDm — unique per physical card.
    public var id: String {
        idmHex
    }

    /// Whether there's any history worth listing.
    public var hasHistory: Bool {
        !transactions.isEmpty
    }
}
