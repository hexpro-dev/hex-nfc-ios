import Foundation

/// Module marker. Design tokens (`HexTokens`), motion presets, the signature
/// `HexTransition`, and component primitives (`HexCard`, `HexButton`, etc.)
/// live in this target.
///
/// Brand colors must be referenced through this module's tokens — a grep for
/// any other hex literal in the codebase is a convention violation.
public enum HexNFCDesign {
    public static let moduleName = "HexNFCDesign"
}
