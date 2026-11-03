import Foundation

/// One finished NFC session, as the review prompt counts it.
///
/// The prompt asks people who are getting what they came for, and nobody who
/// has just watched the app fail. So it hears about every session the user
/// started that reached an outcome, and only that: a cancel, a timeout with no
/// tag in the field and a password prompt are not outcomes and are never sent.
public enum TagActivity: String, Codable, Sendable, Equatable {
    /// A write or an operation (protect, lock, erase, format) that finished.
    /// The only kind that counts toward the three: the owner's call is that
    /// changing a tag is the sign of someone using the app for real, where a
    /// read can be a one-off look.
    case changedTag
    /// A transit card read, or a passport, ID card or travel permit read in
    /// full. One is enough on its own, because these are what the app is for
    /// to the people who use it for them. A partial passport read is not this;
    /// it is `.failed`.
    case specialRead
    /// A tag read that finished, records or none. Counts as a success in the
    /// recent window, so it can push an old failure out, but adds nothing
    /// toward the three.
    case read
    /// Anything that put an error in front of the user, a refused password and
    /// a passport read that came back incomplete included.
    case failed
}

/// What the person said when the card asked "Loving Hex NFC?".
public enum ReviewPromptAnswer: Sendable, Equatable {
    /// "Love it!", or the Settings row that opens the App Store review page.
    case loved
    /// "Meh.", whatever they tap after it.
    case declined
    /// "Hide", or leaving Home with the card unanswered.
    case hidden
}

/// Everything the review prompt remembers, and the rules that read it.
///
/// Stored on the device only, in UserDefaults, and never synced or sent. iOS
/// does not tell an app whether someone has reviewed it, so "never ask someone
/// who has already reviewed" is approximated by `.loved`: the person was handed
/// Apple's rating sheet, or opened the review page themselves, and is not asked
/// again.
public struct ReviewPromptState: Codable, Equatable, Sendable {
    public enum Resolution: String, Codable, Sendable {
        case loved
        case declined
    }

    /// Successful writes and operations since counting last started.
    public var changedTags: Int
    /// Whether a transit card or a complete passport has been read since
    /// counting last started.
    public var hadSpecialRead: Bool
    /// The most recent outcomes, oldest first, at most `windowSize` of them.
    public var recent: [TagActivity]
    /// When the card was last shown.
    public var lastProposedAt: Date?
    /// Set by "Hide". Until this moment nothing is counted; the first session
    /// after it starts the counters again from nothing.
    public var pausedUntil: Date?
    /// Set once, by "Love it!" or "Meh.". Either way the card never comes back.
    public var resolution: Resolution?

    /// Successful writes or operations needed before the card may appear.
    public static let changesNeeded = 3
    /// How many recent outcomes must all be free of failure.
    public static let windowSize = 10
    /// The least time between two appearances of the card, and how long "Hide"
    /// pauses counting. Thirty days rather than a calendar month, so the rule
    /// reads the same in every calendar the app runs under.
    public static let interval: TimeInterval = 30 * 24 * 60 * 60

    public init(
        changedTags: Int = 0,
        hadSpecialRead: Bool = false,
        recent: [TagActivity] = [],
        lastProposedAt: Date? = nil,
        pausedUntil: Date? = nil,
        resolution: Resolution? = nil
    ) {
        self.changedTags = changedTags
        self.hadSpecialRead = hadSpecialRead
        self.recent = recent
        self.lastProposedAt = lastProposedAt
        self.pausedUntil = pausedUntil
        self.resolution = resolution
    }

    /// Every field is optional on the way in, so a later version can add one
    /// and still read what this version stored. An unknown `TagActivity` drops
    /// the window rather than the whole state.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changedTags = try container.decodeIfPresent(Int.self, forKey: .changedTags) ?? 0
        hadSpecialRead = try container.decodeIfPresent(Bool.self, forKey: .hadSpecialRead) ?? false
        recent = (try? container.decodeIfPresent([TagActivity].self, forKey: .recent)) ?? []
        lastProposedAt = try container.decodeIfPresent(Date.self, forKey: .lastProposedAt)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        resolution = try? container.decodeIfPresent(Resolution.self, forKey: .resolution)
    }

    /// Count one finished session.
    public mutating func record(_ activity: TagActivity, now: Date = Date()) {
        guard resolution == nil else { return }
        if let pausedUntil {
            guard now >= pausedUntil else { return }
            // The pause is over and the person is using the app again, so they
            // start from nothing, exactly as someone who has never seen the
            // card. Without the reset, three writes from before the pause
            // would bring the card straight back.
            changedTags = 0
            hadSpecialRead = false
            recent = []
            self.pausedUntil = nil
        }
        recent.append(activity)
        if recent.count > Self.windowSize {
            recent.removeFirst(recent.count - Self.windowSize)
        }
        switch activity {
        case .changedTag:
            changedTags += 1

        case .specialRead:
            hadSpecialRead = true

        case .read, .failed:
            break
        }
    }

    /// Whether the card may appear now.
    ///
    /// A pause that has run out still answers false until the next session
    /// resets the counters: the counts it is holding are from before the
    /// person said "Hide".
    public func isEligible(now: Date = Date()) -> Bool {
        guard resolution == nil, pausedUntil == nil else { return false }
        if let lastProposedAt, now < lastProposedAt.addingTimeInterval(Self.interval) {
            return false
        }
        guard changedTags >= Self.changesNeeded || hadSpecialRead else { return false }
        return !recent.contains(.failed)
    }

    /// The card has just appeared.
    public mutating func markProposed(now: Date = Date()) {
        lastProposedAt = now
    }

    public mutating func answer(_ answer: ReviewPromptAnswer, now: Date = Date()) {
        switch answer {
        case .loved:
            resolution = .loved

        case .declined:
            resolution = .declined

        case .hidden:
            // Measured from the proposal, not the tap: a card left on screen
            // for an hour before "Hide" still pauses for thirty days from when
            // it appeared.
            pausedUntil = (lastProposedAt ?? now).addingTimeInterval(Self.interval)
        }
    }
}
