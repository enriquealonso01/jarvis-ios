import LocalAuthentication
import XCTest
@testable import JarvisApp

/// Item 7 TESTER QA — feature #39 (V2-PLAN.md): Face ID app lock + privacy
/// shield, P0. Pure logic only (no UIKit; the only LA-adjacent surface touched
/// is `LAPolicy`, an enum, via the same pure mapping the app itself uses).
///
/// Seams the implementation exposes (protocol-injected, per task brief):
///   - `AppLockPolicy.lockRequired(enabled:launchOnly:trigger:)` — pure.
///   - `AppLockPolicy.authPolicy(biometricsAvailable:) -> LAPolicy` — pure
///     mapping; .deviceOwnerAuthentication (which INCLUDES biometrics when
///     enrolled) is the mandated gate; biometrics-only is never the gate.
///   - `AppLockEngine` — a @MainActor ObservableObject with protocol-injected
///     `AppLockPolicyEvaluating` (evaluate) + `AppLockClock` (now), driving
///     `appBackgrounded()` / `appActivated()` with the same state machine the
///     real controller runs.
///   - `AuthStore.keychainAccessibility` — the static configuration value
///     passed as kSecAttrAccessible; the spec mandates
///     kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
///
/// NOTE on observation points: `AppLockEngine.appActivated()` unlocks
/// SYNCHRONOUSLY when the injected evaluator grants — so "locked after
/// activation" is only observable with a denying evaluator (the lock stays up
/// for the manual-retry path). The real controller behaves identically
/// (AppLockController.authenticate() only clears isLocked on a grant).
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

    func testColdLaunchLocksAndRunsOnlyTheSpecGate() async {
        // Denying evaluator = the Face ID dialog was dismissed/failed: the
        // cold launch MUST still have raised the lock, and the ONLY policy
        // the machine may request is the spec gate (never biometrics-only).
        let (engine, policy) = makeEngine(granted: false)
        await engine.appActivated()
        XCTAssertTrue(engine.isLocked, "cold launch with app-lock enabled MUST lock (failed first attempt keeps the lock up)")
        XCTAssertEqual(policy.requestedPolicies, [.deviceOwnerAuthentication],
                       "the evaluation run on cold launch must request the spec gate")
        XCTAssertFalse(policy.requestedPolicies.contains(.deviceOwnerAuthenticationWithBiometrics),
                       "biometrics-only must never be requested as the gate")
    }

    func testColdLaunchSuccessfulUnlockClearsLock() async {
        // Granted evaluator = user passed Face ID: cold launch ends unlocked
        // with no shield (the engine unlocks synchronously inside activation,
        // exactly like the scene-phase controller's authenticate() path).
        let (engine, policy) = makeEngine(granted: true)
        await engine.appActivated()
        XCTAssertFalse(engine.isLocked, "granted cold-launch unlock leaves the app unlocked")
        XCTAssertFalse(engine.privacyShielded)
        XCTAssertEqual(policy.requestedPolicies, [.deviceOwnerAuthentication],
                       "even a granting flow runs the spec gate, not biometrics-only")
    }

    func testColdLaunchUnlockedWhenDisabled() async {
        let (engine, policy) = makeEngine(granted: true, enabled: false)
        await engine.appActivated()
        XCTAssertFalse(engine.isLocked, "app-lock off → cold launch stays unlocked")
        XCTAssertTrue(policy.requestedPolicies.isEmpty, "no evaluation at all when disabled")
    }

    // MARK: 3 — background→foreground return re-locks unless launch-only

    func testBackgroundReturnRelocksWhenLaunchOnlyOff() async {
        // launchOnly=false (default): every background→foreground return
        // demands the gate again. With a denying evaluator the lock stays up
        // and the gate has now run TWICE (cold launch + return).
        let (engine, policy) = makeEngine(granted: false, launchOnly: false)
        await engine.appActivated()
        engine.appBackgrounded()
        await engine.appActivated()
        XCTAssertTrue(engine.isLocked,
                      "with default settings a background→foreground return re-locks")
        XCTAssertEqual(policy.requestedPolicies.count, 2,
                       "gate ran once for cold launch and once for the foreground return")
    }

    func testLaunchOnlySkipsForegroundReturnRelock() async {
        // launchOnly=true: only the cold launch demands unlock; the mid-session
        // return must not re-lock and must not even consult the evaluator.
        let (engine, policy) = makeEngine(granted: true, launchOnly: true)
        await engine.appActivated()
        engine.appBackgrounded()
        engine.appBackgrounded()
        await engine.appActivated()
        XCTAssertFalse(engine.isLocked,
                       "'require on launch only' does NOT re-lock mid-session returns")
        XCTAssertEqual(policy.requestedPolicies.count, 1,
                       "the foreground return must not run the evaluator again")
    }

    // MARK: 4 — privacy shield: state-driven, set at .inactive (before snapshot)

    func testShieldRaisesOnBackgroundBeforeSnapshot() async {
        let (engine, _) = makeEngine(granted: true)
        await engine.appActivated()
        engine.appBackgrounded()
        XCTAssertTrue(engine.privacyShielded,
                      "shield must be up the moment the app leaves .active — the view layer renders it at .inactive so the app-switcher snapshot carries no content")
        engine.appBackgrounded()
        XCTAssertTrue(engine.privacyShielded, "repeated backgrounding is idempotent")
    }

    func testFailedUnlockNeverGrantsAndKeepsShield() async {
        let (engine, _) = makeEngine(granted: false)
        await engine.appActivated()
        engine.appBackgrounded()
        await engine.appActivated()
        XCTAssertTrue(engine.isLocked, "failed unlock NEVER grants access")
        XCTAssertTrue(engine.privacyShielded, "failed unlock → still locked, shield stays")
    }

    func testSuccessfulUnlockClearsLockAndShield() async {
        // Start with a denying evaluator (cold launch locks), raise the shield
        // by backgrounding, then let the evaluator grant on the foreground
        // return: BOTH the lock and the shield must clear together.
        let (engine, policy) = makeEngine(granted: false)
        await engine.appActivated()
        engine.appBackgrounded()
        XCTAssertTrue(engine.isLocked && engine.privacyShielded)
        policy.granted = true
        await engine.appActivated()
        XCTAssertFalse(engine.isLocked)
        XCTAssertFalse(engine.privacyShielded,
                       "granted unlock clears BOTH the lock and the shield")
    }

    // MARK: 5 — lock window level: .alert + 1 (asserted as pure constant)

    func testLockWindowLevelConstant() {
        // The lock UI must sit in a dedicated window ABOVE everything so
        // sheets/fullScreenCovers can't bypass it. The level is defined once,
        // as a pure constant, and the window-hosting layer (LockWindowHost)
        // consumes it. UIWindow.Level.alert is +1000 over .normal — asserting
        // the exact numeric keeps this file UIKit-free while pinning the level.
        XCTAssertEqual(AppLockEngine.lockWindowLevelRaw, 1_000.0 + 1.0,
                       "lock window = UIWindow.Level.alert + 1")
        XCTAssertEqual(AppLockEngine.lockWindowLevelRaw,
                       AppLockEngine.lockWindowLevelValue,
                       "the raw constant and the UIWindow.Level built from it must agree")
    }

    // MARK: 6 — Keychain: tokens WhenUnlockedThisDeviceOnly (spec #39)

    func testTokenKeychainAccessibilityIsWhenUnlockedThisDeviceOnly() {
        // Asserted via the helper's static configuration value (no Keychain
        // calls in tests): kSecAttrAccessibleWhenUnlockedThisDeviceOnly is
        // 1 (kSecAttrAccessibleAfterFirstUnlock is 2).
        XCTAssertEqual(AuthStore.keychainAccessibility,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                       "spec #39: tokens stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
    }

    // MARK: 7 — no retain cycles: the engine deallocs with its owner

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
