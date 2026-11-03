import Foundation

/// Decides when the camera has read an access key well enough to lock it in.
///
/// Feed it every frame's `MRZLineReader` readings. It keeps a short window of
/// them and votes position by position, so frames that each got a different
/// character wrong still add up to the right key. It locks when either:
///
/// - at least two frames read exactly the voted key and one of them also
///   passed the composite check digit, or three frames read it exactly; or
/// - the vote alone is decisive: four or more frames, and at every key
///   position the winning character has at least 2.5 votes and three times
///   the runner-up's.
///
/// A competing key that also passes its checks holds the lock off until the
/// leader has three times its frames, and is then carried as an alternate.
///
/// **What no check digit can catch.** ICAO check digits weight 7, 3, 1 and
/// reduce mod 10, so characters whose values are congruent mod 10 are
/// interchangeable to every check, the composite included. Five such pairs
/// also look alike: `<`/`K`, `G`/`6`, `S`/`8`, `L`/`1`, `U`/`0`. In a digit-only
/// position the reader already resolves them. In the document number it
/// cannot, so the lock carries up to three alternates for those positions and
/// the chip, which accepts only the right key, decides. The case that matters
/// most is the filler after an eight-character number read as `K`.
public struct MRZScanConsensus: Sendable {
    /// A key the consensus trusts, with what else it might have been.
    public struct Lock: Sendable, Equatable {
        public var key: PassportMRZ
        /// Other keys that pass every check and that the frames gave some
        /// support to, most likely first. At most three.
        public var alternates: [PassportMRZ]
        public var layout: MRZLayout
    }

    /// How far back readings count, in seconds. Time rather than a frame count,
    /// so a slower phone gets the same chance to agree with itself.
    public let window: TimeInterval
    private var entries: [Entry] = []

    private struct Entry {
        var time: TimeInterval
        var reading: MRZReading
    }

    public init(window: TimeInterval = 1.5) {
        self.window = window
    }

    /// Weight of a reading from the recogniser's second or third guess.
    static let alternateWeight = 0.3

    /// Pairs that look alike and pass every check digit for each other.
    static let congruentLookAlikes: [Character: Character] = [
        "<": "K", "K": "<", "G": "6", "6": "G", "S": "8", "8": "S",
        "L": "1", "1": "L", "U": "0", "0": "U",
    ]

    public mutating func reset() {
        entries.removeAll()
    }

    /// Whether zone-shaped text was seen recently: the cue to tell the holder
    /// to keep still rather than to find the lines.
    public func isTracking(at time: TimeInterval) -> Bool {
        entries.contains { time - $0.time <= 0.6 }
    }

    /// Add one frame's readings, taken at `time` (seconds, any monotonic
    /// clock). Returns a lock once the frames support one.
    public mutating func add(_ readings: [MRZReading], at time: TimeInterval) -> Lock? {
        entries += readings.map { Entry(time: time, reading: $0) }
        entries.removeAll { time - $0.time > window }

        // TD3 and TD2 share their key positions, so they vote together; a TD1
        // card is a different document and never mixes with them.
        let twoLine = entries.filter { $0.reading.layout != .td1 }
        let card = entries.filter { $0.reading.layout == .td1 }
        let pool = twoLine.count >= card.count ? twoLine : card
        guard !pool.isEmpty else { return nil }

        let votes = tally(pool)
        let voted = votes.map(\.winner)
        guard let key = MRZKeySlots.key(from: voted) else { return nil }

        let keyOf: ([Character]) -> [Character] = { slots in MRZKeySlots.keyPositions.map { slots[$0] } }
        let votedKey = keyOf(voted)
        let primaries = pool.filter(\.reading.isPrimary)
        let exact = primaries.filter { keyOf($0.reading.slots) == votedKey }
        let exactFrames = Set(exact.map(\.time)).count
        let compositeFrames = Set(exact.filter { $0.reading.compositeValid == true }.map(\.time)).count

        // Every other key the frames read that also passes its checks.
        var rivals: [[Character]: (key: PassportMRZ, frames: Set<TimeInterval>)] = [:]
        for entry in primaries {
            let rivalKey = keyOf(entry.reading.slots)
            guard rivalKey != votedKey, let valid = MRZKeySlots.key(from: entry.reading.slots) else { continue }
            rivals[rivalKey, default: (valid, [])].frames.insert(entry.time)
        }
        let strongestRival = rivals.values.map(\.frames.count).max() ?? 0
        guard exactFrames >= 3 * strongestRival else { return nil }

        let byExactFrames = (exactFrames >= 2 && compositeFrames >= 1) || exactFrames >= 3
        let primaryFrames = Set(primaries.map(\.time)).count
        let byVote = primaryFrames >= 4 && MRZKeySlots.keyPositions.allSatisfy { position in
            votes[position].winnerWeight >= 2.5 && votes[position].winnerWeight >= 3 * votes[position].runnerUpWeight
        }
        guard byExactFrames || byVote else { return nil }

        let layout = majorityLayout(exact.isEmpty ? pool : exact)
        let ranked = rivals.values.sorted { $0.frames.count > $1.frames.count }.map(\.key)
        return Lock(key: key, alternates: alternates(to: voted, votes: votes, rivals: ranked), layout: layout)
    }

    // MARK: - Voting

    struct PositionVote {
        var winner: Character
        var winnerWeight: Double
        var runnerUpWeight: Double
        var weights: [Character: Double]
    }

    private func tally(_ pool: [Entry]) -> [PositionVote] {
        // Ties go to the most recent primary reading, which the camera has had
        // the longest to focus for.
        let latest = pool.last(where: \.reading.isPrimary)?.reading.slots ?? pool[pool.count - 1].reading.slots
        return (0 ..< MRZKeySlots.count).map { position in
            var weights: [Character: Double] = [:]
            for entry in pool {
                weights[entry.reading.slots[position], default: 0] += entry.reading.isPrimary ? 1 : Self.alternateWeight
            }
            let ranked = weights.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key == latest[position]
            }
            return PositionVote(
                winner: ranked[0].key,
                winnerWeight: ranked[0].value,
                runnerUpWeight: ranked.count > 1 ? ranked[1].value : 0,
                weights: weights
            )
        }
    }

    private func majorityLayout(_ entries: [Entry]) -> MRZLayout {
        var counts: [MRZLayout: Int] = [:]
        for entry in entries {
            counts[entry.reading.layout, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? .td3
    }

    /// Up to three other keys, most likely first:
    ///
    /// 1. rival keys the frames read outright;
    /// 2. one document-number character swapped for its congruent look-alike,
    ///    where any reading offered that look-alike;
    /// 3. a `K` straight before the number's filler, swapped for `<`;
    /// 4. swaps nothing offered but the number's shape makes suspicious: a
    ///    letter after the digits have begun, then a digit inside the leading
    ///    letters (numbers are a letter prefix and a digit run far more often
    ///    than not).
    ///
    /// The last two need no evidence because a misread repeated in every frame
    /// leaves none, and an alternate costs nothing unless the chip refuses the
    /// key, in which case a congruent misread is the likeliest reason.
    private func alternates(to voted: [Character], votes: [PositionVote], rivals: [PassportMRZ]) -> [PassportMRZ] {
        guard let primary = MRZKeySlots.key(from: voted) else { return [] }
        var out: [PassportMRZ] = []
        func offer(_ candidate: PassportMRZ?) {
            guard let candidate, candidate != primary, !out.contains(candidate), out.count < 3 else { return }
            out.append(candidate)
        }
        func swap(_ position: Int, to character: Character) -> PassportMRZ? {
            var swapped = voted
            swapped[position] = character
            return MRZKeySlots.key(from: swapped)
        }
        let number = MRZKeySlots.documentNumber
        rivals.forEach(offer)
        for position in number {
            guard let partner = Self.congruentLookAlikes[voted[position]],
                  votes[position].weights[partner, default: 0] > 0 else { continue }
            offer(swap(position, to: partner))
        }
        for position in number where voted[position] == "K"
            && voted[(position + 1) ..< number.upperBound].allSatisfy({ $0 == "<" })
        {
            offer(swap(position, to: "<"))
        }
        let firstDigit = number.first { voted[$0].isNumber } ?? number.upperBound
        let lastLetter = number.last { voted[$0].isLetter } ?? number.lowerBound
        for position in number where position > firstDigit && voted[position].isLetter {
            if let partner = Self.congruentLookAlikes[voted[position]], partner.isNumber {
                offer(swap(position, to: partner))
            }
        }
        for position in number where position < lastLetter && voted[position].isNumber {
            if let partner = Self.congruentLookAlikes[voted[position]], partner.isLetter {
                offer(swap(position, to: partner))
            }
        }
        // Then whatever congruent swap is left, letters to digits first, so a
        // number whose letters are scattered (some states mix them throughout)
        // still gets its chance.
        for wantsDigit in [true, false] {
            for position in number where voted[position].isLetter == wantsDigit {
                if let partner = Self.congruentLookAlikes[voted[position]], partner.isNumber == wantsDigit {
                    offer(swap(position, to: partner))
                }
            }
        }
        return out
    }
}
