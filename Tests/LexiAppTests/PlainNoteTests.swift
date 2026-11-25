import XCTest
import AppKit
@testable import LexiApp

final class PlainNoteTests: XCTestCase {
    @MainActor
    func testPlainPasteReplacesSelectionAndIgnoresRichText() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("lexi-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("日本語\n二行目", forType: .string)
        item.setData(Data("{\\rtf1\\ansi\\b IGNORE}".utf8), forType: .rtf)
        XCTAssertTrue(board.writeObjects([item]))
        let editor = PlainNoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        editor.isRichText = false
        editor.string = "前OLD後"
        editor.setSelectedRange(NSRange(location: 1, length: 3))
        editor.paste(from: board)
        XCTAssertEqual(editor.string, "前日本語\n二行目後")
        board.clearContents()
        let rich = try NSAttributedString(string: "純テキスト", attributes: [.font: NSFont.boldSystemFont(ofSize: 26)]).data(from: NSRange(location: 0, length: ("純テキスト" as NSString).length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rich, forType: .rtf)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.paste(from: board)
        XCTAssertTrue(editor.string.hasSuffix("純テキスト"))
    }
}
