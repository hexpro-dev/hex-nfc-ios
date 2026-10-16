import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

// MARK: - Where this lives, and why it lives here

// One reusable fault-injection seam for the simulated tag stack.
//
// ## Why the seam decorates the tag rather than the chip
//
// Every fault double this replaced was a full `ChipSimulator` conformance
// wrapping another simulator, and each one paid the same two prices.
// `ChipSimulator.handle(command:)` returns `Data` and cannot throw, so a double
// built there can only ever answer *something*: there was no way to model the
// transport losing a frame, which is how a real reader reports a tag that
// slipped, and no way to model a chip that applied a write whose answer never
// arrived. And a new requirement on `ChipSimulator` broke all six doubles at
// once, because each was ~80 lines of forwarding that existed only to reach one
// opcode.
//
// Decorating `ConnectedTag.transceive` fixes both. It is the level the
// transport actually reports at (`CoreNFCSession` surfaces a lost frame by
// throwing, never by returning zero bytes), and it is one override plus eleven
// forwards rather than a whole chip.
//
// ## Why the seam lives in HexNFCTagSim
//
// `HexNFCTestKit` is a library *product* that `HexNFCApp` links (see
// `Package.swift`), so a fault vocabulary there would reach the release binary,
// and anything that can build a `TagTestContext` could arm one. `HexNFCTagSim`
// is a plain target with no product that the app does not depend on, and it is
// the one target both `HexNFCKitTests` and `HexNFCAppTests` already depend on
// directly. `HexNFCAppTests` does not list `HexNFCTestKit` at all, so a
// vocabulary there would not even be importable from the flow-model tests that
// need it most.
//
// The consequence is deliberate and worth stating: **no test plan step can arm
// a fault.** A test that needs one is an XCTest, not a plan step.
//
// ## What the frame log may and may not print
//
// `TagFaultFrame` keeps the raw request and response bytes, because that is
// what a test asserts against. Those bytes include the password on a
// `PWD_AUTH`, and the key quarters on an Ultralight C key write. So they are
// never interpolated into a message: `redactedDescription` is the only printable
// form, and it is also the `CustomStringConvertible` `description`, so a
// `\(frame)` written by someone who never read this comment still cannot leak.
//
// It is deliberately STRICTER than `CoreNFCSession.isSecretFrame`, rather than a
// copy of it. The live trace decides per frame which ones carry a credential,
// because a traffic view that redacted everything would be useless for
// debugging. This log exists to be asserted against in tests, so it truncates
// every frame to its opcode and at most one parameter byte and asks no
// questions. Two rules with different jobs, and this is the one that may be
// blunt.

// MARK: - Matching

/// Which frames a fault applies to.
///
/// `name` is what a failure message prints, so it names the *shape* of the frame
/// and never carries payload bytes.
public struct FrameMatcher: Sendable {
    public let name: String
    let matches: @Sendable (Data) -> Bool

    /// Every frame.
    public static let any = FrameMatcher(name: "any frame") { _ in true }

    /// Frames whose first byte is `byte`, whatever follows it.
    public static func opcode(_ byte: UInt8) -> FrameMatcher {
        FrameMatcher(name: String(format: "opcode %02X", byte)) { frame in
            frame.first == byte
        }
    }

    /// Frames beginning with these bytes. The Type-2 form `[0xA2, page]` names
    /// one page write exactly, which is why `write(page:)` and `read(page:)`
    /// below are the two shapes worth spelling out.
    public static func prefix(_ bytes: [UInt8], name: String? = nil) -> FrameMatcher {
        let label = name ?? bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return FrameMatcher(name: label) { frame in
            guard frame.count >= bytes.count else { return false }
            return Array(frame.prefix(bytes.count)) == bytes
        }
    }

    /// A Type-2 `WRITE` addressed to one page. Take the page number from
    /// `Type2ConfigLayout` or `ChipMemoryLayout`, never from a literal.
    public static func write(page: Int) -> FrameMatcher {
        prefix([0xA2, UInt8(page)], name: "WRITE p\(page)")
    }

    /// A Type-2 `READ` addressed to one page. Same rule about where the page
    /// number comes from.
    public static func read(page: Int) -> FrameMatcher {
        prefix([0x30, UInt8(page)], name: "READ p\(page)")
    }

    /// Anything else. The name is required rather than optional because it is
    /// the only thing a failure message can say about the frame.
    public static func predicate(
        _ name: String,
        _ body: @escaping @Sendable (Data) -> Bool
    ) -> FrameMatcher {
        FrameMatcher(name: name, matches: body)
    }
}

/// Which occurrence of a match the fault fires on.
///
/// A fault that can only fire on the first match cannot model the failure that
/// matters most in a credential sequence, where the same opcode addresses four
/// different pages in a row and only the third one tears.
public enum FrameOccurrence: Sendable, Hashable {
    /// The first match, and then the fault is spent.
    case first
    /// The Nth match, 1-based, and then the fault is spent.
    case nth(Int)
    /// The Nth match and every one after it.
    case fromNth(Int)
    /// Every match.
    case every

    func isDue(atMatch match: Int) -> Bool {
        switch self {
        case .first: match == 1
        case .nth(let n): match == n
        case .fromNth(let n): match >= n
        case .every: true
        }
    }
}

// MARK: - Effects

/// What the seam does to a frame it matched.
///
/// Note what is *not* here: "the tag left the field". An absent tag is absent
/// from every entry point, including the three that send no frame at all
/// (`readMemory`, `readNDEF`, `writeNDEF`), so it is a state of the tag rather
/// than an effect on a frame. Modelling it as a frame fault inverts the flows it
/// is meant to test: both the write and the scan flow call
/// `ProtectionProbe.presence` first, which reaches `readMemory` and never
/// `transceive`, so the "absence" would not begin until several steps after the
/// tag was supposed to be gone, and the probe would have already recorded the
/// tag as answering. It is armed instead with
/// `FaultInjectingSessionFactory.tagLeavesTheField()`.
public enum TagFaultEffect: Sendable {
    /// **The tag applied the write and the answer never arrived.**
    ///
    /// The frame is forwarded to the chip first, so the state change really
    /// happens; then the answer is thrown away and the caller is told the tag
    /// was lost. The chip is *not* halted: it answered, the reader missed it.
    ///
    /// This is CLAUDE.md's "a refusal may be a lost ACK", and it is the only
    /// effect whose whole point is that the tag's state and the app's belief
    /// have come apart. Every other effect leaves the two agreeing. Nothing in
    /// this repo could model it before, which is why the one abort point the
    /// 2026-09-04 incident actually hit had never run in CI.
    ///
    /// `TagFaultReport.swallowed` is the oracle: it names the frame the chip
    /// applied and carries the answer the seam hid, so a test can prove the
    /// write landed rather than infer it.
    case lostACK

    /// The frame never reached the chip and no answer came back. The caller sees
    /// `TagError.tagLost`.
    ///
    /// The chip is not halted: it heard nothing, so it refused nothing, and it
    /// is still there for the retry. A dropped frame is the tag not answering; a
    /// NAK is the tag refusing, and only the second ends the activation.
    case dropped

    /// The chip refused, with the exact bytes the caller states.
    ///
    /// There is no default refusal byte, because inventing a refusal code is the
    /// same fiction as inventing an answer: SLIX2 answers the generic `0F` to
    /// every refusal, and a simulator that emitted the specific ISO codes kept a
    /// wrong verdict green in CI for two campaigns.
    ///
    /// `halts: true` follows the refusal with the chip's own `HALT` frame, which
    /// is how a Type-2 NAK ends the activation. That arm is delivered through
    /// the wrapped chip rather than by reaching into the simulator, so it is the
    /// simulator's own halt modelling that takes effect and no simulator needs
    /// to change.
    case refused(response: Data, halts: Bool)

    /// **The tag physically left, on this frame, and is gone from every entry
    /// point afterwards.**
    ///
    /// The distinction from `dropped` is what happens to the frames behind it.
    /// A dropped frame is one the chip never heard and it is still sitting
    /// there, so a presence probe answers. This one models the tag being taken
    /// away mid-activation, so the probe that runs next finds silence.
    ///
    /// Not expressible before, and the reason given was sound for the case it
    /// was written about: absence that begins at a `transceive` would let an
    /// earlier `readMemory` answer for a tag that was supposed to be gone from
    /// the start. That is `tagLeavesTheField()`, and it stays the right tool for
    /// a tag absent before the flow began. This is the other shape, where the
    /// earlier reads answering is the *point*, because the tag really was there
    /// for them.
    ///
    /// Captured on an NTAG213 on 2026-09-22: `PWD_AUTH` returned its PACK, the
    /// next `READ p41` came back "Tag connection lost", and every frame after it
    /// was silence. The app read that silence as a refusal and told the owner
    /// the password it had just accepted was wrong.
    case leavesTheField
}

public extension TagFaultEffect {
    /// The one refusal shape this repo has a model for: a single `00` byte, and
    /// the chip returns to HALT for the rest of the activation
    /// (ISO/IEC 14443-3; `NTAG21xSimulator.nak()` and
    /// `MifareUltralightCSimulator`'s equivalent both model it).
    ///
    /// Type-4 and Type-5 have no NAK, so they get no convenience here and must
    /// state the bytes a captured trace actually showed.
    static let type2NAK = TagFaultEffect.refused(response: Data([0x00]), halts: true)
}

/// One armed fault: which frames, what happens, and on which occurrence.
public struct TagFault: Sendable {
    public let matcher: FrameMatcher
    public let effect: TagFaultEffect
    public let occurrence: FrameOccurrence

    public init(
        _ matcher: FrameMatcher,
        _ effect: TagFaultEffect,
        on occurrence: FrameOccurrence = .first
    ) {
        self.matcher = matcher
        self.effect = effect
        self.occurrence = occurrence
    }
}

// MARK: - The log

/// One frame that crossed the seam.
///
/// `request`, `response` and `hiddenResponse` hold raw bytes, which on a
/// credential frame *are* the credential. Never interpolate them into a message;
/// `redactedDescription` is the printable form.
public struct TagFaultFrame: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        /// Forwarded to the chip untouched. `response` is `nil` when the chip
        /// itself failed to answer.
        case delivered
        /// Forwarded and applied by the chip; the answer was hidden from the
        /// caller and kept in `hiddenResponse`.
        case lostACK
        /// Never reached the chip.
        case dropped
        /// Answered with the caller's stated refusal bytes; the chip never saw
        /// the frame.
        case refused
        /// The seam's own frame, not the caller's. Today the only one is the
        /// `HALT` that carries out a refusal's end-of-activation. Kept out of
        /// `TagFaultReport.frames` so "what the driver sent" stays exactly that.
        case synthetic(String)
    }

    public let request: Data
    /// What the caller saw. `nil` whenever no answer reached it.
    public let response: Data?
    /// What the chip answered when the seam forwarded the frame and then hid the
    /// reply. The lost-ACK oracle; `nil` for every other outcome.
    public let hiddenResponse: Data?
    /// `RawCommand.name`, when the caller gave one.
    public let name: String?
    /// Which activation this frame belongs to, 1-based.
    public let tap: Int
    public let outcome: Outcome

    /// Opcode, then the parameter byte, then `..` for everything else.
    ///
    /// The parameter byte is a page number or an instruction byte on every frame
    /// this repo sends except the two that carry credential material there:
    /// Type-2 `PWD_AUTH` (`1B <pwd>`) and the Ultralight C handshake
    /// continuation (`AF <cryptogram>`). Those print the opcode alone. Same rule
    /// `CoreNFCSession.isSecretFrame` applies to the live trace, and the reason
    /// is the same: this string ends up in a failure message someone pastes into
    /// a bug report.
    public var redactedDescription: String {
        let bytes = [UInt8](request)
        guard let opcode = bytes.first else { return "<empty frame>" }
        let parameterIsSecret = (opcode == 0x1B || opcode == 0xAF)
        var text = String(format: "%02X", opcode)
        if !parameterIsSecret, bytes.count > 1 {
            text += String(format: " %02X", bytes[1])
        }
        if bytes.count > (parameterIsSecret ? 1 : 2) {
            text += " .."
        }
        return text
    }
}

/// The redacted form is also the *default* form, so an interpolation written by
/// someone who has not read the note above still cannot print a credential. A
/// documented rule that a `\(frame)` quietly breaks is not a rule.
extension TagFaultFrame: CustomStringConvertible {
    public var description: String {
        "\(redactedDescription) [\(outcome)] tap \(tap)"
    }
}

/// Everything the seam saw, and what it did about it.
public struct TagFaultReport: Sendable {
    /// The caller's frames, in order. Excludes the seam's own synthetic frames,
    /// so an anti-drift assertion reads only what the driver actually sent.
    public let frames: [TagFaultFrame]
    /// Every frame including the synthetic ones.
    public let allFrames: [TagFaultFrame]
    /// Activations opened so far.
    public let taps: Int
    /// Whether any armed fault has fired.
    public let didFire: Bool

    public func frames(matching matcher: FrameMatcher) -> [TagFaultFrame] {
        frames.filter { matcher.matches($0.request) }
    }

    public func contains(_ matcher: FrameMatcher) -> Bool {
        frames.contains { matcher.matches($0.request) }
    }

    public func lastIndex(of matcher: FrameMatcher) -> Int? {
        frames.lastIndex { matcher.matches($0.request) }
    }

    public func frames(inTap tap: Int) -> [TagFaultFrame] {
        frames.filter { $0.tap == tap }
    }

    /// Frames the chip applied and whose answer the seam threw away.
    ///
    /// The lost-ACK oracle. A test asserts on this rather than inferring from a
    /// higher-level result that the write must have landed.
    public var swallowed: [TagFaultFrame] {
        frames.filter { $0.outcome == .lostACK }
    }

    /// The outcome of each caller frame, in order. The compact form for
    /// asserting *which* occurrence a fault fired on.
    public var outcomes: [TagFaultFrame.Outcome] {
        frames.map(\.outcome)
    }
}

// MARK: - Shared state

/// The armed faults, their counters, the frame log and the absence latch, shared
/// by the factory and by every session and tag it vends.
///
/// One `NSLock` around the lot, matching the `@unchecked Sendable` pattern
/// `SimulatedSession` already uses.
final class TagFaultState: @unchecked Sendable {
    private let lock = NSLock()
    private var faults: [TagFault] = []
    private var matchCounts: [Int] = []
    private var log: [TagFaultFrame] = []
    private var absent = false
    private var taps = 0
    private var fired = false

    func arm(_ newFaults: [TagFault]) {
        lock.withLock {
            faults.append(contentsOf: newFaults)
            matchCounts.append(contentsOf: Array(repeating: 0, count: newFaults.count))
        }
    }

    func disarm() {
        lock.withLock {
            faults.removeAll()
            matchCounts.removeAll()
        }
    }

    func setAbsent(_ isAbsent: Bool) {
        lock.withLock { absent = isAbsent }
    }

    var isAbsent: Bool {
        lock.withLock { absent }
    }

    func beginTap() -> Int {
        lock.withLock {
            taps += 1
            return taps
        }
    }

    var currentTap: Int {
        lock.withLock { taps }
    }

    /// The effect due for this frame, and the name of the matcher that chose it.
    ///
    /// Faults are tried in arming order. Each one whose matcher matches has its
    /// counter advanced until one is due; that one fires, and the faults after it
    /// are not counted for this frame. Counting the matches rather than the fires
    /// is what makes `.nth` mean what it says, and the early return is why, on a
    /// shared matcher, a later occurrence has to be armed before an earlier one.
    func effect(for frame: Data) -> (effect: TagFaultEffect, matcher: String)? {
        lock.withLock {
            for index in faults.indices where faults[index].matcher.matches(frame) {
                matchCounts[index] += 1
                guard faults[index].occurrence.isDue(atMatch: matchCounts[index]) else { continue }
                fired = true
                return (faults[index].effect, faults[index].matcher.name)
            }
            return nil
        }
    }

    func record(_ frame: TagFaultFrame) {
        lock.withLock { log.append(frame) }
    }

    func resetLog() {
        lock.withLock { log.removeAll() }
    }

    var report: TagFaultReport {
        lock.withLock {
            TagFaultReport(
                frames: log.filter {
                    if case .synthetic = $0.outcome {
                        return false
                    }
                    return true
                },
                allFrames: log,
                taps: taps,
                didFire: fired
            )
        }
    }
}

// MARK: - Driver

/// Vends sessions over the **same** chip, so state carries across taps exactly
/// as it does on one physical tag, and records every frame either side of the
/// seam.
///
/// It is a `TagSessionFactory`, so it drops straight into `WriteFlowModel`,
/// `ScanFlowModel` and anything else that takes one.
public final class FaultInjectingSessionFactory: TagSessionFactory, @unchecked Sendable {
    public let chip: ChipSimulator
    private let state = TagFaultState()

    public init(chip: ChipSimulator) {
        self.chip = chip
    }

    /// Arm one or more faults. They are tried in the order they were armed.
    public func arm(_ faults: TagFault...) {
        state.arm(faults)
    }

    /// Forget every armed fault. The frame log is kept.
    public func disarm() {
        state.disarm()
    }

    /// **The tag is gone, from now on, from every entry point.**
    ///
    /// Not a frame fault, and deliberately not expressible as one. `readMemory`,
    /// `readNDEF` and `writeNDEF` reach the chip without putting a frame on the
    /// wire, so a tag whose absence only began at the next `transceive` would
    /// still answer the safe pre-read that both flows take first, and the flow
    /// would have already concluded the tag was present. That inversion is
    /// exactly the 2026-08-14 bug: an absent tag reported as a protected one.
    ///
    /// Identification is unaffected: `uid`, `chip` and `capabilities` still
    /// answer, which is the tag that identified and was then lifted off the
    /// phone.
    public func tagLeavesTheField() {
        state.setAbsent(true)
    }

    /// The tag is back. For a test that needs it to answer again on a later tap.
    public func tagReturnsToTheField() {
        state.setAbsent(false)
    }

    /// Drop the recorded frames, keeping the armed faults and their counters.
    public func resetLog() {
        state.resetLog()
    }

    public var report: TagFaultReport {
        state.report
    }

    /// Activations opened so far, i.e. taps.
    public var tapCount: Int {
        state.currentTap
    }

    public func makeSession() -> TagSession {
        FaultInjectingSession(inner: SimulatedSession(chip: chip), state: state)
    }
}

/// Wraps a `SimulatedSession` so the tag it vends carries the seam.
public final class FaultInjectingSession: TagSession, @unchecked Sendable {
    private let inner: SimulatedSession
    private let state: TagFaultState

    init(inner: SimulatedSession, state: TagFaultState) {
        self.inner = inner
        self.state = state
    }

    public func start(alert: String) async throws -> ConnectedTag {
        _ = state.beginTap()
        let tag = try await inner.start(alert: alert)
        return FaultInjectingTag(inner: tag, state: state)
    }

    public func updateAlert(_ alert: String) async {
        await inner.updateAlert(alert)
    }

    public func invalidate(error: String?) async {
        await inner.invalidate(error: error)
    }
}

/// Overrides `transceive` and forwards everything else.
///
/// **It must declare nothing beyond what is listed below.** `enableProtection`,
/// `disableProtection`, `authenticate`, `permanentLock`, `readProtectionState`,
/// `enablePasswordProtection`, `disablePasswordProtection`, `setPassword` and
/// `transceive(sequence:)` are all `ConnectedTag` extension defaults that build
/// their driver from `self.transceive`. Declaring any of them here would point
/// that driver at the inner tag and silently bypass every armed fault, which is
/// the same class of bug the seam exists to catch. `FaultInjectionTests`
/// asserts each of them still puts frames in the log.
///
/// The three session holders are forwarded rather than left to their extension
/// defaults for the mirror reason: the defaults hand back a fresh throwaway on
/// every access, so a decorator taking them would forget an Ultralight C
/// handshake the wrapped tag remembers, and would be a more permissive tag than
/// the one it wraps.
public final class FaultInjectingTag: ConnectedTag, @unchecked Sendable {
    private let inner: ConnectedTag
    private let state: TagFaultState

    /// The `HALT` that carries out a refusal's end-of-activation, sent through
    /// the chip so its own halt modelling is what takes effect.
    private static let haltCommand: UInt8 = 0x50

    init(inner: ConnectedTag, state: TagFaultState) {
        self.inner = inner
        self.state = state
    }

    // MARK: Forwarded

    public var uid: Data {
        inner.uid
    }

    public var chip: ChipProfile? {
        inner.chip
    }

    public var capabilities: TagCapability {
        inner.capabilities
    }

    public var unidentifiedReport: UnidentifiedChipReport? {
        inner.unidentifiedReport
    }

    public var ev2Session: EV2SessionHolder {
        inner.ev2Session
    }

    public var ultralightCSession: UltralightCSessionHolder {
        inner.ultralightCSession
    }

    public var type2Session: Type2SessionHolder {
        inner.type2Session
    }

    public func readNDEF() async throws -> Data {
        try requirePresence()
        return try await inner.readNDEF()
    }

    public func writeNDEF(_ records: [NDEFRecord]) async throws {
        try requirePresence()
        try await inner.writeNDEF(records)
    }

    public func readMemory(range: Range<Int>) async throws -> Data {
        try requirePresence()
        return try await inner.readMemory(range: range)
    }

    public func writeMemory(at offset: Int, bytes: Data) async throws {
        try requirePresence()
        try await inner.writeMemory(at: offset, bytes: bytes)
    }

    // MARK: The seam

    public func transceive(_ command: RawCommand) async throws -> Data {
        try requirePresence()
        guard let (effect, matcher) = state.effect(for: command.bytes) else {
            return try await deliver(command)
        }
        switch effect {
        case .lostACK:
            // Forward FIRST, so the chip really applies the frame, and only then
            // throw the answer away. This is the whole point of the effect: the
            // tag's state moves and the caller is told nothing happened.
            let hidden = try? await inner.transceive(command)
            let frame = record(command, response: nil, hidden: hidden, outcome: .lostACK)
            throw TagError.tagLost(
                diagnostics: "injected lost ACK on \(matcher): the chip applied "
                    + "\(frame.redactedDescription) and the answer was discarded"
            )

        case .dropped:
            let frame = record(command, response: nil, hidden: nil, outcome: .dropped)
            throw TagError.tagLost(
                diagnostics: "injected dropped frame on \(matcher): "
                    + "\(frame.redactedDescription) never reached the chip"
            )

        case .refused(let response, let halts):
            record(command, response: response, hidden: nil, outcome: .refused)
            if halts {
                await haltAfterRefusal(matcher: matcher)
            }
            return response

        case .leavesTheField:
            let frame = record(command, response: nil, hidden: nil, outcome: .dropped)
            state.setAbsent(true)
            throw TagError.tagLost(
                diagnostics: "injected departure on \(matcher): "
                    + "\(frame.redactedDescription) went out as the tag left the field"
            )
        }
    }

    // MARK: Plumbing

    /// Forward untouched, recording either the answer or the fact that none came.
    private func deliver(_ command: RawCommand) async throws -> Data {
        do {
            let response = try await inner.transceive(command)
            record(command, response: response, hidden: nil, outcome: .delivered)
            return response
        } catch {
            record(command, response: nil, hidden: nil, outcome: .delivered)
            throw error
        }
    }

    /// A refusal that ends the activation, delivered as the chip's own `HALT`.
    ///
    /// Gated on Type-2 because that is the only family whose refusal is known to
    /// return the chip to HALT. Type-4 answers a status word and Type-5 answers
    /// an error byte or nothing at all, and neither has been seen ending the
    /// activation, so the seam refuses to invent one for them.
    private func haltAfterRefusal(matcher: String) async {
        guard case .type2? = inner.chip?.family else {
            preconditionFailure(
                "refused(halts: true) on \(inner.chip?.family.shortName ?? "an unidentified chip"): "
                    + "only Type-2 is known to return to HALT on a refusal. "
                    + "Arm refused(response:halts: false) and state what the trace showed."
            )
        }
        let halt = RawCommand(bytes: Data([Self.haltCommand]), name: "HALT (injected refusal aftermath)")
        _ = try? await inner.transceive(halt)
        record(halt, response: nil, hidden: nil, outcome: .synthetic("refusal aftermath for \(matcher)"))
    }

    @discardableResult
    private func record(
        _ command: RawCommand,
        response: Data?,
        hidden: Data?,
        outcome: TagFaultFrame.Outcome
    ) -> TagFaultFrame {
        let frame = TagFaultFrame(
            request: command.bytes,
            response: response,
            hiddenResponse: hidden,
            name: command.name,
            tap: state.currentTap,
            outcome: outcome
        )
        state.record(frame)
        return frame
    }

    private func requirePresence() throws {
        guard state.isAbsent else { return }
        throw TagError.tagLost(diagnostics: "injected: the tag left the field")
    }
}
