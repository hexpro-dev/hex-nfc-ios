import Foundation
@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// `TagError.endedBeforeAnyTag`: the session's word that nothing was ever
/// detected before it ended.
///
/// The app reports a cancel or a timeout quietly only on that word, so it may
/// be given only by the code that would have seen a tag, and never by default.
final class SessionEndingVouchTests: XCTestCase {
    func test_theVouchIsOffByDefault_andOutsideEquality() {
        let plain = TagError.sessionCancelled(diagnostics: "x")
        XCTAssertFalse(plain.endedBeforeAnyTag, "a cancel nobody vouched for keeps the report it always had")
        XCTAssertFalse(TagError.sessionTimeout(diagnostics: "x").endedBeforeAnyTag)

        let vouched = plain.endingBeforeAnyTag()
        XCTAssertTrue(vouched.endedBeforeAnyTag)
        XCTAssertEqual(vouched.kind, plain.kind)
        XCTAssertEqual(vouched, plain, "an error's identity is what happened, not what the session knew")
    }

    /// The simulator vouches exactly where CoreNFC would: before any tag. A
    /// cancel or timeout that lands after detection does not.
    func test_simulatedSessionsVouchOnlyWhenNothingWasDetected() async {
        let cases: [(SimulatedSession.Behaviour, TagError.Kind, Bool)] = [
            (.cancelled, .sessionCancelled, true),
            (.timeout, .sessionTimeout, true),
            (.cancelledAfterDetection, .sessionCancelled, false),
            (.timedOutAfterDetection, .sessionTimeout, false),
        ]
        for (behaviour, kind, vouched) in cases {
            do {
                _ = try await SimulatedSession(chip: NTAG215Simulator(), behaviour: behaviour).start(alert: "")
                XCTFail("\(behaviour) must not hand up a tag")
            } catch let error as TagError {
                XCTAssertEqual(error.kind, kind, "\(behaviour)")
                XCTAssertEqual(error.endedBeforeAnyTag, vouched, "\(behaviour)")
            } catch {
                XCTFail("\(behaviour) threw \(error)")
            }
        }
    }

    /// `CoreNFCSession` is `#if os(iOS)`, so no test on this host can run it.
    /// This holds the two lines the vouch depends on, in the idiom of
    /// `SessionHolderStorageTests`: detection is recorded before `didDetect`
    /// does anything else, and the invalidation vouches only while none was.
    func test_theProductionSessionVouchesOnlyBeforeDidDetect() throws {
        let url = URL(fileURLWithPath: #filePath) // …/app/Tests/HexNFCKitTests/SessionEndingVouchTests.swift
            .deletingLastPathComponent() // …/HexNFCKitTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/app
            .appendingPathComponent("Sources/HexNFCKit/CoreNFCSession.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let detect = try XCTUnwrap(source.range(of: "didDetect tags: [NFCTag]"), "didDetect moved or was renamed")
        let afterDetect = source[detect.upperBound...]
        let marked = try XCTUnwrap(afterDetect.range(of: "detectedATag = true"), "didDetect must record the detection")
        let firstGuard = try XCTUnwrap(afterDetect.range(of: "guard let first = tags.first"))
        XCTAssertLessThan(marked.lowerBound, firstGuard.lowerBound, "recorded before anything can return early")

        let invalidate = try XCTUnwrap(source.range(of: "didInvalidateWithError error: Error"))
        let body = source[invalidate.upperBound...].prefix(1200)
        XCTAssertTrue(
            body.contains("if !detectedATag {\n            translated = translated.endingBeforeAnyTag()"),
            "the invalidation may vouch for an empty field only while no tag was detected"
        )
        XCTAssertEqual(
            source.components(separatedBy: "endingBeforeAnyTag()").count - 1, 1,
            "and nowhere else in the production session"
        )
    }

    /// Once set, the detection stays set for the life of the session.
    ///
    /// A re-poll after a refused probe (`restartPolling()`) detects the same tag
    /// again, and it had answered frames the first time. A reset anywhere would
    /// let a cancel during that re-poll vouch for an empty field, and the app
    /// would then report quietly on a tag that had already been in play. So the
    /// flag has exactly one declaration, starting false, and every other
    /// assignment sets it true.
    func test_theProductionSessionNeverForgetsADetection() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HexNFCKit/CoreNFCSession.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(\bvar\s+)?\bdetectedATag\s*=\s*([A-Za-z_.!]+)"#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let found = matches.map { match -> (isDeclaration: Bool, value: String) in
            let declaration = match.range(at: 1).location != NSNotFound
            let value = Range(match.range(at: 2), in: source).map { String(source[$0]) } ?? ""
            return (declaration, value)
        }

        let declarations = found.filter(\.isDeclaration)
        XCTAssertEqual(declarations.count, 1, "one declaration")
        XCTAssertEqual(declarations.first?.value, "false", "and it starts with nothing detected")
        let assignments = found.filter { !$0.isDeclaration }
        XCTAssertFalse(assignments.isEmpty, "didDetect must record the detection")
        for assignment in assignments {
            XCTAssertEqual(assignment.value, "true", "the detection is never cleared")
        }
        XCTAssertFalse(source.contains("detectedATag.toggle()"), "nor toggled")
    }
}
