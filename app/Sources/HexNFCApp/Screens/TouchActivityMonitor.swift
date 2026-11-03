#if os(iOS)
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Calls `onTouch` for every touch that lands anywhere in the window, and
/// takes none of them.
///
/// The review card waits for ten seconds with nobody touching Home. SwiftUI has
/// no window-wide "a touch happened" signal, and the obvious stand-in, a
/// `DragGesture(minimumDistance: 0)` attached to the screen, competes with the
/// `ScrollView` underneath for the same touches and can stop it scrolling. So
/// this installs a UIKit recogniser on the window that reports each touch as it
/// begins and then fails straight away: it never recognises, never delays a
/// touch and never cancels one, so every control behaves as if it were absent.
struct TouchActivityMonitor: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> InstallerView {
        InstallerView(recognizer: context.coordinator.recognizer)
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.recognizer.onTouch = onTouch
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouch: onTouch)
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
    }

    final class Coordinator {
        let recognizer: PassiveTouchRecognizer

        init(onTouch: @escaping () -> Void) {
            recognizer = PassiveTouchRecognizer(onTouch: onTouch)
        }
    }

    /// Zero-size view whose only job is to find the window once it is in one.
    final class InstallerView: UIView {
        private let recognizer: PassiveTouchRecognizer

        init(recognizer: PassiveTouchRecognizer) {
            self.recognizer = recognizer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, recognizer.view !== window else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            window.addGestureRecognizer(recognizer)
        }
    }

    final class PassiveTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onTouch: () -> Void

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            // Failing at once is what keeps this out of the way: a failed
            // recogniser takes no further part in the touch.
            state = .failed
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
