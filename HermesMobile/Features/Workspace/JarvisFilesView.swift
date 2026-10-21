import SwiftUI

/// "Files from JARVIS": the reports, PDFs and images JARVIS makes for Enrique, read-only, from
/// one folder on the host (`JarvisFiles.folder`) instead of free browsing of the whole server.
/// The app's platform note tells JARVIS to save what it makes there. Hermex's file browser does
/// the listing and the previews (images inline, PDFs and the rest in Quick Look, Share and Save to
/// Files); its Hermes client has no write calls, so nothing here can change the server.
enum JarvisFiles {
    /// Under the host user's home; the host expands `~` (`_fs_path`, `expanduser`).
    static let folder = "~/JARVIS-Files"

    static func client(server: URL, connection: BotConnection, profile: String) -> HermesWorkspaceFileClient {
        let context = HermesWorkspaceContext(server: server, profile: profile, storedKey: "jarvis-files",
                                             cwd: folder, terminalBackend: "local")
        return HermesWorkspaceFileClient(context: context,
                                         http: HermesConnections.shared.connection(for: connection, server: server))
    }
}

struct JarvisFilesView: View {
    let server: URL
    let connection: BotConnection
    let profile: String

    private enum Phase: Equatable {
        case checking, ready, empty, failed(String)
    }

    @State private var phase: Phase = .checking
    @State private var files: HermesWorkspaceFileClient?

    var body: some View {
        Group {
            switch phase {
            case .checking:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                FileBrowserView(files: files, onAPIError: { _ in })
            case .empty:
                ContentUnavailableView {
                    Label("No Files Yet", systemImage: "doc.richtext")
                } description: {
                    Text("Reports, PDFs and images JARVIS makes for you show up here. Ask JARVIS for one in a chat.")
                } actions: {
                    Button("Check Again") { Task { await check() } }
                }
                .accessibilityIdentifier("jarvisFiles.empty")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Files Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { Task { await check() } }
                }
            }
        }
        .navigationTitle("Files from JARVIS")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
    }

    /// Lists the folder once to tell "nothing yet" (the folder isn't there or is empty) from a
    /// folder to browse; the browser then lists it again itself.
    private func check() async {
        phase = .checking
        let client = files ?? JarvisFiles.client(server: server, connection: connection, profile: profile)
        files = client
        do {
            let listing = try await client.directoryList(path: FileTree.rootPath)
            phase = (listing.entries ?? []).isEmpty ? .empty : .ready
        } catch let failure as WorkspaceFolderReadFailure where failure.isMissing {
            phase = .empty
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
