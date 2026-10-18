import XCTest
@testable import JarvisApp

/// Pure-logic tests for the features-day additions:
///   - AppLockPolicy: the Face ID lock decision matrix (no LAContext /
///     Keychain needed — policy is deliberately separated from the store).
///   - CallLogStore: audio-quality line semantics (only gateway-confirmed
///     data produces "audio in/out confirmed"; never fabricated).
/// These run headless on CI (xcodebuild test, iOS Simulator).
final class AppLockPolicyTests: XCTestCase {

    // MARK: Lock decision matrix

    func testDisabledNeverLocks() {
        // Master switch off: every trigger stays unlocked.
        XCTAssertFalse(AppLockPolicy.lockRequired(enabled: false, launchOnly: false, trigger: .coldLaunch))
        XCTAssertFalse(AppLockPolicy.lockRequired(enabled: false, launchOnly: false, trigger: .foregroundReturn))
        XCTAssertFalse(AppLockPolicy.lockRequired(enabled: false, launchOnly: true, trigger: .coldLaunch))
    }

    func testEnabledAlwaysLocksOnColdLaunch() {
        XCTAssertTrue(AppLockPolicy.lockRequired(enabled: true, launchOnly: false, trigger: .coldLaunch))
        XCTAssertTrue(AppLockPolicy.lockRequired(enabled: true, launchOnly: true, trigger: .coldLaunch),
                      "'Require on launch' still locks on LAUNCH — it only relaxes mid-session returns")
    }

    func testRequireOnLaunchOnlySkipsForegroundReturn() {
        XCTAssertTrue(AppLockPolicy.lockRequired(enabled: true, launchOnly: false, trigger: .foregroundReturn))
        XCTAssertFalse(AppLockPolicy.lockRequired(enabled: true, launchOnly: true, trigger: .foregroundReturn),
                       "'Require on launch' must NOT re-lock every background→foreground return")
    }

    func testManualTriggerAlwaysLocks() {
        XCTAssertTrue(AppLockPolicy.lockRequired(enabled: true, launchOnly: true, trigger: .manual))
    }

    // MARK: LA policy gate (feature #39 spec: .deviceOwnerAuthentication)

    func testGateIsAlwaysDeviceOwnerAuthentication() {
        // Spec #39: the gate is ALWAYS .deviceOwnerAuthentication — biometrics
        // evaluate inside it when enrolled AND the passcode fallback is part
        // of the same policy. The biometrics-only variant is never the gate:
        // with no enrollment it leaves the app unprotected-or-unlockable.
        XCTAssertEqual(AppLockPolicy.authPolicy(biometricsAvailable: true),
                       .deviceOwnerAuthentication)
    }

    func testPasscodeCapableGateWhenBiometricsUnavailable() {
        // No enrollment / biometry locked out → SAME passcode-capable policy,
        // so the app can never be left unprotected OR permanently locked.
        XCTAssertEqual(AppLockPolicy.authPolicy(biometricsAvailable: false),
                       .deviceOwnerAuthentication)
    }
}

final class CallLogAudioSummaryTests: XCTestCase {

    @MainActor
    private func freshStore() -> CallLogStore {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return CallLogStore(defaults: defaults)
    }

    @MainActor
    func testStampAudioSummaryBothDirectionsConfirmed() {
        let store = freshStore()
        let id = store.add(reason: "Hey JARVIS", outgoing: true)
        store.stampAudioSummary(id: id, inFrames: 42, outFrames: 40)
        XCTAssertEqual(CallLogStore.audioQualityLabel(
            inFrames: store.entries.first?.audioInFrames,
            outFrames: store.entries.first?.audioOutFrames),
            "audio in/out confirmed")
    }

    @MainActor
    func testStampAudioSummaryInboundOnly() {
        let store = freshStore()
        let id = store.add(reason: "call", outgoing: false)
        store.stampAudioSummary(id: id, inFrames: 10, outFrames: 0)
        XCTAssertEqual(CallLogStore.audioQualityLabel(
            inFrames: store.entries.first?.audioInFrames,
            outFrames: store.entries.first?.audioOutFrames),
            "audio in only — no bot audio sent")
    }

    @MainActor
    func testStampAudioSummaryZeroFramesStillRecordsFacts() {
        // Gateway reported but both directions at zero → frames recorded
        // (facts, not fiction); the LABEL says "no audio either way".
        let store = freshStore()
        let id = store.add(reason: "call", outgoing: true)
        store.stampAudioSummary(id: id, inFrames: 0, outFrames: 0)
        XCTAssertEqual(store.entries.first?.audioInFrames, 0)
        XCTAssertEqual(CallLogStore.audioQualityLabel(inFrames: 0, outFrames: 0),
                       "no audio either way")
    }

    @MainActor
    func testStampAudioSummaryUnknownCallIdIsNoop() {
        // Push-wake races can attach after the entry was pruned; must not
        // create phantom entries.
        let store = freshStore()
        store.stampAudioSummary(id: "does-not-exist", inFrames: 5, outFrames: 5)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testNoSummaryYieldsNoAudioLine() {
        // nil frames = summary never arrived (older builds, crashed
        // sessions) → nil label. Never a guess.
        XCTAssertNil(CallLogStore.audioQualityLabel(inFrames: nil, outFrames: nil))
        XCTAssertNil(CallLogStore.audioQualityLabel(inFrames: 3, outFrames: nil))
        XCTAssertNil(CallLogStore.audioQualityLabel(inFrames: nil, outFrames: 3))
    }

    @MainActor
    func testEntryWithoutSummaryRendersNoAudioLine() {
        let store = freshStore()
        store.add(reason: "plain call", outgoing: true)
        XCTAssertNil(store.entries.first?.audioInFrames,
                     "No gateway summary → no audio-quality line (do not fake)")
    }
}
