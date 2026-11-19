import Foundation

/// Quick Voice's speech-to-text: the same `POST /api/audio/transcribe` dictation uses
/// (`HermesTranscription`), kept separate so Quick Voice owns its own connection's
/// deadline and error copy. A 2xx without words is silence (an empty transcript), not
/// an error; a refusal the host explains in `detail`, or a proxy status, is.
enum QuickVoiceTranscription {
    /// The recorder writes AAC in an `.m4a` container, which the host keeps as `.m4a`.
    static let mimeType = "audio/m4a"

    /// Transcribes `audio` on `profile` over `connection`'s sign-in. Throws on a refusal
    /// or transport failure; returns the words (possibly empty) on a 2xx.
    @MainActor static func transcribe(_ audio: Data, profile: String,
                                      on connection: HermesConnection) async throws -> String {
        let request = try HermesREST.transcribe(
            profile: profile,
            dataURL: "data:\(mimeType);base64," + audio.base64EncodedString(),
            mimeType: mimeType
        ).request(base: connection.connection.address)
        let (body, status) = try await connection.reply(request, deadline: .provisioning)
        return try transcript(body, status)
    }

    /// `{ok, transcript}` as the host sends it. `ok: false` on a 2xx is a provider
    /// failure the host explains in `detail`, so it throws rather than reading as silence.
    static func transcript(_ body: Data, _ status: Int) throws -> String {
        let json = try? JSONDecoder().decode(BotJSON.self, from: body)
        switch status {
        case 200..<300:
            if json?["ok"].flag == false { throw QuickVoiceError.transcriptionRefused }
            return json?["transcript"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case 403, 502...504, 520...530:
            throw BotFailure.rejected(status)
        default:
            if let detail = json?["detail"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty, detail != "Not authenticated" {
                throw QuickVoiceError.transcriptionRefused
            }
            throw APIError.http(statusCode: status, body: String(data: body, encoding: .utf8))
        }
    }
}
