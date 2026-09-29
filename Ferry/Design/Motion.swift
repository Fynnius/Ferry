import SwiftUI
import AppKit

/// Motion vocabulary. Everything collapses to a short cross-fade under Reduce Motion.
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `repoRise`, `expand`, `fileMove`, `buttonMorph`.
    static var snappy: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.32)
    }

    /// `countTick`.
    static var smooth: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3)
    }

    static func animate(_ animation: Animation = snappy, _ body: () -> Void) {
        withAnimation(animation, body)
    }
}

extension AnyTransition {
    /// A card entering or leaving the stack.
    static var repoRise: AnyTransition {
        Motion.reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity)
    }
}

/// `errorShake`: horizontal keyframes, or nothing under Reduce Motion (the caller shows
/// the "Write a message first" hint instead).
struct ShakeEffect: ViewModifier {
    var trigger: Int

    func body(content: Content) -> some View {
        if Motion.reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(8, duration: 0.06)
                    LinearKeyframe(-6, duration: 0.08)
                    LinearKeyframe(4, duration: 0.08)
                    LinearKeyframe(0, duration: 0.08)
                }
            }
        }
    }
}

extension View {
    func shake(trigger: Int) -> some View {
        modifier(ShakeEffect(trigger: trigger))
    }
}
