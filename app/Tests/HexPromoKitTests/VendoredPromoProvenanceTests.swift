import CryptoKit
import Foundation
import XCTest

/// The "do not edit the vendored copy" rule, enforced instead of requested.
///
/// `app/Sources/HexPromoKit/` is byte for byte from `hexpro-dev/hex-promo` at a
/// pinned commit, and its `PROVENANCE.md` records a sha256 and a line count per
/// file. A rule like that decays the first time somebody makes one small,
/// correct-looking fix in there, so this parses the manifest, hashes the real
/// files, and fails on any difference. The lint and format jobs both skip that
/// directory, so nothing else in CI would notice.
///
/// The manifest is parsed out of the document rather than restated in Swift, so
/// the table a human reads on a re-sync is the table the test enforces. Two
/// copies of it would drift the same way the vendored files can.
///
/// The directory is resolved through `#filePath` for the reason
/// `AIDDeclarationTests` reads `Info.plist` off disk: these are assertions about
/// the repository's own artifacts, not about whatever a test bundle happened to
/// be built with, and a copied-in resource would be a third copy to drift. A
/// missing `PROVENANCE.md` FAILS rather than skipping, because a guard that
/// quietly passes when it cannot find its subject is not a guard.
///
/// The pinned commit gets the same treatment, for the same reason: the `Commit`
/// row is the only place this repository records it, and the pin-consistency
/// test below checks every other site naming a hex-promo commit against it.
///
/// What this cannot tell you is whether the copy is STALE. CI has no hex-promo
/// checkout, so freshness is a manual step on the release checklist and the
/// command for it is in `PROVENANCE.md` itself.
final class VendoredPromoProvenanceTests: XCTestCase {
    /// One row of the manifest table.
    private struct Entry {
        let file: String
        let sha256: String
        let lines: Int
    }

    private static var vendoredDirectory: URL {
        URL(fileURLWithPath: #filePath) // …/app/Tests/HexPromoKitTests/VendoredPromoProvenanceTests.swift
            .deletingLastPathComponent() // …/HexPromoKitTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexPromoKit", isDirectory: true)
    }

    private static var provenanceURL: URL {
        vendoredDirectory.appendingPathComponent("PROVENANCE.md")
    }

    private func provenanceText() throws -> String {
        let url = Self.provenanceURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("no PROVENANCE.md at \(url.path); the vendored copy has no pinned origin")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Rows shaped ``| `File.swift` | `<64 hex>` | <n> |``.
    ///
    /// The sha256 recorded for `PromoBanner.swift` further down the document is
    /// prose rather than a table row, so anchoring at the start of a line keeps
    /// the file that was deliberately NOT copied out of the manifest.
    ///
    /// A row may name a path rather than a bare file name. All four are at the
    /// top level today, but everything below compares a row against a path
    /// relative to the vendored directory, and a file the manifest cannot spell
    /// is a file nobody can record.
    private func manifest() throws -> [Entry] {
        let pattern = #"^\|\s*`((?:[A-Za-z0-9_]+/)*[A-Za-z0-9_]+\.swift)`\s*\|\s*`([0-9a-f]{64})`\s*\|\s*(\d+)\s*\|$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let text = try provenanceText()
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let file = Range(match.range(at: 1), in: text),
                  let hash = Range(match.range(at: 2), in: text),
                  let lines = Range(match.range(at: 3), in: text),
                  let count = Int(text[lines])
            else {
                return nil
            }
            return Entry(file: String(text[file]), sha256: String(text[hash]), lines: count)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let digest = try SHA256.hash(data: Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Every `.swift` file under the vendored directory, as a path relative to
    /// it.
    ///
    /// Recursive, because SwiftPM compiles a target's whole subtree and not just
    /// its top level. A flat listing would let `Nested/PromoBanner.swift` build
    /// into the shipping app with every assertion in this file green, which is
    /// the one arrival they exist to catch.
    ///
    /// Relative paths rather than file names, so a recorded name cannot be
    /// borrowed one directory down: `Views/PromoModels.swift` does not match the
    /// manifest's `PromoModels.swift`, so it never gets hashed against that
    /// row's sha256 and shows up as the unrecorded file it is.
    private func vendoredSwiftFiles() throws -> Set<String> {
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: Self.vendoredDirectory.path)
        return Set(subpaths.filter { $0.hasSuffix(".swift") })
    }

    // MARK: - The pin

    /// One place in the repository that names a hex-promo commit.
    private struct CommitReference {
        let path: String
        let line: Int
        let sha: String
    }

    private static var repositoryRoot: URL {
        vendoredDirectory // …/app/Sources/HexPromoKit
            .deletingLastPathComponent() // …/Sources
            .deletingLastPathComponent() // …/app
            .deletingLastPathComponent() // the repository root
    }

    /// Directories the pin scan walks past: the git object store, build
    /// products, the generated public mirror, which holds this repository's
    /// files as they were at the last sync and would report a pin nobody can
    /// update without running a release, and the `hex-docs` submodule.
    ///
    /// The submodule is another repository, checked out inside this one. Its own
    /// tests name hex-promo commits, which are its pins to keep current and not
    /// this repository's sites; with it populated the scan read them as stale
    /// copies of ours and failed a green tree (2026-09-16, after the submodule
    /// pin moved). A worktree without submodules passed the same commit, which
    /// is how a walk of "the repository" quietly became a walk of two.
    private static let unscannedDirectories: Set<String> = [
        ".build", ".git", ".public-mirror", ".swiftpm", "DerivedData", "hex-docs", "node_modules", "xcuserdata",
    ]

    /// A run of lower-case hex with no letter or digit either side, at one of
    /// the two lengths a git commit is written at: 40 for a full sha, 7 to 12
    /// for an abbreviation. Abbreviated as well as full, because the site that
    /// stayed invisible longest wrote the pin seven characters long. The gap
    /// between the bands is what keeps non-commit hex out: `{7,40}` also matched
    /// the sixteen-character media etag in the ported fixtures, which would have
    /// this test report a stale pin on a line holding no commit at all. The
    /// lookarounds keep the manifest's 64-character sha256 rows out, and they
    /// refuse any letter rather than only hex ones, because the App Store link
    /// `apps.apple.com/app/id6801457461` sits near `hexpro-dev` in the README,
    /// and with only hex refused, everything after its leading `i` read as an
    /// abbreviated commit.
    private static let commitPattern = #"(?<![0-9A-Za-z])(?:[0-9a-f]{7,12}|[0-9a-f]{40})(?![0-9A-Za-z])"#

    /// Lower-cased text that marks a commit found near it as a hex-promo one.
    ///
    /// Not the bare org name. `hexpro-dev/hex-promo` is caught by `hex-promo`
    /// already, and since 1.0 the org also holds the public mirror, so a
    /// commit written beside `hexpro-dev/hex-nfc-ios` read as a stale pin.
    private static let hexPromoMarkers = ["hex-promo", "hexpromokit"]

    /// The commit recorded in `PROVENANCE.md`'s `Commit` row, which is the pin.
    /// Parsed rather than restated as a literal in Swift, for the reason the
    /// manifest table is parsed: a second copy is a second thing to update on a
    /// re-sync, and it is always the copy nobody reads that goes stale.
    private func pinnedCommit() throws -> String {
        let text = try provenanceText()
        let pattern = #"^\|\s*Commit\s*\|\s*`([0-9a-f]{40})`\s*\|$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        let parsed = regex.firstMatch(in: text, range: range)
            .flatMap { Range($0.range(at: 1), in: text) }
            .map { String(text[$0]) }
        return try XCTUnwrap(
            parsed,
            "PROVENANCE.md has no `| Commit | <40 hex characters> |` row, and that row is the pin"
        )
    }

    /// Every place in the repository that names a hex-promo commit.
    ///
    /// A scan rather than a list of paths, because a list only knows the files
    /// that existed when it was written and a site nobody remembered is the
    /// defect this exists for. Telling a hex-promo commit from any other sha is
    /// what the scan needs in exchange, and proximity does it: the sha has to
    /// sit within a few lines of `hex-promo`, `hexpro-dev` or `HexPromoKit`. A
    /// pinned GitHub Action elsewhere is therefore none of this test's business,
    /// and the gap left is a hex-promo commit written with no mention of
    /// hex-promo near it, which is far narrower than the gap a path list leaves.
    private func hexPromoCommitReferences() throws -> [CommitReference] {
        let root = Self.repositoryRoot
        let regex = try NSRegularExpression(pattern: Self.commitPattern)
        var references: [CommitReference] = []
        for path in try scannableFiles() {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let haystack = text.lowercased()
            guard Self.hexPromoMarkers.contains(where: { haystack.contains($0) }) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (offset, line) in lines.enumerated() {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                let shas: [String] = regex.matches(in: line, range: range).compactMap { match in
                    guard let matched = Range(match.range, in: line) else { return nil }
                    let token = String(line[matched])
                    // A short run has to hold both a digit and a letter to read
                    // as a commit: seven characters of hex otherwise catches
                    // plain numbers and the few English words spelled in a to
                    // f, and this would fail over prose. A short sha that is
                    // all one or the other costs a detection, not a false
                    // failure.
                    guard token.contains(where: \.isNumber), token.contains(where: \.isLetter) else { return nil }
                    return token
                }
                guard !shas.isEmpty, Self.namesHexPromo(near: offset, in: lines) else { continue }
                references += shas.map { CommitReference(path: path, line: offset + 1, sha: $0) }
            }
        }
        return references
    }

    /// Whether a hex-promo marker sits within three lines of `offset`.
    ///
    /// Three because the widest real case is `PROVENANCE.md`'s first table,
    /// where the `Commit` row sits two rows below the `Upstream` row that names
    /// the repository.
    private static func namesHexPromo(near offset: Int, in lines: [String]) -> Bool {
        let window = 3
        let lower = max(0, offset - window)
        let upper = min(lines.count - 1, offset + window)
        let context = lines[lower ... upper].joined(separator: "\n").lowercased()
        return hexPromoMarkers.contains { context.contains($0) }
    }

    /// Every file under the repository root worth reading, as a path relative to
    /// it.
    ///
    /// Hidden files are included on purpose. `.github/workflows/` checked
    /// hex-promo out until vendoring removed that step, and a workflow that
    /// names the pin is the kind of site a hand-written list of paths misses.
    private func scannableFiles() throws -> [String] {
        let root = Self.repositoryRoot
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            XCTFail("could not walk \(root.path); the pin scan has nothing to read")
            return []
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var paths: [String] = []
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                if Self.unscannedDirectories.contains(url.lastPathComponent) {
                    walk.skipDescendants()
                }
                continue
            }
            // A commit reference is text. Anything measured in megabytes here
            // is a design asset that cannot decode as UTF-8 anyway.
            guard (values.fileSize ?? 0) <= 1_000_000, url.path.hasPrefix(prefix) else { continue }
            paths.append(String(url.path.dropFirst(prefix.count)))
        }
        return paths
    }

    func test_everyVendoredFileMatchesTheHashRecordedInProvenance() throws {
        let entries = try manifest()
        XCTAssertFalse(entries.isEmpty, "PROVENANCE.md records no files; the manifest table did not parse")
        for entry in entries {
            let url = Self.vendoredDirectory.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("PROVENANCE.md names \(entry.file), which is not in the vendored directory")
                continue
            }
            XCTAssertEqual(
                try sha256(of: url),
                entry.sha256,
                "\(entry.file) differs from the pinned upstream copy; fix it upstream and re-vendor"
            )
        }
    }

    /// A second, cheaper reading of the same claim. A hash mismatch says "this
    /// changed"; a line count says roughly how much, which is the first thing
    /// anybody wants to know when the hash assertion goes red.
    ///
    /// It carries the hash test's empty-manifest guard and fails rather than
    /// skips on a file it cannot read, for the same reason that test does: with
    /// neither, this passes when the table parses no rows at all and passes when
    /// a recorded file has been deleted. The other two assertions are what would
    /// go red in both cases, which is exactly how a check comes to read as
    /// coverage it does not provide.
    func test_everyVendoredFileMatchesTheLineCountRecordedInProvenance() throws {
        let entries = try manifest()
        XCTAssertFalse(entries.isEmpty, "PROVENANCE.md records no files; the manifest table did not parse")
        for entry in entries {
            let url = Self.vendoredDirectory.appendingPathComponent(entry.file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("PROVENANCE.md names \(entry.file), which could not be read as UTF-8")
                continue
            }
            // The files end with a trailing newline, so dropping it first stops
            // the split leaving a final empty element that is not a line. This
            // is `wc -l`, which is what the manifest was written from.
            let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
            XCTAssertEqual(
                lines,
                entry.lines,
                "\(entry.file) is \(lines) lines, and PROVENANCE.md records \(entry.lines)"
            )
        }
    }

    /// The direction the hash assertion cannot see: a NEW file arriving
    /// unrecorded. Hashing what the manifest names says nothing about a fifth
    /// file sitting beside them, or under them.
    func test_theVendoredDirectoryHoldsExactlyTheRecordedSwiftFiles() throws {
        let onDisk = try vendoredSwiftFiles()
        let recorded = try Set(manifest().map(\.file))
        XCTAssertEqual(
            onDisk,
            recorded,
            "the vendored directory and PROVENANCE.md disagree about which files are here"
        )
    }

    /// The pin has to be recorded where the rest of the repository can be
    /// checked against it, which means the `Commit` row specifically.
    ///
    /// This used to assert that the document held a hardcoded sha somewhere in
    /// its text, and it passed while a second occurrence further down that same
    /// document named a different commit: `contains` cannot tell the pin from a
    /// mention of it. The literal is gone from here too, being one more site to
    /// update on a re-sync and the one nobody reads.
    func test_provenanceNamesThePinnedUpstreamCommit() throws {
        let text = try provenanceText()
        // Fails unless the `Commit` row is present and holds a full sha. An
        // unparseable row disarms the pin-consistency test below, which has
        // nothing else to compare against.
        _ = try pinnedCommit()
        XCTAssertTrue(
            text.contains("hexpro-dev/hex-promo"),
            "PROVENANCE.md no longer names the upstream repository"
        )
    }

    /// Every site in the repository that names a hex-promo commit names the one
    /// `PROVENANCE.md` pins.
    ///
    /// Two review rounds were lost to the same defect: a document stating how
    /// many places the sha appears, and an edit elsewhere making the number
    /// wrong. Counting is the bug, so nothing counts here. The `Commit` row is
    /// the pin, this finds the rest, and a re-sync is told which sites it missed
    /// rather than trusted to remember them. The one that matters most is the
    /// freshness command inside `PROVENANCE.md`: left on the previous commit it
    /// compares upstream against something that is no longer the pin and answers
    /// "nothing to do" from then on, which is a stale copy that reads current.
    func test_everySiteNamingAHexPromoCommitNamesThePinnedOne() throws {
        let root = Self.repositoryRoot
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("app/Package.swift").path),
            "\(root.path) is not the repository root, so the scan below covers a subtree of it and proves less"
        )

        let pin = try pinnedCommit()
        let references = try hexPromoCommitReferences()
        let elsewhere = references.filter { $0.path != "app/Sources/HexPromoKit/PROVENANCE.md" }

        // Non-vacuity, in both directions this can quietly assert nothing: a
        // scan that finds no sites, and a scan that never reads past the
        // document it parsed the pin out of. `app/Package.swift` names the
        // commit and sits beside this file in every checkout, so "at least one
        // site outside PROVENANCE.md" holds wherever the suite runs.
        XCTAssertFalse(references.isEmpty, "the scan found no hex-promo commit, not even the pin it parsed")
        XCTAssertFalse(
            elsewhere.isEmpty,
            "the scan reached nothing but PROVENANCE.md, so it is asserting nothing about the rest of the repo"
        )

        // `hasPrefix` rather than equality, so an abbreviated commit is checked
        // on the characters it does spell instead of being waved through.
        let stale = references.filter { !pin.hasPrefix($0.sha) }
        XCTAssertTrue(
            stale.isEmpty,
            "PROVENANCE.md pins \(pin); these still name an older commit:\n"
                + stale.map { "  \($0.path):\($0.line) names \($0.sha)" }.joined(separator: "\n")
        )
    }

    /// `PromoBanner.swift` was deliberately not taken. A banner has to look like
    /// the app it sits in, so a vendored one would have to be adapted, and an
    /// adapted vendored file turns every later re-sync into a merge. Leaving it
    /// out is also what keeps SwiftUI, UIKit, and AVKit out of this target.
    /// Somebody re-syncing by copying the whole directory would undo that
    /// silently, so the omission is asserted rather than trusted.
    ///
    /// At any depth, not just at the top level. The file compiles into the app
    /// wherever under the target it lands, so a probe at one path would be
    /// satisfied by a copy sitting one directory away from it.
    func test_theUpstreamBannerViewWasNotVendored() throws {
        let banners = try vendoredSwiftFiles()
            .filter { URL(fileURLWithPath: $0).lastPathComponent == "PromoBanner.swift" }
        XCTAssertTrue(
            banners.isEmpty,
            "upstream's PromoBanner.swift is back at \(banners.sorted()); "
                + "the app draws its own banner and does not use that one"
        )
    }
}
