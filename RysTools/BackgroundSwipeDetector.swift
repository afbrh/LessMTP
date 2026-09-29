import SwiftUI
import UIKit

// Global-coordinate-space frames of every currently on-screen card that has its
// own native .swipeActions (an email row, calendar event, or scratch box — see
// .swipeableCard() below, used in EmailView/CalendarView/ScratchView). RootView
// collects these via .onPreferenceChange and feeds them to BackgroundSwipeDetector,
// so it knows exactly where a swipe should reveal that card's own action instead
// of switching tools.
struct SwipeableCardFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func swipeableCard() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SwipeableCardFramesKey.self, value: [proxy.frame(in: .global)])
            }
        )
    }
}

// Detects a horizontal swipe anywhere on screen to switch tools (see RootView's
// background-swipe feature), but must NOT fire when the swipe starts on a card
// that has its own native .swipeActions — those need the touch instead. A plain
// SwiftUI .simultaneousGesture with a distance/angle threshold can only make
// that a *rare* collision, not actually rule it out.
//
// Two things were tried and rejected before this:
// - Rejecting by "is this touch inside any List row" (a UITableViewCell /
//   UICollectionViewCell): nearly every screen in this app IS a List end-to-end,
//   so that blocked the background swipe almost everywhere, not just on the
//   swipeable cards.
// - Rejecting by UIKit view identity (.accessibilityIdentifier set from
//   SwiftUI): unreliable, since SwiftUI's own rendering mostly doesn't back
//   individual rows with distinct UIViews for touch hit-testing to find.
//
// Instead, each swipeable row reports its own on-screen frame via
// .swipeableCard(), RootView collects them into SwipeableCardFramesKey, and
// this checks the touch's starting location against those exact rectangles —
// so non-swipeable rows (Settings group cards, Scratch's "Add box" button, the
// calendar month grid) are left alone and the background swipe still works
// there, while it's excluded only where a card's own swipe needs the touch.
struct BackgroundSwipeDetector: UIViewRepresentable {
    var swipeableCardFrames: [CGRect]
    var onSwipe: (Bool) -> Void  // forward: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        context.coordinator.swipeableCardFrames = swipeableCardFrames
        context.coordinator.attach(to: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipe: (Bool) -> Void
        var swipeableCardFrames: [CGRect] = []
        private weak var attachedWindow: UIWindow?

        init(onSwipe: @escaping (Bool) -> Void) {
            self.onSwipe = onSwipe
        }

        func attach(to view: UIView) {
            guard let window = view.window, attachedWindow !== window else { return }
            attachedWindow = window
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            window.addGestureRecognizer(recognizer)
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            guard abs(translation.x) > abs(translation.y) * 1.5, abs(translation.x) > 90 else { return }
            onSwipe(translation.x < 0)
        }

        // Never block anything already in the hierarchy — List scrolling, native
        // swipeActions, TextEditor's own tap-to-place-cursor, the tool switcher
        // title's own DragGesture — we only ever want to observe, not compete.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // The actual filter: refuse the touch outright if it starts inside one of
        // the currently-reported swipeable card frames, so that card's own swipe
        // action always gets it instead of racing this gesture on distance/angle
        // alone. touch.location(in: nil) is window coordinates, which line up
        // with SwiftUI's .global coordinate space used by .swipeableCard() since
        // RootView's content fills the window with no extra scaling/transforms.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let location = touch.location(in: nil)
            return !swipeableCardFrames.contains { $0.contains(location) }
        }
    }
}
