import HexNFCKit

public extension ChipCatalog {
    /// Catalog lookup for a chip the caller already knows is in the catalog,
    /// which is every simulator and every fixture: each one is written *for* a
    /// named part, so a miss means the catalog lost an entry, not that the
    /// caller passed something unexpected.
    ///
    /// This replaced eleven call sites that force-unwrapped `profile(for:)`.
    /// The unwrap was not wrong, it was just mute: it trapped on a line whose
    /// only content was the lookup, with nothing in the crash to say which of
    /// the three EM simulators declared on that screen had gone missing. Naming
    /// the chip costs one line here and is the whole diagnosis there.
    ///
    /// Test-target only, which is why a trap is the right answer at all: the
    /// shipping app must never crash on a chip it does not recognise, so
    /// `profile(for:)` keeps returning an optional for it.
    static func require(
        _ id: ChipID,
        file: StaticString = #file,
        line: UInt = #line
    ) -> ChipProfile {
        guard let profile = profile(for: id) else {
            fatalError("ChipCatalog has no profile for \(id)", file: file, line: line)
        }
        return profile
    }
}
