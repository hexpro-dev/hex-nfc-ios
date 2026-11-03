import Foundation
import Observation

/// Where the scan, write and operations flows report each finished session.
///
/// A protocol so flow tests can hand in a recorder of their own and assert on
/// what was reported, without a UserDefaults store in the way.
@MainActor
public protocol TagActivityRecording: AnyObject {
    func record(_ activity: TagActivity)
}

/// The app's one copy of the review prompt state, kept in UserDefaults.
///
/// Owned by `AppModel` and handed to each flow model as its
/// `TagActivityRecording`. Home asks it whether the card may appear, and the
/// card hands back the answer.
@Observable
@MainActor
public final class ReviewPromptModel: TagActivityRecording {
    public enum Mode: Sendable, Equatable {
        /// Counts sessions and shows the card when the rules allow.
        case live
        /// Counts nothing and never shows the card. UI test runs and the docs
        /// capture launch with `--noReviewPrompt`, because both write to real
        /// tags and sit on Home, and on a real phone they share the owner's
        /// own store: a run would otherwise use up the owner's prompt and drop
        /// the card into screenshots.
        case disabled
        /// Shows the card whenever Home has been idle, whatever has been
        /// counted, and remembers nothing: the stored state is neither read
        /// nor written. For UI tests and screenshots of the card itself
        /// (`--reviewPromptPreview`).
        case preview
    }

    public let mode: Mode
    public private(set) var state: ReviewPromptState

    private let defaults: UserDefaults
    private let now: () -> Date
    /// Preview mode shows the card once per launch, so a test that taps
    /// "Hide" can see it go and stay gone.
    private var previewShown = false

    static let storageKey = "pro.hex.nfc.reviewPrompt"

    public init(
        mode: Mode,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.mode = mode
        self.defaults = defaults
        self.now = now
        state = mode == .live ? Self.load(from: defaults) : ReviewPromptState()
    }

    /// The flag a launch argument picks. Arguments are only ever set by Xcode
    /// and the test runner, never by someone using the app.
    public static func mode(forArguments arguments: [String]) -> Mode {
        if arguments.contains("--noReviewPrompt") {
            return .disabled
        }
        if arguments.contains("--reviewPromptPreview") {
            return .preview
        }
        return .live
    }

    public func record(_ activity: TagActivity) {
        guard mode == .live else { return }
        state.record(activity, now: now())
        save()
    }

    /// Whether Home may show the card after its idle wait.
    public var mayPropose: Bool {
        switch mode {
        case .live: state.isEligible(now: now())
        case .disabled: false
        case .preview: !previewShown
        }
    }

    /// Call as the card appears, so the thirty days run from what the person saw.
    public func proposed() {
        if mode == .preview {
            previewShown = true
        }
        guard mode == .live else { return }
        state.markProposed(now: now())
        save()
    }

    public func answer(_ answer: ReviewPromptAnswer) {
        guard mode == .live else { return }
        state.answer(answer, now: now())
        save()
    }

    // MARK: - Persistence

    /// Missing or unreadable data is a fresh start. The worst that does is
    /// count from zero again, which asks later rather than sooner.
    static func load(from defaults: UserDefaults) -> ReviewPromptState {
        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(ReviewPromptState.self, from: data)
        else { return ReviewPromptState() }
        return state
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
