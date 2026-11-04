import SwiftUI
import AppKit

/// Motion, the way Apple describes it: springs everywhere, set by a
/// perceptual duration and a bounce. No bounce for ordinary changes, a little
/// (~15%) where something answers the pointer, never more than ~30%. Springs
/// keep their velocity when interrupted, so nothing has to finish before the
/// next change starts. With Reduce Motion, things fade instead of moving.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Ordinary state changes: layout, selection, expanding sections.
    static var smooth: Animation { reduced ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35) }
    /// Direct answers to the pointer: hover, picking a tab.
    static var snappy: Animation { reduced ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25) }
    /// Pressing down and letting go.
    static var press: Animation { reduced ? .easeOut(duration: 0.1) : .spring(duration: 0.2, bounce: 0.25) }
    /// Something arriving: a popover, a widget, a preview.
    static var appear: Animation { reduced ? .easeOut(duration: 0.18) : .spring(duration: 0.4, bounce: 0.2) }
    /// Something leaving: quicker, never bouncy.
    static var disappear: Animation { reduced ? .easeIn(duration: 0.12) : .smooth(duration: 0.2) }
    /// Content swapping in place: numbers counting, pages.
    static var content: Animation { reduced ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4) }

    /// Progress of a critically damped spring (`.smooth`) at `t` seconds,
    /// for motion driven frame by frame outside SwiftUI.
    static func smoothProgress(_ t: Double, duration: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        guard !reduced else { return CGFloat(min(1, t / 0.2)) }
        let w = 2 * Double.pi / duration
        return CGFloat(min(1, 1 - (1 + w * t) * exp(-w * t)))
    }
}

/// Buttons that dip slightly when pressed and spring back, like Apple's.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension View {
    /// A number that rolls to its new value instead of jumping.
    func rollingNumber(_ value: Double) -> some View {
        monospacedDigit()
            .contentTransition(.numericText(value: value))
            .animation(Motion.content, value: value)
    }

    /// A soft shadow cast only outside `shape`, so it can sit under see-through
    /// glass without darkening it, and scale along with the view.
    func outerShadow<S: Shape>(_ shape: S, radius: CGFloat, y: CGFloat, opacity: Double) -> some View {
        background(
            shape.fill(Color.black)
                .shadow(color: .black.opacity(opacity), radius: radius, y: y)
                .mask(
                    Rectangle().padding(-(radius * 3 + abs(y)))
                        .overlay(shape.fill(Color.black).blendMode(.destinationOut))
                        .compositingGroup()
                )
                .allowsHitTesting(false)
        )
    }
}
