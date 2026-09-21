import SwiftUI

/// In-session feedback: "something is not going correctly" — lands with
/// JARVIS via the push bridge, which notifies JARVIS (WhatsApp) and stores
/// the report. POST /feedback on the bridge (dashboard Bearer auth).
struct FeedbackSheet: View {
    let sessionId: String
    /// Optional anchor: the message the user is flagging.
    var messageId: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var category = "something went wrong"
    @State private var text = ""
    @State private var sending = false
    @State private var resultText: String?
    @State private var success = false

    private let categories = ["something went wrong", "wrong direction", "bad output", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("What's happening?") {
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section("Details") {
                    TextField("Tell JARVIS what went wrong (optional)", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let r = resultText {
                    Section {
                        Label(r, systemImage: success ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(success ? Color.green : Color.red)
                    }
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Send to JARVIS").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(sending)
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func send() async {
        sending = true
        resultText = nil
        defer { sending = false }
        struct Ack: Decodable { let ok: Bool; let id: String?; let notified: Bool? }
        do {
            var body: [String: Any] = [
                "session_id": sessionId,
                "category": category,
                "text": text,
            ]
            if let m = messageId { body["message_id"] = m }
            let ack = try await CCClient.shared.post(
                "/feedback", body: body, as: Ack.self)
            success = ack.ok
            resultText = ack.ok ? "Sent to JARVIS" : "Bridge rejected the report"
            if success {
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        } catch {
            resultText = "Failed: \(error.localizedDescription)"
        }
    }
}
