import Foundation
import LocalAuthentication
import SwiftUI

/// App lock (Face ID). Three pieces:
///   - AppLockPolicy: pure decision logic (unit-tested, no LAContext/Keychain).
///   - AppLockStore: Keychain-backed preferences (same store discipline as the
///     auth tokens — never UserDefaults; the lock state IS a security knob).
///   - AppLockController: scene-phase state machine + biometric prompt.
///
/// Contract: lock on cold launch and (unless "require on launch only") on every
/// background→foreground return; blur content the moment the app backgrounds.
/// Policy chain per spec: .deviceOwnerAuthenticationWithBiometrics first, and
/// when biometrics are unavailable/enrolled-out/locked-out fall back to
/// .deviceOwnerAuthentication (passcode) — never leave the app either
/// unprotected or permanently locked.

// MARK: - Pure policy (unit-testable)

enum AppLockPolicy {
    enum Trigger: Equatable {
        case coldLaunch          // first activation after process start
        case foregroundReturn    // background → active mid-session
        case manual              // explicit re-lock (future: panic button)
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

    /// LA policy with the mandated fallback: biometrics when available,
    /// passcode otherwise. Extracted so the mapping is pinned by a test.
    static func authPolicy(biometricsAvailable: Bool) -> LAPolicy {
        biometricsAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
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

    /// Lock screen (fullScreenCover) visibility. Internal set: the SwiftUI
    /// binding needs to write it when the cover is dismissed.
    @Published var isLocked = false
    /// Privacy blur/cover while backgrounded — applied IMMEDIATELY on
    /// background (before iOS takes the app switcher snapshot).
    @Published private(set) var privacyShielded = false
    @Published var lastError: String?

    private var hasActivatedOnce = false
    private var unlockInFlight = false

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

    /// Evaluate the app-lock policy chain off the main actor. The LAContext is
    /// created INSIDE this nonisolated function on purpose: LAContext is not
    /// Sendable, so constructing it inside the Task avoids every cross-actor
    /// capture (same trap class as the CallKit boxing pattern, sidestepped).
    nonisolated private static func biometricUnlock(reason: String) async -> Bool {
        let context = LAContext()
        var evalError: NSError?
        var policy = AppLockPolicy.authPolicy(
            biometricsAvailable: context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, error: &evalError))
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            // One retry through the FALLBACK policy when biometrics failed for
            // a reason a passcode can still satisfy (e.g. biometry lockout).
            if policy == .deviceOwnerAuthenticationWithBiometrics {
                policy = .deviceOwnerAuthentication
                do {
                    return try await context.evaluatePolicy(policy, localizedReason: reason)
                } catch { return false }
            }
            return false
        }
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
