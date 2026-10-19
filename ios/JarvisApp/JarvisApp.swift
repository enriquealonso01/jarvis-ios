import SwiftUI
import UIKit

/// Bootstrap entry point: the screenshot lane (DEBUG + -SCREENSHOT_SEED) must
/// seed Keychain/UserDefaults BEFORE AuthStore.shared and ServerConfig.shared
/// initialize (their @Published state snapshots those stores at init), so the
/// seed runs ahead of the App struct's own synthesized main. Production path
/// is untouched — this is a pure pass-through when the lane is inactive.
@main
struct JarvisAppMain {
    // Main.main() runs on the main thread before any App state exists, so the
    // @MainActor seed call is legal here via MainActor.assumeIsolated.
    static func main() {
        #if DEBUG
        if ScreenshotSeed.isActive {
            MainActor.assumeIsolated {
                ScreenshotSeed.bootstrapIfNeeded()
            }
        }
        #endif
        JarvisApp.main()
    }
}

struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore.shared
    @StateObject private var server = ServerConfig.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // v2 (Item 1): open the GRDB local store at launch so the offline-first
        // source of truth is warm before any view asks for it. Feature-flagged
        // (V2_LOCAL_STORE): v1 flows (SessionsView etc.) don't read it yet, so
        // a failure must never block v1 — log and continue with nil.
        if V2Flags.localStore {
            LocalStoreBootstrap.shared.warmUp()
        }
        #if DEBUG
        // Screenshot lane: fire the GRDB seed as this init's main-actor task.
        // JarvisApp.init runs BEFORE the view hierarchy builds, so this task
        // is enqueued ahead of V2SidebarShell's .task restore — the seeded
        // sidebar state and selection therefore win the restore. Fire-and-
        // forget: no main-thread blocking anywhere. Inert without
        // -SCREENSHOT_SEED.
        if ScreenshotSeed.isActive {
            Task { await ScreenshotSeed.seedStore() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if server.configured {
                    if auth.isAuthed {
                        if V2Flags.sidebarShell {
                            // v2 Item 3: ChatGPT-grammar sidebar shell hosts
                            // the chat surface (v1 transcript rebuild is Item 4).
                            V2SidebarShell(store: LocalStoreBootstrap.shared.store)
                        } else {
                            RootTabView()
                        }
                    } else {
                        LoginView()
                    }
                } else {
                    SetupView()
                }
            }
            .modifier(AppLockGate())
            .preferredColorScheme(AppTheme.preferredColorScheme)
            .tint(.jarvisAccent)
        }
    }
}

/// Face ID app lock as a ViewModifier: an `App` struct can't observe
/// ObservableObjects, so the isLocked-driven fullScreenCover MUST live in a
/// real View (this modifier) that observes AppLockController — otherwise the
/// cover never presents when isLocked flips.
private struct AppLockGate: ViewModifier {
    @ObservedObject private var lock = AppLockController.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // Lock on cold launch / foreground return; raise the privacy
            // shield the moment the app leaves .active — at .inactive, BEFORE
            // iOS snapshots the app switcher (.background is too late for the
            // snapshot; .background is also handled, harmless/idempotent).
            // Auth is left on purpose — the lock screen also covers the
            // login view (tokens are gone post-logout, but a lock never hurts).
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    lock.appBackgrounded()
                case .active:
                    lock.appActivated()
                @unknown default:
                    break
                }
            }
            // The lock screen lives in its own window above everything, so a
            // sheet can never be presented "over" the lock and bypass it.
            .onChange(of: lock.isLocked) { _, locked in
                AppLockController.lockWindow.setIsLocked(locked)
            }
            .overlay {
                if lock.privacyShielded {
                    PrivacyShieldView().transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: lock.privacyShielded)
    }
}

/// Root tab bar, sessions-first: Sessions / Calls / More.
struct RootTabView: View {
    @StateObject private var caps = CapabilityRegistry.shared
    /// Selection is bound so widget deep links (jarvis://…) can switch tabs.
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            SessionsView()
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)
            ProjectsManagerView()
                .tabItem { Label("Projects", systemImage: "folder.fill") }
                .tag(1)
            CallsView()
                .tabItem { Label("Calls", systemImage: "phone.fill") }
                .tag(2)
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(3)
        }
        // Home-screen widget taps land on the matching tab (widgets.swift
        // emits jarvis://sessions, jarvis://calls, jarvis://more, jarvis://status).
        .onOpenURL { url in
            switch url.host {
            case "sessions": tab = 0
            case "projects": tab = 1
            case "calls": tab = 2
            case "more", "status": tab = 3
            default: break
            }
        }
        // Reaching this view means isAuthed just flipped true (password login,
        // manual token) OR the app cold-launched already authed. Either way,
        // re-kick /register with the stored PushKit token: on a fresh install
        // the launch-time retry loop exhausted BEFORE login existed, so this
        // is the call that actually lands the device registration (day-one
        // "ring this phone"). Idempotent on the server; every attempt re-reads
        // the current access token.
        .task { await CallManager.shared.retryDeviceRegistration() }
    }
}

/// PushKit must be registered from launch (cold VoIP push delivery).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CallManager.shared.registerVoIP()
        return true
    }
}

// MARK: - JARVIS palette

extension Color {
    /// JARVIS arc-reactor gold — matches the CC orb accent.
    static let jarvisAccent = Color(red: 1.0, green: 0.78, blue: 0.35)
    static let jarvisCard = Color(red: 0.11, green: 0.12, blue: 0.15)
}

/// Liquid-Glass-style card container. On iOS 26+ uses the real `.glassEffect`
/// modifier; earlier OSes get a matching material fallback so the app builds
/// and degrades gracefully.
struct GlassCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            content
                .padding(16)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
        } else {
            content
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.jarvisCard.opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }
}

#Preview {
    GlassCard { Text("Gateway").foregroundStyle(.white) }
        .background(Color.black)
}
