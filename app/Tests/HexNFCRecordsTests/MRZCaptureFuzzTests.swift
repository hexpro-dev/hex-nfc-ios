@testable import HexNFCRecords
import XCTest

/// Seeded fuzzing of camera capture: random valid zones (TD3, TD2, TD1),
/// corrupted the way text recognition goes wrong, fed frame by frame through
/// `MRZLineReader` and `MRZScanConsensus`.
///
/// Every trial ends one of four ways: the lock is the true key, the lock is
/// wrong but carries the true key as an alternate (the chip refuses the first
/// and the prompt offers the next), the lock is wrong with no way back, or
/// nothing locked. The third is the one that matters. It is allowed only
/// where ICAO check digits are provably blind, and only at a measured rate.
final class MRZCaptureFuzzTests: XCTestCase {
    // MARK: - Independent noise

    /// Every frame is corrupted afresh, as a moving hand and a refocusing lens
    /// do. No wrong lock is acceptable here: errors that differ frame to frame
    /// must be voted out.
    func test_independentNoise_neverLocksWrong_andLocksFast() {
        var rng = SplitMix64(seed: 0x4D52_5A31)
        var tally = Tally()
        for _ in 0 ..< 600 {
            let document = FuzzDocument.random(&rng)
            tally.record(run(document, frames: 12, rng: &rng) { line, rng in
                corrupt(line, times: rng.pick([0, 0, 1, 1, 1, 2]), rng: &rng)
            })
        }
        XCTAssertEqual(tally.wrong, 0, tally.summary)
        XCTAssertGreaterThanOrEqual(tally.lockedRightOrRescued, 0.97, tally.summary)
        XCTAssertLessThanOrEqual(tally.medianFramesToLock, 3, tally.summary)
    }

    // MARK: - The same misread every frame

    /// One misread repeated in every frame, with light independent noise on
    /// top, and the recogniser sometimes offering the truth as its second
    /// guess (`topCandidates`). The repeated misread is the hard case: voting
    /// cannot outvote it, so a wrong lock is caught only by a check digit or
    /// rescued by an alternate.
    func test_repeatedSingleMisread_isRefusedOrRescued() {
        var rng = SplitMix64(seed: 0x4D52_5A32)
        var tally = Tally()
        for _ in 0 ..< 600 {
            let document = FuzzDocument.random(&rng)
            let misread = keyRegionMisreads(document, count: 1, rng: &rng)
            tally.record(run(document, frames: 12, truthAsSecondCandidate: 0.3, rng: &rng) { line, rng in
                corrupt(misread(line), times: rng.pick([0, 0, 0, 1]), rng: &rng)
            })
        }
        XCTAssertEqual(tally.wrong, 0, tally.summary)
    }

    /// The same, with nothing ever pointing at the truth. Wrong locks are now
    /// possible, and every one of them must sit in the blind spot the
    /// consensus documents: the document number, at a character congruent mod
    /// 10 to the true one.
    func test_repeatedSingleMisreadWithNoEvidence_failsOnlyInTheBlindSpot() {
        var rng = SplitMix64(seed: 0x4D52_5A33)
        var tally = Tally()
        for _ in 0 ..< 600 {
            let document = FuzzDocument.random(&rng)
            let misread = keyRegionMisreads(document, count: 1, rng: &rng)
            let outcome = run(document, frames: 12, rng: &rng) { line, _ in misread(line) }
            tally.record(outcome)
            if case .wrong(let key) = outcome {
                XCTAssertTrue(
                    differsOnlyInBlindSpot(key, document.truth),
                    "\(key.documentNumber) vs \(document.truth.documentNumber)"
                )
            }
        }
        // Measured 3 of 600 when written (361 right, 70 rescued, 166 refused):
        // numbers so dense in look-alikes that the three alternates run out.
        // The ceiling is room for a change in the generator, not for a
        // regression.
        XCTAssertLessThanOrEqual(tally.wrong, 6, tally.summary)
    }

    /// Two misreads repeated in every frame. A pair that happens to cancel in
    /// a check digit is invisible to ICAO's scheme (one in ten pairs inside
    /// the same field), so this is a ceiling, not a zero.
    func test_repeatedDoubleMisread_wrongLocksStayRare() {
        var rng = SplitMix64(seed: 0x4D52_5A34)
        var tally = Tally()
        for _ in 0 ..< 600 {
            let document = FuzzDocument.random(&rng)
            let misread = keyRegionMisreads(document, count: 2, rng: &rng)
            tally.record(run(document, frames: 12, truthAsSecondCandidate: 0.3, rng: &rng) { line, rng in
                corrupt(misread(line), times: rng.pick([0, 0, 0, 1]), rng: &rng)
            })
        }
        // Measured 14 of 600 when written (260 right, 93 rescued, 233
        // refused). Every one is two congruent swaps in one number, which a
        // single-swap alternate cannot undo and no check digit can see.
        XCTAssertLessThanOrEqual(tally.wrong, 20, tally.summary)
    }

    // MARK: - Driving the pipeline

    private enum Outcome {
        case right(frames: Int)
        case rescued(frames: Int)
        case wrong(PassportMRZ)
        case none
    }

    private struct Tally {
        var right = 0
        var rescued = 0
        var wrong = 0
        var none = 0
        var framesToLock: [Int] = []

        mutating func record(_ outcome: Outcome) {
            switch outcome {
            case .right(let frames):
                right += 1
                framesToLock.append(frames)
            case .rescued(let frames):
                rescued += 1
                framesToLock.append(frames)
            case .wrong:
                wrong += 1
            case .none:
                none += 1
            }
        }

        var total: Int { right + rescued + wrong + none }
        var lockedRightOrRescued: Double { Double(right + rescued) / Double(max(total, 1)) }
        var medianFramesToLock: Int {
            let sorted = framesToLock.sorted()
            return sorted.isEmpty ? .max : sorted[sorted.count / 2]
        }

        var summary: String {
            "right \(right), rescued \(rescued), wrong \(wrong), none \(none), median frames \(medianFramesToLock)"
        }
    }

    /// Feed up to `frames` frames, 0.1 s apart, each line passed through
    /// `damage`, until the consensus locks.
    private func run(
        _ document: FuzzDocument,
        frames: Int,
        truthAsSecondCandidate: Double = 0,
        rng: inout SplitMix64,
        damage: (String, inout SplitMix64) -> String
    ) -> Outcome {
        var consensus = MRZScanConsensus()
        for frame in 1 ... frames {
            var observations: [MRZTextObservation] = []
            let lines = ["PASSPORT", "Surname / Nom"] + document.lines
            for (index, line) in lines.enumerated() {
                let damaged = damage(line, &rng)
                var candidates = [damaged]
                if damaged != line, rng.chance(truthAsSecondCandidate) {
                    candidates.append(line)
                }
                observations += observe(candidates, line: index, rng: &rng)
            }
            let readings = MRZLineReader.readings(from: observations)
            guard let lock = consensus.add(readings, at: Double(frame) * 0.1) else { continue }
            if lock.key == document.truth { return .right(frames: frame) }
            if lock.alternates.contains(document.truth) { return .rescued(frames: frame) }
            return .wrong(lock.key)
        }
        return .none
    }

    /// One visual line as the recogniser reports it, sometimes split in two at
    /// a filler run.
    private func observe(_ candidates: [String], line: Int, rng: inout SplitMix64) -> [MRZTextObservation] {
        let top = 0.95 - Double(line) * 0.1
        let primary = candidates[0]
        if rng.chance(0.15), let cut = primary.range(of: "<<<")?.lowerBound, cut != primary.startIndex {
            let left = String(primary[..<cut])
            let right = String(primary[cut...])
            return [
                MRZTextObservation(candidates: [left], minX: 0.02, minY: top - 0.08, maxX: 0.6, maxY: top),
                MRZTextObservation(candidates: [right], minX: 0.62, minY: top - 0.075, maxX: 0.98, maxY: top + 0.005),
            ]
        }
        return [MRZTextObservation(candidates: candidates, minX: 0.02, minY: top - 0.08, maxX: 0.98, maxY: top)]
    }

    // MARK: - Corruption

    /// Visual confusions text recognition makes on OCR-B.
    private static let confusions: [Character: [Character]] = [
        "0": ["O", "D", "Q"], "O": ["0"], "D": ["0"], "1": ["I", "L"], "I": ["1"], "L": ["1"],
        "2": ["Z"], "Z": ["2"], "5": ["S"], "S": ["5", "8"], "6": ["G"], "G": ["6"],
        "8": ["B", "S"], "B": ["8"], "<": ["K"], "C": ["G"], "U": ["V"], "E": ["F"], "M": ["N"],
    ]

    /// Apply `times` random corruptions: a confusion, filler dropped or added,
    /// `<<` read as `«`, or a stray glyph at the start of the line.
    private func corrupt(_ line: String, times: Int, rng: inout SplitMix64) -> String {
        var chars = Array(line)
        for _ in 0 ..< times where !chars.isEmpty {
            switch rng.int(0 ..< 10) {
            case 0 ..< 6:
                let index = rng.int(0 ..< chars.count)
                if let options = Self.confusions[chars[index]] {
                    chars[index] = rng.pick(options)
                }
            case 6:
                if let run = fillerRun(chars, rng: &rng) { chars.remove(at: run) }
            case 7:
                if let run = fillerRun(chars, rng: &rng) { chars.insert("<", at: run) }
            case 8:
                if let run = fillerRun(chars, rng: &rng), run + 1 < chars.count, chars[run + 1] == "<" {
                    chars.replaceSubrange(run ... run + 1, with: ["«"])
                }
            default:
                if chars.count > 20 { chars.insert(rng.pick(["1", "I", ".", "|"] as [Character]), at: 0) }
            }
        }
        return String(chars)
    }

    /// An index inside a run of at least three `<`.
    private func fillerRun(_ chars: [Character], rng: inout SplitMix64) -> Int? {
        let starts = chars.indices.filter { index in
            index + 2 < chars.count && chars[index] == "<" && chars[index + 1] == "<" && chars[index + 2] == "<"
        }
        guard !starts.isEmpty else { return nil }
        return rng.pick(starts) + 1
    }

    /// A fixed set of confusions inside the key fields of the line that carries
    /// them, returned as a function so the same misread lands in every frame.
    private func keyRegionMisreads(
        _ document: FuzzDocument,
        count: Int,
        rng: inout SplitMix64
    ) -> (String) -> String {
        var edits: [(line: Int, index: Int, character: Character)] = []
        for _ in 0 ..< 20 where edits.count < count {
            let (line, index) = rng.pick(document.keyPositions)
            let original = Array(document.lines[line])[index]
            guard let options = Self.confusions[original],
                  !edits.contains(where: { $0.line == line && $0.index == index }) else { continue }
            edits.append((line, index, rng.pick(options)))
        }
        let lines = document.lines
        return { line in
            guard let number = lines.firstIndex(of: line) else { return line }
            var chars = Array(line)
            for edit in edits where edit.line == number {
                chars[edit.index] = edit.character
            }
            return String(chars)
        }
    }

    private func differsOnlyInBlindSpot(_ lock: PassportMRZ, _ truth: PassportMRZ) -> Bool {
        guard lock.dateOfBirth == truth.dateOfBirth, lock.dateOfExpiry == truth.dateOfExpiry else { return false }
        return zip(lock.documentNumberField, truth.documentNumberField).allSatisfy { read, real in
            read == real || MRZScanConsensus.congruentLookAlikes[real] == read
        }
    }
}

// MARK: - Documents

/// A random, valid machine-readable zone with its true access key.
private struct FuzzDocument {
    var lines: [String]
    var truth: PassportMRZ
    /// (line, index) of every key character: the number, the dates and their
    /// check digits.
    var keyPositions: [(Int, Int)]

    static func random(_ rng: inout SplitMix64) -> FuzzDocument {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = Array("0123456789")
        let numberLength = rng.chance(0.3) ? 8 : 9
        var number = String(rng.pick(letters))
        for _ in 1 ..< numberLength {
            number.append(rng.chance(0.7) ? rng.pick(digits) : rng.pick(letters))
        }
        let field = number.padding(toLength: 9, withPad: "<", startingAt: 0)
        let birth = rng.chance(0.03) ? String(date(&rng, years: 0 ..< 100).prefix(4)) + "<<" : date(&rng, years: 0 ..< 100)
        let expiry = date(&rng, years: 24 ..< 37)
        let sex = rng.pick(["M", "F", "<", "X"])
        let state = rng.pick(["UTO", "AUS", "NPL", "CAN", "D<<", "GBR"])
        let name = rng.pick(["ERIKSSON<<ANNA<MARIA", "OKAFOR<<DANIEL<CHIDI", "TANAKA<<HARUTO", "MORENO<GARCIA<<LUCIA"])
        let truth = PassportMRZ(documentNumber: number, dateOfBirth: birth, dateOfExpiry: expiry)
        let check = { (text: String) in String(PassportMRZ.checkDigit(text)) }
        let datePart = birth + check(birth) + sex + expiry + check(expiry)

        switch rng.int(0 ..< 10) {
        case 0 ..< 7:
            let optional = optionalData(&rng, length: 14)
            let optionalCheck = optional.allSatisfy { $0 == "<" } ? "<" : check(optional)
            let head = field + check(field) + state + datePart
            let composite = check(String(head.prefix(10)) + slice(head, 13 ..< 20) + slice(head, 21 ..< 28)
                + optional + optionalCheck)
            let line1 = pad("P<" + state + name, to: 44)
            return FuzzDocument(
                lines: [line1, head + optional + optionalCheck + composite],
                truth: truth,
                keyPositions: twoLineKeyPositions(line: 1)
            )

        case 7:
            let optional = optionalData(&rng, length: 7)
            let head = field + check(field) + state + datePart
            let composite = check(String(head.prefix(10)) + slice(head, 13 ..< 20) + slice(head, 21 ..< 28) + optional)
            return FuzzDocument(
                lines: [pad("I<" + state + name, to: 36), head + optional + composite],
                truth: truth,
                keyPositions: twoLineKeyPositions(line: 1)
            )

        default:
            let optional1 = optionalData(&rng, length: 15)
            let optional2 = optionalData(&rng, length: 11)
            let line1 = "I<" + state + field + check(field) + optional1
            let head2 = datePart + state
            let composite = check(slice(line1, 5 ..< 30) + slice(head2, 0 ..< 7) + slice(head2, 8 ..< 15) + optional2)
            let keyPositions = (5 ..< 15).map { (0, $0) } + ((0 ..< 7).map { (1, $0) }) + ((8 ..< 15).map { (1, $0) })
            return FuzzDocument(
                lines: [line1, head2 + optional2 + composite, pad(name, to: 30)],
                truth: truth,
                keyPositions: keyPositions
            )
        }
    }

    private static func twoLineKeyPositions(line: Int) -> [(Int, Int)] {
        MRZKeySlots.keyPositions.map { (line, $0) }
    }

    private static func date(_ rng: inout SplitMix64, years: Range<Int>) -> String {
        let month = rng.int(1 ..< 13)
        let day = rng.int(1 ..< 29)
        return String(format: "%02d%02d%02d", rng.int(years), month, day)
    }

    /// Mostly filler, sometimes a personal number left-aligned in it.
    private static func optionalData(_ rng: inout SplitMix64, length: Int) -> String {
        guard rng.chance(0.4) else { return String(repeating: "<", count: length) }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let content = String((0 ..< rng.int(1 ..< length)).map { _ in rng.pick(alphabet) })
        return pad(content, to: length)
    }

    private static func pad(_ text: String, to length: Int) -> String {
        String(text.prefix(length)).padding(toLength: length, withPad: "<", startingAt: 0)
    }

    private static func slice(_ text: String, _ range: Range<Int>) -> String {
        String(Array(text)[range])
    }
}

// MARK: - Seeded randomness

/// SplitMix64: small, fast, and the same sequence on every machine, so a
/// failure reproduces from its seed.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double(next() >> 11) / Double(1 << 53) < probability
    }

    mutating func pick<T>(_ options: [T]) -> T {
        options[int(0 ..< options.count)]
    }
}
