import SwiftUI

import DesignSystem

// MARK: - Item 12 (Voice M2) — the live-call in-chat voice bar
//
// Sits above the chat transcript while a CallKit call is live (UI Law §7:
// chat stays visible, compact mute/end pill). Observes the REAL
// CallManager — hidden entirely when `activeCallUUID` is nil, so the bar
// never fabricates a session.

struct V2InChatVoiceBar: View {
    /// The one app-side call manager (v1 singleton reused as the M2 call
    /// engine; §5.4 machine inside).
    @ObservedObject private var mgr = CallManager.shared

    var body: some View {
        // Interaction analysis: the bar exists only while a real call is
        // live; idle hides it completely (no fake UI).
        if mgr.activeCallUUID != nil {
            V2InChatVoiceOverlay(
                callState: mgr.callState,
                onToggleMute: { mgr.toggleMuteFromInChat() },
                onEnd: { mgr.endActiveCall() })
        }
    }
}
