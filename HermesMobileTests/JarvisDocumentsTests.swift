import XCTest
@testable import HermesMobile

/// JARVIS's documents: what the Documents screen lists from the host's `/api/files`, which files a
/// document's page may load, when an open one reloads, and that the platform note teaches JARVIS
/// only helpers the app's kit has.
final class JarvisDocumentsTests: XCTestCase {
    private let listing = Data("""
        {"path": "/root/JARVIS-Files/documents", "parent": "/root/JARVIS-Files", "entries": [
          {"name": "data", "path": "/root/JARVIS-Files/documents/data", "is_directory": true, "size": null, "mtime": 1761750000},
          {"name": "_drafts", "path": "/root/JARVIS-Files/documents/_drafts", "is_directory": true, "size": null, "mtime": 1},
          {"name": "Krendora", "path": "/root/JARVIS-Files/documents/Krendora", "is_directory": true, "size": null, "mtime": 1},
          {"name": "Old notes.html", "path": "/root/JARVIS-Files/documents/Old notes.html", "is_directory": false, "size": 10, "mtime": 1761700000},
          {"name": "📈 Sales.html", "path": "/root/JARVIS-Files/documents/📈 Sales.html", "is_directory": false, "size": 2048, "mtime": 1761750000.5},
          {"name": "logo.png", "path": "/root/JARVIS-Files/documents/logo.png", "is_directory": false, "size": 5, "mtime": 1761760000},
          {"name": "Undated.htm", "path": "/root/JARVIS-Files/documents/Undated.htm", "is_directory": false}
        ]}
        """.utf8)

    func testListingShowsFoldersThenHTMLDocumentsNewestFirst() throws {
        let entries = try JarvisDocuments.entries(listing: listing, folder: "documents")
        XCTAssertEqual(entries.map(\.name), ["Krendora", "📈 Sales.html", "Old notes.html", "Undated.htm"])
        XCTAssertEqual(entries.map(\.kind), [.folder, .document, .document, .document])
        XCTAssertEqual(entries[1].path, "documents/📈 Sales.html")
        XCTAssertEqual(entries[1].heading, JarvisDocuments.Heading(icon: "📈", title: "Sales"))
        XCTAssertEqual(JarvisDocuments.heading(for: "2026 Plan.html", isFolder: false), JarvisDocuments.Heading(icon: nil, title: "2026 Plan"))
    }

    func testADocumentLoadsOnlyFilesInsideJarvisFiles() throws {
        let page = try XCTUnwrap(JarvisDocuments.url(for: "documents/📈 Sales.html"))
        XCTAssertEqual(JarvisDocuments.path(for: page), "documents/📈 Sales.html")
        let data = try XCTUnwrap(URL(string: "data/sales.json?t=17", relativeTo: page)?.absoluteURL)
        XCTAssertEqual(JarvisDocuments.path(for: data), "documents/data/sales.json")
        XCTAssertNil(JarvisDocuments.path(for: try XCTUnwrap(URL(string: "jarvis-doc://files/documents/%2E%2E/%2E%2E/.ssh/id_rsa"))))
        XCTAssertNil(JarvisDocuments.path(for: try XCTUnwrap(URL(string: "jarvis-doc://other/documents/a.html"))))
        XCTAssertNil(JarvisDocuments.path(for: try XCTUnwrap(URL(string: "https://files/documents/a.html"))))
        XCTAssertEqual(try HermesWorkspaceFileClient.hostPath("documents/data/sales.json", in: JarvisFiles.folder),
                       "~/JARVIS-Files/documents/data/sales.json")
    }

    func testAnOpenDocumentSeesJarvisRewriteOrDeleteIt() throws {
        let before = try JarvisDocuments.version(named: "📈 Sales.html", listing: listing)
        let rewritten = Data(String(decoding: listing, as: UTF8.self).replacingOccurrences(of: "1761750000.5", with: "1761750099").utf8)
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, try JarvisDocuments.version(named: "📈 Sales.html", listing: rewritten))
        XCTAssertNil(try JarvisDocuments.version(named: "Gone.html", listing: listing))
    }

    func testThePlatformNoteNamesOnlyHelpersTheKitHas() throws {
        XCTAssertTrue(HermesREST.platformNote.contains(JarvisFiles.folder + "/" + JarvisDocuments.folder + "/"))
        let named = Set(HermesREST.platformNote.matches(of: #/Jarvis\.(\w+)/#).map { String($0.output.1) })
        XCTAssertFalse(named.isEmpty)
        for helper in named {
            XCTAssertTrue(JarvisDocumentKit.script.contains("\(helper): \(helper)"), "window.Jarvis has no \(helper)")
        }
    }

    func testEveryDocumentGetsTheBundledLibraries() throws {
        for name in JarvisDocumentKit.libraries + [JarvisDocumentKit.stylesheet] {
            XCTAssertNotNil(JarvisDocumentKit.file(name), "\(name) is missing from the app's DocumentKit folder")
        }
        let tailwind = try XCTUnwrap(JarvisDocumentKit.file("tailwindcss-browser.js"))
        XCTAssertNotEqual(JarvisDocumentKit.tailwind(tailwind), tailwind,
                          "Tailwind no longer appends to document.head as it loads: check the document-start patch")
    }

    func testManagedFilesListsAHostFolder() throws {
        let request = try HermesREST.managedFiles(path: "~/JARVIS-Files/a+b c").request(base: URL(string: "https://hermes.example")!)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://hermes.example/api/files?path=~/JARVIS-Files/a%2Bb%20c")
    }
}
