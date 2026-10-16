import HexNFCShaders
import SwiftUI

/// The Hex Pro signature motif: a hexagon split into three slices that
/// animate independently — frame fades + scales in, caret slides up,
/// inverted caret slides down. All on `.standard` spring, 60ms stagger.
///
/// Used as the launch logo, scan-success animation, and section-header
/// mask. Drawn entirely with `Canvas` so the Reduce-Motion fallback can
/// render an identical static composition without animation.
public struct HexTransition: View {
    public enum State: Sendable { case hidden, presenting, present }

    public var state: State
    public var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hexReduceMotion) private var appReduceMotion

    public init(state: State = .present, size: CGFloat = 96) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        let frame = HexTokens.Motion.standard
        let caretA = HexTokens.Motion.standard.delay(0.06)
        let caretB = HexTokens.Motion.standard.delay(0.12)
        let fade = Animation.easeOut(duration: 0.18)
        let useSpring = !(systemReduceMotion || appReduceMotion)
        ZStack {
            HexagonOutline()
                .stroke(HexTokens.Color.primary, lineWidth: 2)
                .opacity(state == .hidden ? 0 : 1)
                .scaleEffect(useSpring && state == .hidden ? 0.92 : 1)
                .animation(useSpring ? frame : fade, value: state)
            HexCaret(direction: .up)
                .fill(HexTokens.Color.primaryLight)
                .offset(y: useSpring && state == .hidden ? 8 : 0)
                .opacity(state == .hidden ? 0 : 1)
                .animation(useSpring ? caretA : fade, value: state)
            HexCaret(direction: .down)
                .fill(HexTokens.Color.primary)
                .offset(y: useSpring && state == .hidden ? -8 : 0)
                .opacity(state == .hidden ? 0 : 1)
                .animation(useSpring ? caretB : fade, value: state)
        }
        .frame(width: size, height: size)
    }
}

/// Regular hexagon, pointy-top orientation. Inset 1pt so the stroke sits
/// inside the bounding box.
public struct HexagonOutline: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - 1
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for index in 0 ..< 6 {
            let angle = Double(index) * (.pi / 3) - .pi / 2
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// Triangular caret used as one of the three hexagon slices.
public struct HexCaret: Shape {
    public enum Direction: Sendable { case up, down }
    public let direction: Direction

    public init(direction: Direction) {
        self.direction = direction
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 3
        let center = CGPoint(x: rect.midX, y: rect.midY)
        switch direction {
        case .up:
            path.move(to: CGPoint(x: center.x, y: center.y - radius))
            path.addLine(to: CGPoint(x: center.x + radius, y: center.y + radius * 0.5))
            path.addLine(to: CGPoint(x: center.x - radius, y: center.y + radius * 0.5))

        case .down:
            path.move(to: CGPoint(x: center.x, y: center.y + radius))
            path.addLine(to: CGPoint(x: center.x + radius, y: center.y - radius * 0.5))
            path.addLine(to: CGPoint(x: center.x - radius, y: center.y - radius * 0.5))
        }
        path.closeSubpath()
        return path
    }
}
