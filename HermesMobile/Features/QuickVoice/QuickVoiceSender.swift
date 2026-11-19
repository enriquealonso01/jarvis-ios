import Foundation

/// Sends one Quick Voice clip the way a composer voice note that opens a new chat goes
/// (`ChatViewModel.drainVoiceNoteOutbox` → `routeFirstHermesPrompt`, build 99 / PR #37):
/// transcribe once, ask the box which Bot owns the words (`JarvisBotRouter`,
/// `POST /bridge/route`, asked with the words alone), open a new chat on that Profile and
/// submit the `🎤 …` text (`prompt.submit`). The clip itself never leaves the phone
/// (Enrique's rule, 2026-10-21): it is kept in `VoiceNoteLocalStore` under the sent text,
/// as every voice note's is, so the chat's audio bubble can play it.
enum QuickVoiceSender {
    /// The live path: the JARVIS server's saved sign-in and the app's shared connection
    /// pool, which the `audio` background mode keeps usable while the phone is locked.
    @MainActor static func deliver(_ audio: Data,
                                   profile: String = JarvisBotRouting.generalProfile) async -> QuickVoiceController.Outcome {
        let server = JarvisServer.address
        guard let saved = try? BotConnectionStore().load(server: server) else {
            return .failed(String(localized: "JARVIS is not signed in."))
        }
        return await deliver(audio, profile: profile, server: server, saved: saved,
                             connection: HermesConnections.shared.connection(for: saved, server: server))
    }

    /// Tests reach this seam: an explicit server, sign-in and connection, so nothing
    /// touches the Keychain or the shared pool.
    @MainActor static func deliver(_ audio: Data, profile: String, server: URL, saved: BotConnection,
                                   connection: HermesConnection) async -> QuickVoiceController.Outcome {
        let transcript: String
        do {
            transcript = try await QuickVoiceTranscription.transcribe(audio, profile: profile, on: connection)
        } catch {
            return .failed(String(localized: "The recording could not be transcribed."))
        }
        guard !transcript.isEmpty else {
            return .failed(String(localized: "Nothing was said."))
        }
        // Bot routing asks with the words alone — no 🎤 marker — and only a general
        // chat's first message asks (`JarvisBotRouting.routes`).
        let reply = JarvisBotRouting.routes(profile: profile)
            ? await JarvisBotRouter.route(transcript, current: profile) : nil
        let target = JarvisBotRouting.destination(reply, current: profile) ?? profile

        let client = BotClient(http: connection)
        defer { client.close() }
        do {
            guard (try? await client.connect()) != nil else {
                return .failed(String(localized: "JARVIS could not be reached."))
            }
            let created = try await client.call(.sessionNew(profile: target))
            guard let key = created["stored_session_id"].text, !key.isEmpty,
                  let runtime = created["session_id"].text, !runtime.isEmpty else {
                return .failed(String(localized: "The chat could not be opened."))
            }
            let message = VoiceNoteText.message(transcript: transcript)
            let submitted = try await client.call(.promptSubmit(sessionID: runtime, text: message))
            if submitted["status"].text == "rejected" {
                return .failed(String(localized: "The note could not be sent."))
            }
            VoiceNoteLocalStore.shared.save(audio, forMessageText: message)
            guard let url = HermesDeepLink.sessionURL(
                for: HermesSessionDestination(server: server, profile: target, key: key)) else {
                return .failed(String(localized: "The chat could not be opened."))
            }
            return .sent(url)
        } catch {
            return .failed(String(localized: "The note could not be sent."))
        }
    }
}
