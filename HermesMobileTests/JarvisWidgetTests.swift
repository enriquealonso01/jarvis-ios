import XCTest
@testable import HermesMobile

/// Widgets designed in chat (requirement 8): the ```jarvis-widget spec, its live data file, and
/// how a reply carrying one splits.
final class JarvisWidgetTests: XCTestCase {
    private let fence = """
    ```jarvis-widget
    {"id": "orders", "title": "Orders today", "symbol": "cart", "accent": "#FF8800", "style": "metric",
     "value": 42, "caption": "orders", "data": "~/JARVIS-Files/widgets/orders.json", "extra": true}
    ```
    """

    func testParsesAFencedSpecLeniently() throws {
        let spec = try XCTUnwrap(JarvisWidgetSpec.parse(fence))
        XCTAssertEqual(spec.id, "orders")
        XCTAssertEqual(spec.title, "Orders today")
        XCTAssertEqual(spec.style, .metric)
        XCTAssertEqual(spec.value, "42", "a number value reads as text")
        XCTAssertEqual(spec.data, "~/JARVIS-Files/widgets/orders.json")
    }

    func testStyleDefaultsToMetricAndIdAndTitleAreRequired() {
        XCTAssertEqual(JarvisWidgetSpec.parse(#"{"id": "a", "title": "A"}"#)?.style, .metric)
        XCTAssertNil(JarvisWidgetSpec.parse(#"{"title": "A"}"#))
        XCTAssertNil(JarvisWidgetSpec.parse(#"{"id": " ", "title": "A"}"#))
        XCTAssertNil(JarvisWidgetSpec.parse("not json"))
    }

    func testDataFileOverridesTheLiveFields() throws {
        let spec = try XCTUnwrap(JarvisWidgetSpec.parse(fence))
        let file = #"{"value": "57", "trend": "+3", "rows": [{"label": "Pending", "value": "2"}], "updated": "2026-10-21T15:00:00Z"}"#
        let updated = spec.applying(dataFile: Data(file.utf8))
        XCTAssertEqual(updated.value, "57")
        XCTAssertEqual(updated.trend, "+3")
        XCTAssertEqual(updated.rows, [JarvisWidgetSpec.Row(label: "Pending", value: "2")])
        XCTAssertEqual(updated.updated, "2026-10-21T15:00:00Z")
        XCTAssertEqual(updated.title, "Orders today")
        XCTAssertEqual(spec.applying(dataFile: Data("oops".utf8)), spec)
    }

    func testReplySplitsIntoTextAndWidget() throws {
        let reply = "Here is your widget.\n\n" + fence + "\n\nTap Add to Home Screen."
        let parts = try XCTUnwrap(RichMessageSegments.split(reply))
        XCTAssertEqual(parts.count, 3)
        guard case .widget(let spec, _) = parts[1] else { return XCTFail("expected a widget part") }
        XCTAssertEqual(spec.id, "orders")
    }

    func testRichAndWidgetFencesKeepTheirOrder() throws {
        let rich = "```jarvis-rich\n{\"blocks\":[{\"id\":\"n\",\"type\":\"text\",\"props\":{\"text\":\"Hi\"},\"fallbackText\":\"Hi\"}]}\n```"
        let parts = try XCTUnwrap(RichMessageSegments.split(fence + "\n" + rich))
        guard case .widget = parts.first, case .rich = parts.last else { return XCTFail("order lost: \(parts)") }
    }

    func testUnparseableWidgetFenceStaysText() {
        XCTAssertNil(RichMessageSegments.split("```jarvis-widget\n{\"title\": \"no id\"}\n```"))
    }

    func testDataFilesMustBeInsideJarvisFiles() {
        XCTAssertTrue(JarvisWidgetRefresher.isAllowed("~/JARVIS-Files/widgets/orders.json"))
        XCTAssertFalse(JarvisWidgetRefresher.isAllowed("~/.hermes/config.yaml"))
        XCTAssertFalse(JarvisWidgetRefresher.isAllowed("~/JARVIS-Files/../.ssh/id_rsa"))
        XCTAssertFalse(JarvisWidgetRefresher.isAllowed("/etc/passwd"))
    }

    func testPdfExportPrintsAWidgetByTitle() {
        let message = ChatMessage(role: "assistant", content: fence, timestamp: nil, messageId: "a1")
        XCTAssertEqual(ChatPDFExport.printableText(message), "Widget: Orders today")
    }

    func testPlatformNoteTeachesTheWidgetFence() {
        XCTAssertTrue(HermesREST.platformNote.contains("jarvis-widget"))
    }
}
