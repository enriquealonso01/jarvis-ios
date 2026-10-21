import PDFKit
import XCTest
@testable import HermesMobile

final class ChatPDFExportTests: XCTestCase {

    func testEntriesKeepUserAndAssistantRowsOnly() {
        let messages = [
            ChatMessage(role: "user", content: "Hello", timestamp: 1_770_000_000, messageId: "u1"),
            ChatMessage(role: "tool", content: "{\"ok\":true}", timestamp: 1_770_000_001, messageId: "t1"),
            ChatMessage(role: "assistant", content: "Hi Enrique", timestamp: 1_770_000_002, messageId: "a1"),
            ChatMessage(role: "assistant", content: "   ", timestamp: 1_770_000_003, messageId: "a2"),
            ChatMessage(role: "system", content: "rules", timestamp: 1_770_000_004, messageId: "s1"),
        ]
        let entries = ChatPDFExport.entries(from: messages)
        XCTAssertEqual(entries.map(\.id), ["u1", "a1"])
        XCTAssertEqual(entries.map(\.isUser), [true, false])
        XCTAssertEqual(entries.first?.date, Date(timeIntervalSince1970: 1_770_000_000))
    }

    func testRichBlocksPrintTheirFallbackText() {
        let content = """
        Here is the poll.

        ```jarvis-rich
        {"blocks":[{"id":"q1","type":"poll","props":{"question":"Which?","options":["A","B"]},"fallbackText":"Poll: A or B"}]}
        ```
        """
        let message = ChatMessage(role: "assistant", content: content, timestamp: nil, messageId: "a1")
        XCTAssertEqual(ChatPDFExport.printableText(message), "Here is the poll.\n\nPoll: A or B")
    }

    func testVoiceNotePrintsItsTranscript() {
        let message = ChatMessage(role: "user", content: "Call the bank tomorrow", timestamp: nil, messageId: "u1",
                                  attachments: [MessageAttachment(name: "3f2a-voice-note-1234.m4a")])
        XCTAssertEqual(ChatPDFExport.printableText(message), "Voice note: Call the bank tomorrow")
    }

    func testRenderWritesAPDFWithCoverAndMessages() throws {
        let entries = (0..<60).map { index in
            ChatPDFExport.Entry(id: "m\(index)", isUser: index.isMultiple(of: 2),
                                date: Date(timeIntervalSince1970: 1_770_000_000 + Double(index)),
                                text: String(repeating: "Message \(index). ", count: 20))
        }
        let url = try ChatPDFExport.render(title: "Test chat", entries: entries, options: .init())
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 2, "cover plus more than one page of messages")
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Test chat") ?? false)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Message 0.") ?? false)
    }

    func testRenderWithoutCoverStillProducesAPage() throws {
        var options = ChatPDFExport.Options()
        options.includeCover = false
        let url = try ChatPDFExport.render(title: "Empty", entries: [], options: options)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
    }
}
