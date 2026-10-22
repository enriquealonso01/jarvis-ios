import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// The mic's touch host (build 83: the recording bar's buttons couldn't be pressed). It takes
/// touches only inside the mic's last frame and only until the note locks, so it can never
/// shadow Delete, Pause, Resume or Send; and it drives the same press state machine the view
/// used to.
@MainActor
final class VoiceMicTouchHostTests: XCTestCase {
    private var began = 0, locks = 0, cancels = 0, releases = 0, taps = 0
    private var drags: [CGSize] = []

    private func coordinator(context: VoiceMicPressContext) -> VoiceMicTouchHost.Coordinator {
        let coordinator = VoiceMicTouchHost.Coordinator()
        coordinator.contextProvider = { context }
        coordinator.handlers = VoiceMicPressHandlers(
            onPressBegan: { [unowned self] in began += 1 },
            onDrag: { [unowned self] in drags.append($0) },
            onLock: { [unowned self] in locks += 1 },
            onCancel: { [unowned self] in cancels += 1 },
            onRelease: { [unowned self] in releases += 1 },
            onTap: { [unowned self] in taps += 1 }
        )
        return coordinator
    }

    private let open = VoiceMicPressContext(tapRecords: true, isLocked: false, noteInProgress: false, isDisabled: false)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testTheHostTakesTouchesOnlyInsideTheMicsFrameAndOnlyWhileEnabled() {
        let host = VoiceMicTouchHost.HostView(frame: CGRect(x: 0, y: 0, width: 400, height: 120))
        let recognizer = UILongPressGestureRecognizer()
        host.addGestureRecognizer(recognizer)
        host.recognizer = recognizer
        host.micRect = CGRect(x: 340, y: 40, width: 44, height: 44)
        XCTAssertTrue(host.point(inside: CGPoint(x: 360, y: 60), with: nil))
        XCTAssertFalse(host.point(inside: CGPoint(x: 60, y: 60), with: nil), "the rest of the composer passes through")
        XCTAssertNil(host.hitTest(CGPoint(x: 60, y: 60), with: nil))

        // Locked or paused: micRect is zero and the recognizer is off, so nothing is ever taken.
        host.micRect = .zero
        recognizer.isEnabled = false
        XCTAssertFalse(host.point(inside: CGPoint(x: 360, y: 60), with: nil), "Pause, Resume, Delete and Send are never shadowed")
        XCTAssertNil(host.hitTest(CGPoint(x: 360, y: 60), with: nil))
    }

    func testAHoldAndReleaseSendsThroughTheHandlers() {
        let c = coordinator(context: open)
        c.deliver(.touchDown(t0))
        c.deliver(.moved(CGSize(width: 2, height: -3)))
        c.deliver(.released(t0 + 1.4))
        XCTAssertEqual([began, locks, cancels, releases, taps], [1, 0, 0, 1, 0])
        XCTAssertEqual(drags.last, .zero)
    }

    func testASwipeUpLocksOnceAndTheLaterReleaseDoesNothing() {
        let c = coordinator(context: open)
        c.deliver(.touchDown(t0))
        c.deliver(.moved(CGSize(width: 0, height: -90)))
        c.deliver(.moved(CGSize(width: 0, height: -160)))
        c.deliver(.cancelled)  // the host is disabled under the finger as the note locks
        XCTAssertEqual([began, locks, cancels, releases], [1, 1, 0, 0])
    }

    func testASlideLeftCancels() {
        let c = coordinator(context: open)
        c.deliver(.touchDown(t0))
        c.deliver(.moved(CGSize(width: -130, height: 4)))
        c.deliver(.released(t0 + 1))
        XCTAssertEqual([began, locks, cancels, releases], [1, 0, 1, 0])
    }

    func testAnInterruptedHoldLocksTheNote() {
        let c = coordinator(context: open)
        c.deliver(.touchDown(t0))
        c.deliver(.cancelled)
        XCTAssertEqual([began, locks, cancels, releases], [1, 1, 0, 0])
    }

    func testAPressWhileANoteIsInProgressDoesNothing() {
        let c = coordinator(context: VoiceMicPressContext(tapRecords: true, isLocked: true, noteInProgress: true, isDisabled: false))
        c.deliver(.touchDown(t0))
        c.deliver(.moved(CGSize(width: 0, height: -200)))
        c.deliver(.released(t0 + 1))
        XCTAssertEqual([began, locks, cancels, releases, taps], [0, 0, 0, 0, 0])
    }

    func testWithTapsSetToDictateAShortPressDictates() {
        let c = coordinator(context: VoiceMicPressContext(tapRecords: false, isLocked: false, noteInProgress: false, isDisabled: false))
        c.deliver(.touchDown(t0))
        c.deliver(.released(t0 + 0.1))
        XCTAssertEqual([began, taps], [0, 1])
    }
}
