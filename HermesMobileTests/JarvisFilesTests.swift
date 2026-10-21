import XCTest
@testable import HermesMobile

/// Files from JARVIS reads one host folder, `~/JARVIS-Files`, which the host expands.
@MainActor final class JarvisFilesTests: XCTestCase {
    func testPathsStayInsideTheJarvisFilesFolder() throws {
        XCTAssertEqual(try HermesWorkspaceFileClient.hostPath(FileTree.rootPath, in: JarvisFiles.folder), "~/JARVIS-Files")
        XCTAssertEqual(try HermesWorkspaceFileClient.hostPath("reports/weekly.pdf", in: JarvisFiles.folder),
                       "~/JARVIS-Files/reports/weekly.pdf")
        XCTAssertThrowsError(try HermesWorkspaceFileClient.hostPath("../.ssh/id_rsa", in: JarvisFiles.folder))
        XCTAssertThrowsError(try HermesWorkspaceFileClient.hostPath("/etc/passwd", in: JarvisFiles.folder))
    }

    func testClientIsScopedToTheFolderOnALocalBackend() {
        let server = URL(string: "https://jarvis.example")!
        let record = BotConnection(id: UUID(), name: "JARVIS", address: server, username: "user", password: "secret")
        let client = JarvisFiles.client(server: server, connection: record, profile: "default")
        XCTAssertEqual(client.context.cwd, "~/JARVIS-Files")
        XCTAssertTrue(client.context.isLocal)
        XCTAssertTrue(client.scope.hasSuffix("|~/JARVIS-Files"))
    }

    func testPlatformNoteTellsJarvisWhereToSaveFiles() {
        XCTAssertTrue(HermesREST.platformNote.contains("~/JARVIS-Files/"))
    }
}
