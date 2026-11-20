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
            JarvisClientLog.record("quickVoice", "transcribe failed: \(HermesConnectionLog.reason(error))")
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

        let message = VoiceNoteText.message(transcript: transcript)
        // A failure before the prompt went out is tried once more on a fresh socket; once
        // it may have reached JARVIS it is never sent twice.
        var attempt = await openChat(target: target, message: message, connection: connection)
        if case .beforePrompt = attempt {
            try? await Task.sleep(for: .milliseconds(1500))
            attempt = await openChat(target: target, message: message, connection: connection)
        }
        switch attempt {
        case .sent(let key):
            VoiceNoteLocalStore.shared.save(audio, forMessageText: message)
            guard let url = HermesDeepLink.sessionURL(
                for: HermesSessionDestination(server: server, profile: target, key: key)) else {
                return .failed(String(localized: "The chat could not be opened."))
            }
            return .sent(url)
        case .beforePrompt(let reason), .afterPrompt(let reason):
            return .failed(reason)
        }
    }

    private enum ChatAttempt {
        /// The new chat's stored key.
        case sent(String)
        /// Failed before `prompt.submit` was sent: safe to try again.
        case beforePrompt(String)
        /// Failed once the prompt may have reached JARVIS: never retried.
        case afterPrompt(String)
    }

    /// Opens a new chat on `target` and submits `message`, logging the step and reason of a
    /// failure (`JarvisClientLog`, category `quickVoice`).
    @MainActor private static func openChat(target: String, message: String,
                                            connection: HermesConnection) async -> ChatAttempt {
        let client = BotClient(http: connection)
        defer { client.close() }
        do {
            try await client.connect()
        } catch {
            JarvisClientLog.record("quickVoice", "connect failed: \(HermesConnectionLog.reason(error))")
            return .beforePrompt(String(localized: "JARVIS could not be reached."))
        }
        let created: BotJSON
        do {
            created = try await client.call(.sessionNew(profile: target))
        } catch {
            JarvisClientLog.record("quickVoice", "session.create failed: \(HermesConnectionLog.reason(error))")
            return .beforePrompt(String(localized: "The chat could not be opened."))
        }
        guard let key = created["stored_session_id"].text, !key.isEmpty,
              let runtime = created["session_id"].text, !runtime.isEmpty else {
            JarvisClientLog.record("quickVoice", "session.create answered without its ids")
            return .beforePrompt(String(localized: "The chat could not be opened."))
        }
        do {
            let submitted = try await client.call(.promptSubmit(sessionID: runtime, text: message))
            if submitted["status"].text == "rejected" {
                JarvisClientLog.record("quickVoice", "prompt.submit rejected")
                return .afterPrompt(String(localized: "The note could not be sent."))
            }
            return .sent(key)
        } catch {
            JarvisClientLog.record("quickVoice", "prompt.submit failed: \(HermesConnectionLog.reason(error))")
            return .afterPrompt(String(localized: "The note could not be sent."))
        }
    }
}
