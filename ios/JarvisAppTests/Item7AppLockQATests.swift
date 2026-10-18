import XCTest
@testable import JarvisApp

/// Item 7 TESTER QA — feature #39 (V2-PLAN.md): Face ID app lock + privacy
/// shield, P0. This suite PINS the contract before/at implementation time.
/// It is pure logic only (no UIKit; the only LA-adjacent surface touched is
/// `LAPolicy`, an enum, via the same pure mapping the app itself uses).
///
/// Seams the implementation must expose (protocol-injected, per task brief):
///   - `AppLockPolicy.lockRequired(enabled:launchOnly:trigger:)` — pure.
///   - `AppLockPolicy.authPolicy(biometricsAvailable:) -> LAPolicy` — pure
///     mapping; .deviceOwnerAuthentication (which INCLUDES biometric when
///     enrolled) is the mandated gate; biometrics-only is a stopgap.
///   - `AppLockEngine` — a @MainActor ObservableObject with protocol-injected
///     `AppLockPolicyEvaluating` (evaluate) + `AppLockClock` (now), driving
///     `appBackgrounded()` / `appActivated()` with the same state machine the
///     real controller runs.
///   - `AuthStore.keychainAccessibility` — the static configuration value
///     passed as kSecAttrAccessible; the spec mandates
///     kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
@MainActor
final class Item7AppLockQATests: XCTestCase {

    // MARK: fixtures

    private final class MockPolicy: AppLockPolicyEvaluating {
        var granted: Bool
        var requestedPolicies: [LAPolicy] = []
        init(granted: Bool) { self.granted = granted }
        func evaluate(_ policy: LAPolicy) async -> Bool {
            requestedPolicies.append(policy)
            return granted
        }
    }

    private func makeEngine(granted: Bool,
                            enabled: Bool = true,
                            launchOnly: Bool = false) -> (AppLockEngine, MockPolicy) {
        let policy = MockPolicy(granted: granted)
        let engine = AppLockEngine(
            lockEnabled: { enabled },
            launchOnly: { launchOnly },
            policyEvaluator: policy)
        return (engine, policy)
    }

    // MARK: 1 — unlock gate policy: .deviceOwnerAuthentication (spec #39)

    func testUnlockGateUsesDeviceOwnerAuthenticationWithPasscodeFallback() {
        // The MANDATED gate: .deviceOwnerAuthentication — biometric when
        // enrolled AND passcode fallback built in. Biometrics-only
        // (.deviceOwnerAuthenticationWithBiometrics) is NOT the spec gate:
        // with no enrollment it leaves the app unprotected-or-unlockable.
        XCTAssertEqual(AppLockPolicy.authPolicy(biometricsAvailable: true),
                       .deviceOwnerAuthentication,
                       "spec #39: the unlock gate is .deviceOwnerAuthentication (passcode fallback included), not biometrics-only")
        XCTAssertEqual(AppLockPolicy.authPolicy(biometricsAvailable: false),
                       .deviceOwnerAuthentication,
                       "no biometry → same passcode-capable policy; never biometrics-only")
    }

    // MARK: 2 — lock state machine: cold launch + background → lock

    func testColdLaunchLocksImmediatelyWhenEnabled() async throws {
        let (engine, policy) = makeEngine(granted: true)
        // First activation after process start = cold launch, enabled → the
        // engine must present the lock and run the auth evaluation.
        await engine.appActivated()
        XCTAssertTrue(engine.isLocked, "cold launch with app-lock enabled MUST be locked")
        XCTAssertEqual(policy.requestedPolicies, [.deviceOwnerAuthentication],
                       "the evaluation run on cold launch must request the spec gate")
    }

    func testColdLaunchUnlockedWhenDisabled() async {
        let (engine, policy) = makeEngine(granted: true, enabled: false)
        await engine.appActivated()
        XCTAssertFalse(engine.isLocked, "app-lock off → cold launch stays unlocked")
        XCTAssertTrue(policy.requestedPolicies.isEmpty, "no evaluation at all when disabled")
    }

    func testBackgroundReturnRelocksAndLaunchOnlySkipsIt() async {
        // launchOnly=false: every background→foreground return re-locks.
        let (relock, _) = makeEngine(granted: true, launchOnly: false)
        await relock.appActivated()
        relock.appBackgrounded()
        await relock.appActivated()
        XCTAssertTrue(relock.isLocked,
                      "with default settings a background→foreground return re-locks")

        // launchOnly=true: only the cold launch demands unlock.
        let (launchOnly, _) = makeEngine(granted: true, launchOnly: true)
        await launchOnly.appActivated()
        await launchOnly.appActivated()
        XCTAssertFalse(launchOnly.isLocked,
                       "'require on launch only' does NOT re-lock mid-session returns")
    }

    // MARK: 3 — privacy shield: state-driven, set at .inactive (before snapshot)

    func testShieldRaisesOnBackgroundBeforeSnapshot() async {
        let (engine, _) = makeEngine(granted: true)
        await engine.appActivated()
        engine.appBackgrounded()
        XCTAssertTrue(engine.privacyShielded,
                      "shield must be up the moment the app leaves .active — the view layer renders it at .inactive so the app-switcher snapshot carries no content")
        engine.appBackgrounded()
        XCTAssertTrue(engine.privacyShielded, "repeated backgrounding is idempotent")

        // Failure keeps the lock (and the shield with it); success clears it.
        let (failEngine, _) = makeEngine(granted: false)
        await failEngine.appActivated()
        failEngine.appBackgrounded()
        await failEngine.appActivated()
        XCTAssertTrue(failEngine.privacyShielded, "failed unlock → still locked, shield stays")
        XCTAssertTrue(failEngine.isLocked, "failed unlock NEVER grants access")
    }

    func testSuccessClearsLockAndShield() async {
        let (engine, _) = makeEngine(granted: true)
        await engine.appActivated()
        engine.appBackgrounded()
        await engine.appActivated()
        XCTAssertTrue(engine.isLocked && engine.privacyShielded)
        await engine.appActivated()
        XCTAssertFalse(engine.isLocked)
        XCTAssertFalse(engine.privacyShielded,
                       "granted unlock clears BOTH the lock and the shield")
    }

    // MARK: 4 — lock window level: .alert + 1 (asserted as pure constant)

    func testLockWindowLevelConstant() {
        // The lock UI must sit in a dedicated window ABOVE everything so
        // sheets/fullScreenCovers can't bypass it. The level is defined once,
        // as a pure constant, and the window-hosting layer must consume it.
        // UIWindow.Level.alert is +1000 over .normal — asserting the exact
        // numeric keeps this file UIKit-free while pinning the level.
        XCTAssertEqual(AppLockEngine.lockWindowLevelRaw, 1_000.0 + 1.0,
                       "lock window = UIWindow.Level.alert + 1")
        XCTAssertEqual(AppLockEngine.lockWindowLevelRaw,
                       AppLockEngine.lockWindowLevelValue,
                       "the raw constant and the UIWindow.Level built from it must agree")
    }

    // MARK: 5 — Keychain: tokens WhenUnlockedThisDeviceOnly (spec #39)

    func testTokenKeychainAccessibilityIsWhenUnlockedThisDeviceOnly() {
        // Asserted via the helper's static configuration value (no Keychain
        // calls in tests): kSecAttrAccessibleWhenUnlockedThisDeviceOnly is
        // 1 (kSecAttrAccessibleAfterFirstUnlock is 2).
        XCTAssertEqual(AuthStore.keychainAccessibility,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                       "spec #39: tokens stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
    }

    // MARK: 6 — no retain cycles: the engine deallocs with its owner

    func testEngineDeallocsCleanlyNoRetainCycle() {
        // The engine holds only closures + an injected evaluator; nothing may
        // capture the engine itself (a lock singleton would also be fine, but
        // THIS type is instantiated per-owner, so it must not leak).
        weak var weakEngine: AppLockEngine?
        var policy: MockPolicy? = MockPolicy(granted: true)
        autoreleasepool {
            let engine = AppLockEngine(lockEnabled: { true },
                                       launchOnly: { false },
                                       policyEvaluator: policy!)
            weakEngine = engine
        }
        policy = nil
        XCTAssertNil(weakEngine,
                     "AppLockEngine must not retain itself (closures/evaluator are unowned deps)")
    }
}
