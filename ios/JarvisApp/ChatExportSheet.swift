import SwiftUI
import Persistence
import FeaturesChat

/// Item 13: export options + share sheet. Pure UI over the engine +
/// renderer — every control functional (no fake buttons).
struct ChatExportSheet: ViewModifier {
    let store: PersistenceStore?
    let conversationID: UUID
    /// Set true from the toolbar to open the options sheet.
    @Binding var isPresented: Bool

    @State private var includeCover = true
    @State private var includeHeaders = true
    @State private var includePageNumbers = true
    @State private var includeTimestamps = true
    @State private var isRendering = false
    @State private var shareURL: URL?
    @State private var errorText: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                optionsView
            }
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL {
                    ChatFileShareSheet(items: [url])
                }
            }
            .alert("Export failed", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "Unknown error")
            }
    }

    private var optionsView: some View {
        NavigationStack {
            Form {
                Section("Include") {
                    Toggle("Cover page", isOn: $includeCover)
                    Toggle("Headers", isOn: $includeHeaders)
                    Toggle("Page numbers", isOn: $includePageNumbers)
                    Toggle("Message timestamps", isOn: $includeTimestamps)
                }
                Section {
                    Button {
                        render()
                    } label: {
                        if isRendering {
                            ProgressView()
                        } else {
                            Label("Export PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isRendering)
                }
                Section {
                    Text("Exports this whole conversation — messages come from the on-device store, oldest first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Export chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func render() {
        guard let store else {
            errorText = "Local store unavailable."
            return
        }
        isRendering = true
        let options = ChatExportEngine.Options(
            includeCover: includeCover,
            includeHeaders: includeHeaders,
            includePageNumbers: includePageNumbers,
            includeTimestamps: includeTimestamps)
        Task {
            do {
                let document = try await ChatExportEngine.buildDocument(
                    conversationID: conversationID,
                    store: store,
                    options: options)
                let url = try ChatPDFRenderer.render(document: document, options: options)
                await MainActor.run {
                    isRendering = false
                    isPresented = false
                    shareURL = url
                }
            } catch {
                await MainActor.run {
                    isRendering = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

/// Item 13: file share sheet — hosts UIActivityViewController for arbitrary
/// items (the rendered PDF file URL). Kept separate from Item 9's
/// text-only wrapper so the QA'd code path is untouched.
struct ChatFileShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
