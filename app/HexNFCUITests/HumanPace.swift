import ObjectiveC
import XCTest

/// Taps at a person's pace instead of XCUITest's.
///
/// Before every action XCUITest waits for the app to go idle, animations
/// included. A person does not, and the crash 1.0.1 shipped with on iOS 27
/// lives entirely inside an animation: swipe the last record away and press
/// Write within about 0.6 s, while the emptied record list is still on its way
/// out, and UIKit aborts (2026-10-22). Eighty-odd XCUITest runs could not reach
/// it, because none of them could tap during that window.
///
/// `run` switches the wait off for the duration of its closure by replacing
/// `XCUIApplicationProcess`'s quiescence methods with ones that return at once,
/// and puts them back afterwards. Private API, so test target only: nothing
/// here is linked into the app.
@MainActor
enum HumanPace {
    private static let selectors = [
        "waitForQuiescenceIncludingAnimationsIdle:",
        "waitForQuiescenceIncludingAnimationsIdle:isPreEvent:",
    ]

    /// `true` when at least one quiescence method was found to replace. A test
    /// that depends on tapping mid-animation should skip, not pass, when the
    /// toolchain has renamed them.
    static var isAvailable: Bool {
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return false }
        return selectors.contains { class_getInstanceMethod(process, NSSelectorFromString($0)) != nil }
    }

    private typealias OneFlag = @convention(block) (AnyObject, Bool) -> Void
    private typealias TwoFlags = @convention(block) (AnyObject, Bool, Bool) -> Void

    /// The replaced methods and their originals, while `run` has them swapped.
    private static var installed: [(Method, IMP)] = []

    static func run(_ body: () -> Void) {
        install()
        defer { restore() }
        body()
    }

    /// Put XCUITest's waits back. `run` does this itself, but a failing
    /// assertion can unwind out of its closure without running `defer`, which
    /// would leave every later test in the runner tapping mid-animation, so the
    /// test class calls this from `tearDown` as well. Safe to call at any time.
    static func restore() {
        for (method, original) in installed {
            method_setImplementation(method, original)
        }
        installed = []
    }

    private static func install() {
        guard installed.isEmpty, let process = NSClassFromString("XCUIApplicationProcess") else { return }
        let skipOne: OneFlag = { _, _ in }
        let skipTwo: TwoFlags = { _, _, _ in }
        for name in selectors {
            guard let method = class_getInstanceMethod(process, NSSelectorFromString(name)) else { continue }
            let skip = name.hasSuffix("isPreEvent:")
                ? imp_implementationWithBlock(skipTwo)
                : imp_implementationWithBlock(skipOne)
            installed.append((method, method_setImplementation(method, skip)))
        }
    }
}
