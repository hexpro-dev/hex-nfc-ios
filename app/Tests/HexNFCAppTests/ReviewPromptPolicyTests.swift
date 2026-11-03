@testable import HexNFCApp
import XCTest

/// When "Loving Hex NFC?" may appear.
///
/// The owner's rules, one test each: three finished writes or operations, or
/// one transit or complete passport read; nothing failed in the last ten
/// sessions; at most once in thirty days; never again after "Love it!" or
/// "Meh."; and "Hide" pauses counting for thirty days, after which the next
/// session starts the count from nothing.
final class ReviewPromptPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func state(_ activities: [TagActivity], at now: Date? = nil) -> ReviewPromptState {
        var state = ReviewPromptState()
        for activity in activities {
            state.record(activity, now: now ?? start)
        }
        return state
    }

    // MARK: - What earns the card

    func test_threeChangedTags_areEligible() {
        XCTAssertFalse(state([.changedTag, .changedTag]).isEligible(now: start))
        XCTAssertTrue(state([.changedTag, .changedTag, .changedTag]).isEligible(now: start))
    }

    func test_readsAlone_neverEarnTheCard() {
        XCTAssertFalse(state(Array(repeating: .read, count: 20)).isEligible(now: start))
    }

    func test_readsBetweenChanges_doNotBreakTheCount() {
        XCTAssertTrue(state([.changedTag, .read, .changedTag, .read, .changedTag]).isEligible(now: start))
    }

    func test_oneSpecialRead_isEnoughOnItsOwn() {
        XCTAssertTrue(state([.specialRead]).isEligible(now: start))
    }

    // MARK: - What keeps it away

    func test_aFailureInTheWindow_blocks() {
        XCTAssertFalse(state([.changedTag, .changedTag, .failed, .changedTag]).isEligible(now: start))
        XCTAssertFalse(state([.failed, .specialRead]).isEligible(now: start))
    }

    /// A failure stops counting against the card once ten later sessions have
    /// pushed it out of the window, reads included.
    func test_aFailure_clearsAfterTenLaterSessions() {
        let nine: [TagActivity] = [.changedTag, .changedTag, .changedTag] + Array(repeating: .read, count: 6)
        XCTAssertFalse(state([.failed] + nine).isEligible(now: start), "still the tenth most recent")
        XCTAssertTrue(state([.failed] + nine + [.read]).isEligible(now: start), "now the eleventh")
    }

    func test_window_keepsOnlyTheLastTen() {
        let full = state(Array(repeating: .read, count: 25))
        XCTAssertEqual(full.recent.count, ReviewPromptState.windowSize)
    }

    // MARK: - Cadence

    func test_afterAProposal_waitsThirtyDays() {
        var state = state([.specialRead])
        state.markProposed(now: start)

        XCTAssertFalse(state.isEligible(now: start.addingTimeInterval(29 * day)))
        XCTAssertTrue(state.isEligible(now: start.addingTimeInterval(30 * day)))
    }

    // MARK: - Answers

    func test_loved_isNeverAskedAgain() {
        var state = state([.specialRead])
        state.markProposed(now: start)
        state.answer(.loved, now: start)

        state.record(.specialRead, now: start.addingTimeInterval(400 * day))
        XCTAssertFalse(state.isEligible(now: start.addingTimeInterval(400 * day)))
        XCTAssertEqual(state.resolution, .loved)
    }

    func test_declined_isNeverAskedAgain() {
        var state = state([.specialRead])
        state.markProposed(now: start)
        state.answer(.declined, now: start)

        state.record(.specialRead, now: start.addingTimeInterval(400 * day))
        XCTAssertFalse(state.isEligible(now: start.addingTimeInterval(400 * day)))
        XCTAssertEqual(state.resolution, .declined)
    }

    /// The Settings row: someone who opened the review page themselves is
    /// treated as having reviewed, card or no card.
    func test_lovedWithoutAProposal_stillEndsIt() {
        var state = state([.changedTag, .changedTag, .changedTag])
        state.answer(.loved, now: start)
        XCTAssertFalse(state.isEligible(now: start))
    }

    func test_hidden_pausesCountingForThirtyDays() {
        var state = state([.changedTag, .changedTag, .changedTag])
        state.markProposed(now: start)
        state.answer(.hidden, now: start.addingTimeInterval(60))

        for _ in 0 ..< 5 {
            state.record(.changedTag, now: start.addingTimeInterval(10 * day))
        }
        XCTAssertEqual(state.changedTags, 3, "nothing is counted during the pause")
        XCTAssertFalse(state.isEligible(now: start.addingTimeInterval(31 * day)), "and the old count does not return")
    }

    /// Thirty days on, the first session starts a fresh count: three new
    /// writes are needed, not one more on top of the old three.
    func test_hidden_restartsFromNothingOnTheFirstSessionAfterThePause() {
        var state = state([.changedTag, .changedTag, .changedTag, .failed])
        state.markProposed(now: start)
        state.answer(.hidden, now: start)

        let later = start.addingTimeInterval(31 * day)
        state.record(.changedTag, now: later)
        XCTAssertEqual(state.changedTags, 1)
        XCTAssertEqual(state.recent, [.changedTag], "the old failure went with the old count")
        XCTAssertNil(state.pausedUntil)
        XCTAssertFalse(state.isEligible(now: later))

        state.record(.changedTag, now: later)
        state.record(.changedTag, now: later)
        XCTAssertTrue(state.isEligible(now: later))
    }

    /// The pause runs from when the card appeared, not from when "Hide" was
    /// tapped.
    func test_hidden_isMeasuredFromTheProposal() {
        var state = state([.specialRead])
        state.markProposed(now: start)
        state.answer(.hidden, now: start.addingTimeInterval(2 * day))

        XCTAssertEqual(state.pausedUntil, start.addingTimeInterval(30 * day))
    }

    // MARK: - Storage

    func test_codable_roundTrips() throws {
        var original = state([.changedTag, .failed, .specialRead])
        original.markProposed(now: start)
        original.answer(.hidden, now: start)

        let decoded = try JSONDecoder().decode(ReviewPromptState.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// A later version may add fields or activities. What this version stored
    /// must still read, and what it does not understand must not cost the rest.
    func test_decoding_toleratesMissingAndUnknownFields() throws {
        let json = #"{"changedTags":2,"recent":["changedTag","somethingNew"],"resolution":"unheardOf"}"#
        let decoded = try JSONDecoder().decode(ReviewPromptState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.changedTags, 2)
        XCTAssertEqual(decoded.recent, [])
        XCTAssertNil(decoded.resolution)
        XCTAssertFalse(decoded.hadSpecialRead)
    }
}

@MainActor
final class ReviewPromptModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "pro.hex.nfc.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_live_persistsAcrossLaunches() {
        let first = ReviewPromptModel(mode: .live, defaults: defaults)
        first.record(.changedTag)
        first.record(.changedTag)
        first.record(.changedTag)

        let second = ReviewPromptModel(mode: .live, defaults: defaults)
        XCTAssertEqual(second.state.changedTags, 3)
        XCTAssertTrue(second.mayPropose)
    }

    func test_live_unreadableStorage_startsFresh() {
        defaults.set(Data("not json".utf8), forKey: ReviewPromptModel.storageKey)
        let model = ReviewPromptModel(mode: .live, defaults: defaults)
        XCTAssertEqual(model.state, ReviewPromptState())
    }

    /// UI tests and the docs capture write to real tags on the owner's phone.
    /// Disabled must neither count those sessions nor show the card.
    func test_disabled_recordsNothingAndNeverProposes() {
        let model = ReviewPromptModel(mode: .disabled, defaults: defaults)
        model.record(.specialRead)
        model.answer(.loved)

        XCTAssertFalse(model.mayPropose)
        XCTAssertNil(defaults.data(forKey: ReviewPromptModel.storageKey))
    }

    /// Preview shows the card once, whatever is stored, and stores nothing.
    func test_preview_proposesOnceAndStoresNothing() {
        let model = ReviewPromptModel(mode: .preview, defaults: defaults)
        XCTAssertTrue(model.mayPropose)

        model.proposed()
        model.answer(.hidden)

        XCTAssertFalse(model.mayPropose)
        XCTAssertNil(defaults.data(forKey: ReviewPromptModel.storageKey))
    }

    func test_launchArguments_pickTheMode() {
        XCTAssertEqual(ReviewPromptModel.mode(forArguments: ["HexNFC"]), .live)
        XCTAssertEqual(ReviewPromptModel.mode(forArguments: ["HexNFC", "--noReviewPrompt"]), .disabled)
        XCTAssertEqual(ReviewPromptModel.mode(forArguments: ["HexNFC", "--reviewPromptPreview"]), .preview)
        XCTAssertEqual(
            ReviewPromptModel.mode(forArguments: ["--reviewPromptPreview", "--noReviewPrompt"]),
            .disabled,
            "suppression wins, so a run that asks for both stays clean"
        )
    }

    func test_proposedAndAnswered_areStored() {
        let model = ReviewPromptModel(mode: .live, defaults: defaults)
        model.record(.specialRead)
        model.proposed()
        model.answer(.declined)

        let reloaded = ReviewPromptModel(mode: .live, defaults: defaults)
        XCTAssertEqual(reloaded.state.resolution, .declined)
        XCTAssertNotNil(reloaded.state.lastProposedAt)
        XCTAssertFalse(reloaded.mayPropose)
    }
}
