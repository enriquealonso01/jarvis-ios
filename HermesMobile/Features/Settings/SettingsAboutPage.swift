import SwiftUI

/// The app's version and build, and the credit to Hermex, the open-source app JARVIS is built on.
struct SettingsAboutPage: View {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
    }

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "Version"), value: Self.appVersion)
                LabeledContent(String(localized: "Build"), value: appBuild)
            }

            Section {
                Text("JARVIS is Enrique's personal assistant app.")
                Link(destination: AppConfig.hermexURL) {
                    Text("Built on Hermex by Uzair Ansar, used under the MIT License.")
                }
                .accessibilityIdentifier("about.hermexAttribution")
                Link(destination: URL(string: "https://github.com/livekit/components-js")!) {
                    Text(verbatim: "The voice screen's Aura visualizer is a port of LiveKit Agents UI (Copyright LiveKit, Inc.), used under the Apache License 2.0.")
                }
                .accessibilityIdentifier("about.livekitAttribution")
                Link(destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!) {
                    Text(verbatim: "Apache License 2.0")
                }
                .accessibilityIdentifier("about.apacheLicense")
            } header: {
                Text("Credits")
            }
        }
        .settingsPage(String(localized: "About JARVIS"))
    }
}

/// Maintainer tools: Debug-only helpers, and the browser sign-in testing toggle (#708) in Debug
/// and Hermex Branch builds. Not localized.
struct SettingsDeveloperPage: View {
    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        HermesBrowserSignIn.offersTestingToggle
        #endif
    }

    /// The testing toggle `HermesBrowserSignIn.isForcedForTesting` reads.
    @AppStorage(HermesBrowserSignIn.forcedKey) private var forcesBrowserSignIn = false

    var body: some View {
        List {
            #if DEBUG
            Section {
                Button(String(localized: "Reset rating prompt state")) {
                    RatingPromptState.shared.reset()
                }

                NavigationLink {
                    ProviderGlyphGalleryView()
                } label: {
                    SettingsLabel(title: "Provider Glyphs", systemImage: "square.grid.2x2")
                }
            } footer: {
                Text(verbatim: "Debug builds only.")
            }
            #endif

            if HermesBrowserSignIn.offersTestingToggle {
                Section {
                    Toggle(isOn: $forcesBrowserSignIn) { Text(verbatim: "Browser sign-in on password hosts") }
                } footer: {
                    Text(verbatim: "Hermes hosts that offer a password sign in through the browser instead, the next time a sign-in form opens. Debug and JARVIS Branch builds only.")
                }
            }
        }
        .settingsPage("Developer")
    }
}
