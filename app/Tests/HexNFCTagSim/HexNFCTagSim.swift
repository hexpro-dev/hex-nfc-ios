import Foundation
import HexNFCKit

/// Test-only chip simulator library. Real chip simulators (NTAG213/215/216,
/// NTAG424 DNA, ISO 15693, MIFARE Ultralight EV1, EM V10/V11/V16) are added
/// in Phase 1 under `Simulators/`.
///
/// This target is declared as a regular `.target` in `Package.swift` (not a
/// `.testTarget`) so that multiple test targets can depend on it. It has no
/// `.library` product, which is what keeps it from linking into the shipping
/// app.
public enum HexNFCTagSim {
    public static let moduleName = "HexNFCTagSim"
}
