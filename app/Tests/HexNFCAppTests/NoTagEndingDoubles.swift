@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// Vends the sessions a test scripted, one per `makeSession()`, in order.
///
/// The no-tag suites turn on *which* session of a flow ended how. A cancel is
/// reported quietly only while no earlier session of the flow had a tag, so a
/// test has to be able to say "this tap had a tag, and the next one was
/// cancelled with nothing in the field". No other factory here can: they vend
/// one behaviour for every session.
///
/// An unscripted session fails the test rather than handing out a default. A
/// flow that opens more sessions than the test expected is a flow the test has
/// stopped describing.
final class ScriptedSessionFactory: TagSessionFactory, @unchecked Sendable {
    private var script: [() -> TagSession]
    private(set) var made: [TagSession] = []

    init(_ script: [() -> TagSession]) {
        self.script = script
    }

    /// Every session over the same chip, so state carries across taps the way
    /// it does on one physical tag, with one behaviour each.
    convenience init(chip: ChipSimulator, _ behaviours: [SimulatedSession.Behaviour]) {
        self.init(behaviours.map { behaviour in { SimulatedSession(chip: chip, behaviour: behaviour) } })
    }

    func makeSession() -> TagSession {
        guard !script.isEmpty else {
            XCTFail("session \(made.count + 1) was not scripted")
            let stray = SimulatedSession(chip: NTAG215Simulator(), behaviour: .cancelledAfterDetection)
            made.append(stray)
            return stray
        }
        let session = script.removeFirst()()
        made.append(session)
        return session
    }

    /// The simulated session behind the `index`th `makeSession()`, for asserting
    /// how it was ended.
    func simulated(_ index: Int) throws -> SimulatedSession {
        let session = made.indices.contains(index) ? made[index] as? SimulatedSession : nil
        return try XCTUnwrap(session, "no simulated session \(index); \(made.count) were made")
    }
}

/// The copy the flows show for the two endings when they are still reported,
/// read from `TagError` rather than restated, so a copy change cannot pass
/// these tests by accident.
enum NoTagEndingCopy {
    static var cancelled: String {
        String(localized: TagError.sessionCancelled().userMessage)
    }

    static var timedOut: String {
        String(localized: TagError.sessionTimeout().userMessage)
    }
}

/// A session whose `start` fails with an error that is not a `TagError`.
///
/// Every flow has a second `catch` for these, and it counts them as contact:
/// no session vouched for an empty field, so the ending may have come from a
/// tag. The kit throws none today, which is why only a double can reach that
/// branch. No tag response is modelled; the error never leaves the host.
final class ForeignErrorSession: TagSession, @unchecked Sendable {
    struct Failure: Error {}

    private(set) var didInvalidate = false

    func start(alert _: String) async throws -> ConnectedTag {
        throw Failure()
    }

    func updateAlert(_: String) async {}

    func invalidate(error _: String?) async {
        didInvalidate = true
    }
}
