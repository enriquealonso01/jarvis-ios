import SwiftUI

/// Documents: the pages, reports and live dashboards JARVIS made (`JarvisDocuments`), folders on
/// top, then the most recently changed first. A row opens the document full screen; a folder opens
/// its own list. The list reads again when it comes back on screen, when the app comes forward, and
/// on pull; a search filters it by title.
struct JarvisDocumentsView: View {
    let place: JarvisDocuments.Place
    /// Relative to `JarvisFiles.folder`.
    var folder = JarvisDocuments.folder
    /// A folder's name; nil for the top list.
    var title: String?

    private enum Phase: Equatable {
        case loading, ready, failed(String)
    }

    /// What reads the list again: coming back on screen, or the app coming forward.
    private struct LoadTrigger: Equatable {
        let isActive: Bool
        let appearance: Int
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = Phase.loading
    @State private var entries: [JarvisDocuments.Entry] = []
    @State private var query = ""
    @State private var appearance = 0
    @State private var openedDocument: JarvisDocuments.Route?
    @State private var openedFolder: JarvisDocuments.Entry?

    var body: some View {
        content
            .navigationTitle(title ?? String(localized: "Documents"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("Search Documents"))
            .onAppear { appearance += 1 }
            .task(id: LoadTrigger(isActive: scenePhase == .active, appearance: appearance)) {
                guard scenePhase == .active else { return }
                await load()
            }
            .navigationDestination(item: $openedDocument) { JarvisDocumentView(place: place, route: $0) }
            .navigationDestination(item: $openedFolder) { JarvisDocumentsView(place: place, folder: $0.path, title: $0.heading.title) }
    }

    @ViewBuilder private var content: some View {
        if !entries.isEmpty {
            list
        } else {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                ContentUnavailableView {
                    Label("No Documents Yet", systemImage: "doc.text.image")
                } description: {
                    Text("Ask JARVIS for a document, a report or a live dashboard. It shows up here.")
                } actions: {
                    Button("Check Again") { Task { await load() } }
                }
                .accessibilityIdentifier("jarvisDocuments.empty")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Documents Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
    }

    private var list: some View {
        List(shown) { entry in
            Button {
                if entry.kind == .folder { openedFolder = entry } else { openedDocument = JarvisDocuments.Route(entry) }
            } label: {
                JarvisDocumentRow(entry: entry)
            }
            .accessibilityIdentifier(entry.kind == .folder ? "jarvisDocuments.folder" : "jarvisDocuments.document")
        }
        .listStyle(.plain)
        .refreshable { await load() }
        .overlay {
            if shown.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private var shown: [JarvisDocuments.Entry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? entries : entries.filter { $0.heading.title.localizedStandardContains(query) }
    }

    private func load() async {
        do {
            let listed = try await JarvisDocuments.list(folder, on: place.http)
            guard !Task.isCancelled else { return }
            entries = listed
            phase = .ready
        } catch {
            // A screen that left, or an app that went back, cancels the read; that is no failure.
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// A document's row: its emoji (or a page or folder symbol), its title, and when JARVIS last
/// changed it.
private struct JarvisDocumentRow: View {
    let entry: JarvisDocuments.Entry

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.heading.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if entry.kind == .document, let modified = entry.modified {
                    Text(modified, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if entry.kind == .folder {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Group {
            if let emoji = entry.heading.icon {
                Text(verbatim: emoji).font(.title3)
            } else {
                Image(systemName: entry.kind == .folder ? "folder" : "doc.text")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.secondarySystemFill)))
        .accessibilityHidden(true)
    }
}
