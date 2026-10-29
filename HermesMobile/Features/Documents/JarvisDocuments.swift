import Foundation
import UniformTypeIdentifiers

/// JARVIS's documents: pages, reports and live dashboards JARVIS writes as HTML files in
/// `folder`, under `JarvisFiles.folder` on the host. The Documents screen lists them and a
/// document opens full screen in a web view (`JarvisDocumentView`) with the app's look
/// (`JarvisDocumentKit`). JARVIS writes them with its own file tools, so the app only reads: the
/// listing is `/api/files` (names, sizes, modified times) and every file a document loads, the page
/// itself included, is `/api/fs/download` through `JarvisDocumentSchemeHandler`. The app's
/// platform note (`HermesREST.platformNote`) tells JARVIS the format.
enum JarvisDocuments {
    /// The documents' folder, relative to `JarvisFiles.folder`.
    static let folder = "documents"
    /// A document and every file it loads come from `jarvis-doc://files/<path>`, `<path>` relative
    /// to `JarvisFiles.folder`, so a relative URL or a `fetch` in a document reads JARVIS's files.
    static let scheme = "jarvis-doc"
    static let host = "files"
    /// How often an open document asks the host whether JARVIS changed its file.
    static let watchInterval: Duration = .seconds(4)

    /// Where a document's files come from: the signed-in JARVIS host, and the Profile that signs
    /// its downloads.
    struct Place: Equatable {
        let server: URL
        let connection: BotConnection
        let profile: String

        @MainActor var http: HermesConnection { HermesConnections.shared.connection(for: connection, server: server) }
        @MainActor func files() -> HermesWorkspaceFileClient {
            JarvisFiles.client(server: server, connection: connection, profile: profile)
        }
    }

    /// A document or a folder of them, as one listing row shows it.
    struct Entry: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable { case document, folder }

        let kind: Kind
        /// Relative to `JarvisFiles.folder`.
        let path: String
        let name: String
        let modified: Date?
        let size: Int?

        var id: String { path }
        var heading: Heading { JarvisDocuments.heading(for: name, isFolder: kind == .folder) }
    }

    /// The title a file name shows as, and the emoji it leads with, which gives the document its
    /// icon: "📈 Sales.html" is "Sales" with 📈.
    struct Heading: Hashable, Sendable {
        let icon: String?
        let title: String
    }

    /// What a listing says about a document's file; a different one means JARVIS changed it.
    struct Version: Hashable, Sendable {
        let modified: Date?
        let size: Int?
    }

    /// One screen's worth of a document: where it is and what it is called until its page names itself.
    struct Route: Hashable, Identifiable {
        let path: String
        let title: String
        var id: String { path }

        init(path: String, title: String) {
            self.path = path
            self.title = title
        }

        init(_ entry: Entry) {
            self.init(path: entry.path, title: entry.heading.title)
        }

        /// A document another one linked to, by its path.
        init(linked path: String) {
            self.init(path: path, title: JarvisDocuments.heading(for: (path as NSString).lastPathComponent, isFolder: false).title)
        }
    }

    // MARK: - Listing

    /// `folder`'s documents and folders (`entries`), or none when the host has no such folder yet.
    @MainActor static func list(_ folder: String, on http: HermesConnection) async throws -> [Entry] {
        guard let body = try await listing(of: folder, on: http) else { return [] }
        return try entries(listing: body, folder: folder)
    }

    /// The listing row of the document at `path`, or nil once it is gone. Throws when the host
    /// can't be asked, which says nothing about the document.
    @MainActor static func version(of path: String, on http: HermesConnection) async throws -> Version? {
        guard let body = try await listing(of: (path as NSString).deletingLastPathComponent, on: http) else { return nil }
        return try version(named: (path as NSString).lastPathComponent, listing: body)
    }

    /// The row named `name` in one `/api/files` listing, or nil when it has none.
    static func version(named name: String, listing body: Data) throws -> Version? {
        guard let row = try rows(of: body).first(where: { $0["name"].text == name }) else { return nil }
        return Version(modified: row["mtime"].number.map(Date.init(timeIntervalSince1970:)), size: row["size"].integer)
    }

    /// `/api/files` for a folder under `JarvisFiles.folder`; nil when it isn't there (404).
    @MainActor private static func listing(of folder: String, on http: HermesConnection) async throws -> Data? {
        let path = folder.isEmpty ? JarvisFiles.folder : JarvisFiles.folder + "/" + folder
        do {
            return try await http.data(.managedFiles(path: path))
        } catch BotFailure.rejected(404) {
            return nil
        }
    }

    /// The documents and folders of one `/api/files` listing of `folder`: folders first by name,
    /// then documents, most recently changed first. Only HTML files are documents. A folder named
    /// `data` or `assets`, or starting with `_` or `.`, holds documents' files and is left out, as is
    /// every other file.
    static func entries(listing body: Data, folder: String) throws -> [Entry] {
        let entries = try rows(of: body).compactMap { row -> Entry? in
            guard let name = row["name"].text, isName(name) else { return nil }
            let isFolder = row["is_directory"].flag == true
            if isFolder ? isSupportFolder(name) : !isDocument(name) { return nil }
            return Entry(kind: isFolder ? .folder : .document, path: folder.isEmpty ? name : folder + "/" + name, name: name,
                         modified: row["mtime"].number.map(Date.init(timeIntervalSince1970:)), size: row["size"].integer)
        }
        return sorted(entries)
    }

    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            if a.kind != b.kind { return a.kind == .folder }
            if a.kind == .document, a.modified != b.modified {
                guard let left = a.modified else { return false }
                guard let right = b.modified else { return true }
                return left > right
            }
            return a.heading.title.localizedStandardCompare(b.heading.title) == .orderedAscending
        }
    }

    private static func rows(of body: Data) throws -> [BotJSON] {
        guard let rows = try JSONDecoder().decode(BotJSON.self, from: body)["entries"].list else {
            throw APIError.decoding(underlying: BotFailure.unsupported)
        }
        return rows
    }

    static func isDocument(_ name: String) -> Bool {
        ["html", "htm"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func isSupportFolder(_ name: String) -> Bool {
        ["data", "assets"].contains(name.lowercased()) || name.hasPrefix("_")
    }

    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    // MARK: - Names

    static func heading(for name: String, isFolder: Bool) -> Heading {
        var stem = name
        if !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex { stem = String(name[..<dot]) }
        guard let first = stem.first, isEmoji(first) else { return Heading(icon: nil, title: stem) }
        let rest = stem.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? Heading(icon: nil, title: stem) : Heading(icon: String(first), title: rest)
    }

    /// Digits, `#` and `*` are emoji only as keycaps, and a plain symbol such as ☀ only with its
    /// emoji selector, so a scalar counts when it presents as emoji or carries more scalars.
    private static func isEmoji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, scalar.properties.isEmoji else { return false }
        return scalar.properties.isEmojiPresentation || character.unicodeScalars.count > 1
    }

    // MARK: - URLs

    /// The `jarvis-doc` URL of `path`, relative to `JarvisFiles.folder`.
    static func url(for path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.path = "/" + path
        return parts.url
    }

    /// The path under `JarvisFiles.folder` a `jarvis-doc` URL names; nil for another scheme or
    /// host, a path that climbs out of the folder, or none. A query (a cache-busting `?t=`) and a
    /// fragment are not part of it.
    static func path(for url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let path = String(url.path.drop(while: { $0 == "/" }))
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\0"), !parts.contains(".."), parts.contains(where: { !$0.isEmpty && $0 != "." }) else { return nil }
        return path
    }

    /// The `Content-Type` a file is served with; text says it is UTF-8.
    static func contentType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let type: String
        switch ext {
        case "html", "htm": type = "text/html"
        case "js", "mjs": type = "text/javascript"
        case "json": type = "application/json"
        case "css": type = "text/css"
        case "md": type = "text/markdown"
        default: type = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
        let isText = type.hasPrefix("text/") || type == "application/json" || type == "image/svg+xml"
        return isText ? type + "; charset=utf-8" : type
    }
}
