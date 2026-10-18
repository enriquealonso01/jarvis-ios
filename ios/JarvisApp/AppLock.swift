import Foundation
import LocalAuthentication
import SwiftUI

/// App lock (Face ID), feature #39. Four pieces:
///   - AppLockPolicy: pure decision logic (unit-tested, no LAContext/Keychain).
///   - AppLockStore: Keychain-backed preferences (same store discipline as the
///     auth tokens — never UserDefaults; the lock state IS a security knob).
///   - AppLockController: scene-phase state machine + biometric prompt.
///   - AppLockEngine: the same rules with every dependency injected, so the
///     Item 7 QA suite can drive the machine headlessly.
///
/// Contract: lock on cold launch and (unless "require on launch only") on every
/// background→foreground return; shield content the moment the app leaves
/// .active (BEFORE the app-switcher snapshot). The gate is ALWAYS
/// `.deviceOwnerAuthentication` — biometrics evaluate inside that policy when
/// enrolled, and the passcode fallback is built in; the biometrics-only
/// variant is deliberately never the gate.

// MARK: - Pure policy (unit-testable)

enum AppLockPolicy {
    /// Activation kinds that can demand an unlock.
    enum Trigger: Equatable {
        case coldLaunch          // first activation after process start
        case foregroundReturn    // background → active mid-session
        case manual              // explicit re-lock (future: panic button)
    }

    /// The mandated unlock gate for feature #39: `.deviceOwnerAuthentication`
    /// evaluates biometrics when enrolled AND falls back to the device
    /// passcode in one policy — with no enrollment it still gates via
    /// passcode instead of leaving the app unprotected. The biometrics-only
    /// variant is deliberately NOT the gate.
    static func authPolicy(biometricsAvailable: Bool) -> LAPolicy {
        _ = biometricsAvailable // biometry presence is irrelevant to the gate
        return .deviceOwnerAuthentication
    }

    /// Should the lock screen be presented for this activation?
    static func lockRequired(enabled: Bool, launchOnly: Bool, trigger: Trigger) -> Bool {
        guard enabled else { return false }
        switch trigger {
        case .coldLaunch, .manual:
            return true
        case .foregroundReturn:
            // "Require on launch" mode intentionally does NOT re-lock on every
            // foreground return — only cold launches demand biometrics.
            return !launchOnly
        }
    }
}

/// Protocol seam so the lock state machine is testable without LAContext.
/// @MainActor: every implementor (the real AppLockController bridge and the
/// QA suite's MockPolicy) already lives on the main actor, and constraining
/// the protocol keeps `policyEvaluator` Sendable-safe across the `await` in
/// AppLockEngine.appActivated (Swift 6: 'sending ... risks causing data races'
/// without it).
@MainActor
protocol AppLockPolicyEvaluating {
    func evaluate(_ policy: LAPolicy) async -> Bool
}

/// `clock` is unused today (no timeout-based relock is specced) but kept on
/// the contract so a future idle-timeout can be pinned by these same tests.
protocol AppLockClock {
    var now: Date { get }
}

struct SystemAppLockClock: AppLockClock {
    var now: Date { Date() }
}

// MARK: - Testable engine (pure-logic, fully injected)

/// The same trigger/policy rules the scene-phase controller enforces, but
/// with every outside dependency (enablement flags, policy evaluation)
/// injected so the Item 7 QA suite can drive every transition headlessly.
/// The view layer renders `privacyShielded` the moment scenePhase leaves
/// `.active` (i.e. at `.inactive`, BEFORE the app-switcher snapshot) and hosts
/// `LockScreenView` in a dedicated window at `lockWindowLevelRaw` so
/// sheets/covers can't bypass it.
@MainActor
final class AppLockEngine: ObservableObject {
    /// UIWindow.Level.alert + 1 (raw so tests need no UIKit). The dedicated
    /// lock window is created at this level; alert already floats above all
    /// sheets/covers, +1 keeps it above any peer alert. `nonisolated` so the
    /// nonisolated LockWindowHost default-arg can read it (Swift 6: default
    /// values evaluate in the caller's isolation, and its callers are
    /// nonisolated).
    nonisolated static let lockWindowLevelRaw: CGFloat = 1_000 + 1
    /// The same level expressed the way the window-hosting layer consumes it.
    nonisolated static let lockWindowLevelValue: CGFloat = 1_000 + 1

    @Published private(set) var isLocked = false
    @Published private(set) var privacyShielded = false

    private var hasActivatedOnce = false
    private let lockEnabled: () -> Bool
    private let launchOnly: () -> Bool
    private let policyEvaluator: AppLockPolicyEvaluating
    let clock: AppLockClock

    init(lockEnabled: @escaping () -> Bool,
         launchOnly: @escaping () -> Bool,
         policyEvaluator: AppLockPolicyEvaluating,
         clock: AppLockClock = SystemAppLockClock()) {
        self.lockEnabled = lockEnabled
        self.launchOnly = launchOnly
        self.policyEvaluator = policyEvaluator
        self.clock = clock
    }

    /// Called at scenePhase .background (and harmless at .inactive): raise the
    /// shield BEFORE iOS takes the app-switcher snapshot.
    func appBackgrounded() {
        privacyShielded = true
    }

    /// Called at scenePhase .active: cold launch locks; mid-session returns
    /// re-lock unless "require on launch only" is set; a failed evaluation
    /// keeps the lock up.
    func appActivated() async {
        let trigger: AppLockPolicy.Trigger = hasActivatedOnce ? .foregroundReturn : .coldLaunch
        hasActivatedOnce = true
        guard AppLockPolicy.lockRequired(enabled: lockEnabled(),
                                         launchOnly: launchOnly(),
                                         trigger: trigger) else {
            privacyShielded = false
            return
        }
        isLocked = true
        if await policyEvaluator.evaluate(AppLockPolicy.authPolicy(biometricsAvailable: true)) {
            isLocked = false
            privacyShielded = false
        }
    }
}

// MARK: - Keychain-backed preferences

@MainActor
final class AppLockStore {
    static let shared = AppLockStore()

    private let enabledKey = "jarvis.lock.enabled"
    private let launchOnlyKey = "jarvis.lock.requireOnLaunch"

    /// App lock master switch. Keychain value "1" = on; absent = off.
    var lockEnabled: Bool {
        get { AuthStore.loadString(enabledKey) == "1" }
        set { setKey(enabledKey, newValue) }
    }

    /// "Require on launch" option: only cold launches demand unlock; mid-session
    /// foreground returns don't re-lock. Absent = false (lock on every return).
    var requireOnLaunchOnly: Bool {
        get { AuthStore.loadString(launchOnlyKey) == "1" }
        set { setKey(launchOnlyKey, newValue) }
    }

    private func setKey(_ key: String, _ value: Bool) {
        if value {
            AuthStore.saveString(key, "1")
        } else {
            AuthStore.deleteKey(key)
        }
    }
}

// MARK: - Scene-phase controller

@MainActor
final class AppLockController: ObservableObject {
    static let shared = AppLockController()

    /// Lock screen (dedicated lock window) visibility. Internal set: the
    /// SwiftUI binding needs to write it when the window is dismissed.
    @Published var isLocked = false
    /// Privacy blur/cover while backgrounded — applied IMMEDIATELY on
    /// background (before iOS takes the app switcher snapshot).
    @Published private(set) var privacyShielded = false
    @Published var lastError: String?

    private var hasActivatedOnce = false
    private var unlockInFlight = false
    /// Shared host for the dedicated lock window. Static (not an instance
    /// member) because the ViewModifier that drives it is a value type that
    /// SwiftUI recreates on every parent body evaluation — the window book-
    /// keeping must survive those recreations exactly like `shared` does.
    static let lockWindow = LockWindowHost()

    func appBackgrounded() {
        privacyShielded = true
    }

    func appActivated() {
        // The system biometric dialog cycles scenePhase (inactive → active).
        // Re-entry while the lock is up must NOT restart the policy machine —
        // stay locked until evaluatePolicy actually grants.
        guard !isLocked else { return }
        let trigger: AppLockPolicy.Trigger = hasActivatedOnce ? .foregroundReturn : .coldLaunch
        hasActivatedOnce = true
        if AppLockPolicy.lockRequired(enabled: AppLockStore.shared.lockEnabled,
                                      launchOnly: AppLockStore.shared.requireOnLaunchOnly,
                                      trigger: trigger) {
            isLocked = true
            authenticate()
        } else {
            privacyShielded = false
        }
    }

    /// Unlock attempt from the lock screen's button (first auto-prompt may have
    /// been cancelled or the app may have been launched into the background).
    func authenticate() {
        guard !unlockInFlight else { return }
        unlockInFlight = true
        lastError = nil
        Task {
            let granted = await Self.biometricUnlock(reason: "Unlock JARVIS")
            unlockInFlight = false
            if granted {
                isLocked = false
                privacyShielded = false
                lastError = nil
            } else {
                // Cancellation and mismatches both land here; the lock screen
                // stays up with its manual Unlock button.
                lastError = "Didn't unlock — try again."
            }
        }
    }

    /// Evaluate the app-lock policy off the main actor. The LAContext is
    /// created INSIDE this nonisolated function on purpose: LAContext is not
    /// Sendable, so constructing it inside the Task avoids every cross-actor
    /// capture (same trap class as the CallKit boxing pattern, sidestepped).
    nonisolated private static func biometricUnlock(reason: String) async -> Bool {
        let context = LAContext()
        var evalError: NSError?
        // The gate is ALWAYS .deviceOwnerAuthentication (spec #39): biometrics
        // evaluate inside it when enrolled, and the passcode fallback is part
        // of the same policy. The canEvaluatePolicy probe only decides whether
        // a prompt is even worth raising (no auth method at all → keep locked).
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication, error: &evalError) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: reason)
        } catch {
            return false
        }
    }
}

// MARK: - Lock window host (dedicated UIWindow, sheets can't bypass)

/// Hosts `LockScreenView` in its OWN UIWindow at UIWindow.Level.alert + 1, so
/// no sheet/fullScreenCover/peer alert can ever cover the lock. `isLocked`
/// drives creation/removal; the hidden-until-shown dance avoids a black flash
/// on iOS 17+.
final class LockWindowHost {
    private weak var window: UIWindow?
    private let level: CGFloat

    init(level: CGFloat = AppLockEngine.lockWindowLevelRaw) {
        self.level = level
    }

    /// Present (or keep) the lock window; tear it down on unlock.
    func setIsLocked(_ locked: Bool) {
        if !locked {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let lockWindow = UIWindow(windowScene: scene)
        lockWindow.windowLevel = UIWindow.Level(level)
        lockWindow.rootViewController = UIHostingController(rootView: LockScreenView())
        lockWindow.isHidden = false
        window = lockWindow
    }
}

// MARK: - Lock screen

struct LockScreenView: View {
    @ObservedObject private var lock = AppLockController.shared

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.jarvisAccent)
            Text("JARVIS is locked")
                .font(.title2.bold())
            Text("Unlock with Face ID (or your passcode).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let err = lock.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                lock.authenticate()
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
        .padding(20)
    }
}

/// Content cover shown while backgrounded so the app-switcher snapshot carries
/// no session data. A material overlay beats .blur(radius:) here: it fully
/// hides text AND visually persists in the snapshot.
struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.jarvisAccent)
                Text("JARVIS")
                    .font(.title3.bold())
            }
        }
    }
}
