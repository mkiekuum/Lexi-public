import XCTest
import LexiCore
@testable import LexiApp

final class DictionaryExampleMarkerTests: XCTestCase {
    @MainActor
    func testAllSavedExamplesRenderOneMarker() throws {
        guard let path = ProcessInfo.processInfo.environment["LEXI_MARKER_TEST_DB"] else {
            throw XCTSkip("Set LEXI_MARKER_TEST_DB to a disposable database copy")
        }
        let store = try LexiStore(url: URL(fileURLWithPath: path))
        let entries = try store.listEntrySummaries(EntrySummaryQuery()).filter { $0.type == .example }
        var count = 0
        for item in entries {
            let entry = try store.getEntry(item.id)
            guard !entry.dictionaryText.isEmpty else { continue }
            let doc = try XCTUnwrap(entry.structuredDocument)
            let key = try XCTUnwrap(entry.sourceEntryID) + "-" + (try XCTUnwrap(entry.sourceSubentryID))
            let view = DictionaryDocumentView(document: doc, entryTitle: entry.title,
                entryFullTitle: entry.fullTitle, showsDocumentHeading: true, highlightSourceID: key, onReference: { _ in })
            let html = view.html
            XCTAssertEqual(html.components(separatedBy: "<mark class=\"selected-example\">").count - 1, 1, entry.title)
            XCTAssertEqual(html.components(separatedBy: "</mark>").count - 1, 1, entry.title)
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
        print("Verified example marker HTML: \(count) entries")
    }
}
