import Foundation
import XCTest

/// Keeps unbounded motion behind the Reduce Motion gate.
///
/// The distinction this enforces is not "animated" versus "still". Almost
/// everything in the app animates, and suppressing one-shot springs and opacity
/// cross-fades would make it *worse* for the reader who asked: a cross-fade is
/// the recommended fallback, and killing list insert/remove animations costs
/// comprehension. What has to be gated is motion the reader can neither outlast
/// nor predict, which here means two things: it repeats without end, or it is
/// involuntary optical flow.
///
/// Both times this app shipped an ungated animation, the gate had been left to
/// a *screen*. `ScanSheet` never declared a reduce-motion environment value at
/// all, and `TransitResultSheet` declared one nothing read. So the real fix is
/// `HexTokens.Motion.scanPulse` being module-internal and reachable only
/// through `View.hexPulse(active:)`, which carries the gate: a screen cannot
/// forget what it cannot spell. This test is the backstop for the next
/// unbounded primitive somebody reaches for, which the compiler will not catch.
///
/// It reads source text off disk through `#filePath`, in the idiom of
/// `PromoImportContainmentTests`, because where an animation is written is a
/// property of the source and the built module has no memory of it.
///
/// What it cannot prove is that a declared gate is actually *read*. That is
/// what the `internal` demotion and review are for.
final class ContinuousMotionGateTests: XCTestCase {
    /// Unbounded motion primitives. Each runs until something stops it.
    private static let unboundedMotion = [
        "repeatForever",
        "TimelineView(.animation",
        ".phaseAnimator(",
        "Motion.scanPulse",
    ]

    /// The one file allowed to *define* a forever-repeating curve.
    private static let curveDefinition = "HexTokens.swift"

    /// Reading either flag counts. The house rule is to read both, but a file
    /// that reads one is gated, not ungated, and this test is about the gate
    /// existing rather than about its completeness.
    private static let gateMarkers = ["hexReduceMotion", "accessibilityReduceMotion"]

    private static var packageSources: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCAppTests/ContinuousMotionGateTests.swift
            .deletingLastPathComponent() // …/HexNFCAppTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// Every `.swift` file under `Sources`, except the vendored copy, which is
    /// kept byte for byte and is not ours to hold to this rule.
    private func sourceFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: Self.packageSources, includingPropertiesForKeys: nil
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard !url.pathComponents.contains("HexPromoKit") else { continue }
            files.append(url)
        }
        XCTAssertFalse(files.isEmpty, "walked \(Self.packageSources.path) and found no Swift files")
        return files
    }

    /// Source with `//` comments removed, so prose about an animation does not
    /// read as the animation. Deliberately naive; it only has to be right about
    /// this repo's comment style, and a false positive here is a failing test
    /// rather than a shipped bug.
    private func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex ..< comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    func test_theOnlyForeverRepeatingCurve_isTheOneInHexTokens() throws {
        for url in try sourceFiles() where url.lastPathComponent != Self.curveDefinition {
            XCTAssertFalse(
                try code(of: url).contains("repeatForever"),
                """
                \(url.lastPathComponent) declares a `repeatForever` animation. \
                The app's one looping curve lives in \(Self.curveDefinition) and \
                is reached through `View.hexPulse(active:)`, which gates it on \
                Reduce Motion. A second one here would not be gated.
                """
            )
        }
    }

    func test_scanPulse_isNotReachableFromOutsideTheDesignModule() throws {
        for url in try sourceFiles() {
            let isDesignModule = url.pathComponents.contains("HexNFCDesign")
            guard !isDesignModule else { continue }
            XCTAssertFalse(
                try code(of: url).contains("Motion.scanPulse"),
                """
                \(url.lastPathComponent) names `Motion.scanPulse` directly. It is \
                internal to HexNFCDesign so that screens have to go through \
                `hexPulse(active:)` and pick up its Reduce Motion gate; if this \
                compiles, the token was made public again.
                """
            )
        }
    }

    func test_everyFileApplyingUnboundedMotion_alsoReadsAReduceMotionFlag() throws {
        for url in try sourceFiles() {
            let source = try code(of: url)
            let applied = Self.unboundedMotion.filter { marker in
                // The file that defines the curve does not have to gate it;
                // the modifier that applies it does.
                if marker == "repeatForever", url.lastPathComponent == Self.curveDefinition {
                    return false
                }
                if marker == "Motion.scanPulse", url.lastPathComponent == Self.curveDefinition {
                    return false
                }
                return source.contains(marker)
            }
            guard !applied.isEmpty else { continue }
            XCTAssertTrue(
                Self.gateMarkers.contains(where: source.contains),
                """
                \(url.lastPathComponent) applies unbounded motion (\(applied.joined(separator: ", "))) \
                but reads no Reduce Motion flag. Either gate it on \
                `\\.accessibilityReduceMotion` and `\\.hexReduceMotion`, or move it \
                behind a self-gating modifier the way `hexPulse` wraps the scan pulse.
                """
            )
        }
    }
}
