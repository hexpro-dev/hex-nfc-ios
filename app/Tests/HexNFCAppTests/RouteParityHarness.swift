@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCStorage
@testable import HexNFCTagSim
import XCTest

/// Runs one `RouteParity.Cell` down both routes and reports what each one did.
///
/// Two identically seeded simulators, one per route, because a single chip
/// driven twice would have the first run's writes underneath the second. Each is
/// wrapped in a `FaultInjectingSessionFactory` with **no faults armed**: the
/// seam is used here purely as the frame recorder, which is the one thing in
/// this repo that can say what a tap actually put on the wire.
///
/// ## What it drives, and what it answers
///
/// One loop per route, answering whichever gate the flow raises.
/// `.awaitingConfirmation` gets the credential, if that route collects one
/// there, and then `confirm()`. `.needsUnlock` gets the credential through
/// `unlock(with:)`. Everything else is the flow working, and the loop waits.
///
/// The credential is handed over **at most once**. A second request is a finding
/// rather than a retry: a refused `PWD_AUTH` NAKs and the NAK halts the chip, so
/// the app's own rule is that a second attempt is a second tap, and a route that
/// asks twice for a credential the tag accepted has lost track of it. The loop
/// records the count and stops.
///
/// ## Why the loop is bounded
///
/// `waitForConfirmation()` has no deadline and `swift test` applies no per-test
/// timeout, so an unbounded loop turns a regression into a CI job that never
/// ends rather than a red test. An earlier stage of this branch hit exactly that
/// hang. There are two bounds: `until` fails loudly if a phase stops moving, and
/// `stepBudget` caps the number of gates one run may raise.
///
/// ## What it deliberately does not compare
///
/// The number of taps. Operations gates every one of these verbs behind a typed
/// UID; the editor gates only the two that change protection, so its erase is
/// one tap where Operations' is two. That is policy about which acts are
/// dangerous, not behaviour at the tag, and pinning it would pin the policy.
/// Frames are compared over the **work tap**, the last activation that carried
/// any, which is the tap the user was told would change the tag.
///
/// The records. The editor writes a data area and Operations does not, which is
/// what the two routes are for.
///
/// The wording of a refusal, the summary type, and anything on either model that
/// the other has no counterpart for.
@MainActor
enum RouteParityHarness {
    /// The most gates one run may raise before the harness gives up on it.
    ///
    /// The longest legitimate run in the matrix raises four: the identify tap,
    /// the typed-UID gate, an unlock prompt, and the work tap. Double that, so a
    /// regression that adds a gate is still reported as the failure it is rather
    /// than as a budget the harness ran out of.
    static let stepBudget = 8

    /// Run `cell` down both routes and collect what each did.
    static func runBothRoutes(
        _ cell: RouteParity.Cell,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ParityRun {
        let credential = try RouteParity.heldCredential(cell.chip)

        let operationsChip = try await RouteParity.makeChip(cell.chip)
        let editorChip = try await RouteParity.makeChip(cell.chip)
        try await RouteParity.seedGate(on: operationsChip, cell)
        try await RouteParity.seedGate(on: editorChip, cell)

        let before = await readBack(operationsChip, presenting: credential)
        operationsChip.beginActivation()
        editorChip.beginActivation()

        let operationsFactory = FaultInjectingSessionFactory(chip: operationsChip)
        let editorFactory = FaultInjectingSessionFactory(chip: editorChip)

        let operationsRoute = try OperationsParityRoute(model: OperationsFlowModel(
            factory: operationsFactory,
            operation: operation(for: cell),
            credentials: InMemoryTagCredentialStore()
        ))
        let editorRoute = try EditorParityRoute(model: WriteFlowModel(
            factory: editorFactory,
            dataArea: cell.operation == .erase ? .replace([]) : .untouched,
            credentials: InMemoryTagCredentialStore(),
            protection: cell.operation == .arm ? RouteParity.stagedArm(cell.chip) : nil,
            removeProtection: cell.operation == .remove,
            uidConfirmation: .required
        ))

        let operationsRequests = await drive(
            operationsRoute, cell: cell, route: "Operations", credential: credential, file: file, line: line
        )
        let editorRequests = await drive(
            editorRoute, cell: cell, route: "the editor", credential: credential, file: file, line: line
        )

        let after = try credentialAfterTheRun(cell)
        let operationsObservation = await observe(
            operationsRoute, chip: operationsChip, factory: operationsFactory,
            requests: operationsRequests, presenting: after
        )
        let editorObservation = await observe(
            editorRoute, chip: editorChip, factory: editorFactory,
            requests: editorRequests, presenting: after
        )
        return ParityRun(
            cell: cell,
            dataAreaBefore: before.dataArea,
            operations: operationsObservation,
            editor: editorObservation
        )
    }

    // MARK: - The loop

    /// Answer whichever gate the route raises until it ends, and report how many
    /// times it asked for a credential.
    private static func drive(
        _ route: ParityRoute,
        cell: RouteParity.Cell,
        route name: String,
        credential: TagCredential,
        file: StaticString,
        line: UInt
    ) async -> Int {
        var running: [Task<Void, Never>] = [route.begin()]
        var handedOver = false
        var requests = 0
        var steps = 0

        while steps < stepBudget {
            steps += 1
            let gate = route.gate
            switch gate {
            case .finished:
                for task in running {
                    await task.value
                }
                return requests

            case .working:
                await settle(route, past: gate, file: file, line: line)

            case .confirmation(let needsCredential):
                if needsCredential {
                    requests += 1
                    guard !handedOver else { break }
                    handedOver = true
                    route.supplyCredentialAtTheGate(credential)
                }
                route.confirm()
                await settle(route, past: gate, file: file, line: line)

            case .credential:
                requests += 1
                guard !handedOver else { break }
                handedOver = true
                running.append(route.unlock(credential))
                await settle(route, past: gate, file: file, line: line)
            }
            // A second request for a credential the tag accepted is the finding,
            // not something to answer again.
            if requests > 1 {
                break
            }
        }

        XCTFail(
            "\(name) never finished \(cell): \(steps) gates answered, still \(route.gate), "
                + "\(requests) credential request(s). The run is being cancelled so the suite "
                + "fails rather than hangs.",
            file: file, line: line
        )
        route.cancel()
        for task in running {
            await task.value
        }
        return requests
    }

    /// Wait for the flow to leave the gate it is on, failing loudly if it does
    /// not. `until` is the shared settle helper in `SessionCountingDoubles`.
    private static func settle(
        _ route: ParityRoute,
        past gate: ParityGate,
        file: StaticString,
        line: UInt
    ) async {
        await until(file: file, line: line) { route.gate != gate }
    }

    // MARK: - Reading the tag back

    /// What one route left on its simulator.
    ///
    /// Read from the simulator's own accessors rather than over a session, so the
    /// read-back costs no frames and cannot appear in the recorder as something a
    /// route sent. A read-gated Type-2 refuses them until a credential is
    /// presented, so `presenting:` is offered first and only then does the read
    /// give up.
    private static func readBack(
        _ simulator: ChipSimulator,
        presenting credential: TagCredential
    ) async -> (gate: GateReading, dataArea: DataAreaReading) {
        simulator.beginActivation()
        if let reading = attemptReadBack(simulator) {
            return reading
        }
        simulator.beginActivation()
        _ = try? await SimulatedConnectedTag(simulator: simulator).authenticate(credential)
        return attemptReadBack(simulator) ?? (.unreadable, .unreadable)
    }

    private static func attemptReadBack(
        _ simulator: ChipSimulator
    ) -> (gate: GateReading, dataArea: DataAreaReading)? {
        do {
            let state = try simulator.readProtectionState()
            let bytes = try simulator.readNDEF()
            return (.read(state), NDEFCodec.isEmptyMessage(bytes) ? .empty : .bytes(bytes))
        } catch {
            return nil
        }
    }

    /// The credential that opens the tag once the run is over: the arm's new one
    /// where an arm ran, and the one it started with everywhere else.
    private static func credentialAfterTheRun(_ cell: RouteParity.Cell) throws -> TagCredential {
        switch cell.operation {
        case .arm: try RouteParity.armCredential(cell.chip)
        case .erase, .remove: try RouteParity.heldCredential(cell.chip)
        }
    }

    private static func operation(for cell: RouteParity.Cell) throws -> OperationsFlowModel.Operation {
        switch cell.operation {
        case .erase: .erase
        case .arm: try .enableProtection(RouteParity.stagedArm(cell.chip))
        case .remove: .disableProtection
        }
    }

    private static func observe(
        _ route: ParityRoute,
        chip: ChipSimulator,
        factory: FaultInjectingSessionFactory,
        requests: Int,
        presenting credential: TagCredential
    ) async -> RouteObservation {
        let report = factory.report
        // The last activation that carried a frame. Operations' erase and the
        // editor's differ in how many taps they take, so the tap that changed
        // the tag is the one both routes can be compared over.
        let workTap = (1 ... max(report.taps, 1)).last { !report.frames(inTap: $0).isEmpty }
        let frames = workTap.map { report.frames(inTap: $0) } ?? []
        let reading = await readBack(chip, presenting: credential)
        return RouteObservation(
            outcome: route.outcome ?? .refused,
            gate: reading.gate,
            dataArea: reading.dataArea,
            workTapFrames: frames.map(\.redactedDescription),
            credentialFramesInWorkTap: frames.filter {
                NFCTraceRedaction.isSecretFrame($0.request, chip: chip.profile)
            }.count,
            credentialRequests: requests,
            taps: report.taps
        )
    }
}

// MARK: - What a run produced

/// The gate a read-back found.
enum GateReading: Equatable, Sendable {
    /// What the tag reported. Compared whole between the routes, AUTH0 and all,
    /// so a route that armed a different first page is a failure and not a
    /// rounding.
    case read(TagProtection?)
    case unreadable

    var gateClass: RouteParity.GateClass {
        switch self {
        case .read(let state):
            guard let state, state.passwordProtect else { return .open }
            return state.effectiveReadProtect ? .readGated : .writeGated

        case .unreadable:
            return .unreadable
        }
    }
}

/// The data area a read-back found. `.empty` covers both forms real hardware
/// echoes a cleared tag back in, zero bytes and a single Empty record, which is
/// the comparison `NDEFCodec.isEmptyMessage` exists for.
enum DataAreaReading: Equatable, Sendable {
    case empty
    case bytes(Data)
    case unreadable
}

struct RouteObservation: Sendable {
    var outcome: RouteParity.Outcome
    var gate: GateReading
    var dataArea: DataAreaReading
    var workTapFrames: [String]
    var credentialFramesInWorkTap: Int
    var credentialRequests: Int
    var taps: Int
}

struct ParityRun: Sendable {
    var cell: RouteParity.Cell
    /// What both tags carried before either route ran. One value, because both
    /// simulators were built and seeded the same way.
    var dataAreaBefore: DataAreaReading
    var operations: RouteObservation
    var editor: RouteObservation
}

// MARK: - The two routes, behind one shape

/// What a flow is waiting for, in the vocabulary both flows share.
enum ParityGate: Equatable, Sendable {
    case working
    /// The typed-UID gate. `needsCredential` is true where that route also
    /// collects the tag's credential there, which Operations does and the editor
    /// does not.
    case confirmation(needsCredential: Bool)
    /// The unlock prompt.
    case credential
    case finished
}

/// The two flows have no common protocol and should not grow one in production:
/// they answer to different screens and carry different vocabulary. This is the
/// narrow shape the parity loop needs, and it lives in the test tree for that
/// reason.
@MainActor
protocol ParityRoute: AnyObject {
    var gate: ParityGate { get }
    var outcome: RouteParity.Outcome? { get }
    func begin() -> Task<Void, Never>
    func supplyCredentialAtTheGate(_ credential: TagCredential)
    func confirm()
    func unlock(_ credential: TagCredential) -> Task<Void, Never>
    func cancel()
}

@MainActor
final class OperationsParityRoute: ParityRoute {
    let model: OperationsFlowModel

    init(model: OperationsFlowModel) {
        self.model = model
    }

    var gate: ParityGate {
        switch model.phase {
        case .awaitingConfirmation: .confirmation(needsCredential: model.requiresUnlockCredential)
        case .needsUnlock: .credential
        case .done, .error: .finished
        default: .working
        }
    }

    var outcome: RouteParity.Outcome? {
        switch model.phase {
        case .done: .completed
        case .error: .refused
        default: nil
        }
    }

    func begin() -> Task<Void, Never> {
        Task { await model.begin() }
    }

    func supplyCredentialAtTheGate(_ credential: TagCredential) {
        model.supplyUnlockCredential(credential)
    }

    func confirm() {
        model.confirm()
    }

    func unlock(_ credential: TagCredential) -> Task<Void, Never> {
        Task { await model.unlock(with: credential) }
    }

    func cancel() {
        model.cancel()
    }
}

@MainActor
final class EditorParityRoute: ParityRoute {
    let model: WriteFlowModel

    init(model: WriteFlowModel) {
        self.model = model
    }

    var gate: ParityGate {
        switch model.phase {
        // This route has no field at the typed-UID gate: it is handed whatever
        // the editor holds at construction and asks through `.needsUnlock`
        // otherwise, which is the gate below.
        case .awaitingConfirmation: .confirmation(needsCredential: false)
        case .needsUnlock: .credential
        case .done, .error: .finished
        default: .working
        }
    }

    var outcome: RouteParity.Outcome? {
        switch model.phase {
        case .done: .completed
        case .error: .refused
        default: nil
        }
    }

    func begin() -> Task<Void, Never> {
        Task { await model.begin() }
    }

    func supplyCredentialAtTheGate(_: TagCredential) {}

    func confirm() {
        model.confirm()
    }

    func unlock(_ credential: TagCredential) -> Task<Void, Never> {
        Task { await model.unlock(with: credential) }
    }

    func cancel() {
        model.reset()
    }
}
