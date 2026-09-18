import SwiftUI
import UIKit

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore.shared
    @StateObject private var server = ServerConfig.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if server.configured {
                    if auth.isAuthed {
                        RootTabView()
                    } else {
                        LoginView()
                    }
                } else {
                    SetupView()
                }
            }
            .preferredColorScheme(.dark)
            .tint(.jarvisAccent)
        }
    }
}

/// Root tab bar: Home / Chats / Secrets / Calls.
struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "circle.grid.2x2.fill") }
            ProjectsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
            SecretsView()
                .tabItem { Label("Secrets", systemImage: "key.fill") }
            CallsView()
                .tabItem { Label("Calls", systemImage: "phone.fill") }
        }
    }
}

/// PushKit must be registered from launch (cold VoIP push delivery).
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

#Preview {
    GlassCard { Text("Gateway").foregroundStyle(.white) }
        .background(Color.black)
}
