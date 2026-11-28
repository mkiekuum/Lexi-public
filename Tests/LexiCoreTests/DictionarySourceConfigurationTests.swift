import Foundation
import XCTest
@testable import LexiCore

final class DictionarySourceConfigurationTests: XCTestCase {
    func testConnectSwitchDisconnectAndMoveWithoutLosingNotebook() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let db = base.appendingPathComponent("Notebook.sqlite")
        let store = try LexiStore(url: db)
        let folder = try store.createFolder(name: "Test")
        let entry = try store.createEntry(title: "検証", note: "keep this note")
        try store.addFolder(folder.id, to: entry.id)
        let parser = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Scripts/daijisen_parser.py")
        func create(_ root: URL, key: String, body: String) throws {
            let contents = root.appendingPathComponent("Contents")
            let index = root.appendingPathComponent("Headline")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
            try "\(key)-0000\t検証\n".write(to: index.appendingPathComponent("headline.headlinestore.tsv"), atomically: true, encoding: .utf8)
            try "\(key)-0000\t検証\n".write(to: index.appendingPathComponent("short-headline.headlinestore.tsv"), atomically: true, encoding: .utf8)
            let xml = "<html><body><Contents><見出G><headword class=\"見出\">検証</headword></見出G><解説G><MG><meaning>\(body)</meaning></MG></解説G></Contents></body></html>"
            try xml.write(to: contents.appendingPathComponent(key + ".xml"), atomically: true, encoding: .utf8)
            // A dictionary-supplied parser must never be executed.
            try "raise RuntimeError('untrusted parser')".write(to: root.appendingPathComponent("daijisen_parser.py"), atomically: true, encoding: .utf8)
        }
        let a = base.appendingPathComponent("External disk A/DAIJISEN.J")
        let b = base.appendingPathComponent("Custom dictionary B")
        try create(a, key: "100001", body: "first test body")
        try create(b, key: "100002", body: "second test body")
        let provider = ConfiguredDictionaryProvider(databaseURL: db, parserURL: parser)
        try DictionarySourceConfiguration().save(for: db)
        do {
            _ = try await provider.matches(for: entry)
            XCTFail("Disconnected sources must not be searched")
        } catch {}
        XCTAssertEqual(try DictionarySourceConfiguration.resolve(a.deletingLastPathComponent()).path, a.path)
        try DictionarySourceConfiguration(directory: a.path).save(for: db)
        let first = try await provider.retrieve(for: entry)
        XCTAssertEqual(first.sourceKey, "100001-0000")
        XCTAssertTrue(try store.refreshDictionaryContent(requested: entry, result: first))
        let previous = try store.getEntry(entry.id)
        let pending = try await provider.matches(for: previous)
        XCTAssertThrowsError(try DictionarySourceConfiguration.resolve(base))
        XCTAssertEqual(try DictionarySourceConfiguration.load(for: db).directory, a.path)
        try DictionarySourceConfiguration(directory: b.path).save(for: db)
        do {
            _ = try await provider.retrieve(for: previous, match: pending[0])
            XCTFail("Old source candidate must be rejected")
        } catch {}
        let second = try await provider.retrieve(for: previous)
        XCTAssertEqual(second.sourceKey, "100002-0000")
        XCTAssertTrue(try store.refreshDictionaryContent(requested: previous, result: second))
        let saved = try store.getEntry(entry.id)
        XCTAssertEqual(saved.note, entry.note)
        XCTAssertEqual(saved.folderIDs, [folder.id])
        XCTAssertTrue(saved.dictionaryText.contains("second test body"))
        try DictionarySourceConfiguration().save(for: db)
        XCTAssertFalse(try DictionarySourceConfiguration.load(for: db).available)
        XCTAssertEqual(try store.getEntry(entry.id), saved)
        try DictionarySourceConfiguration(directory: b.path).save(for: db)
        let moved = base.appendingPathComponent("Moved dictionary")
        try FileManager.default.moveItem(at: b, to: moved)
        XCTAssertFalse(try DictionarySourceConfiguration.load(for: db).available)
        do {
            _ = try await provider.matches(for: saved)
            XCTFail("Missing directory must not fall back to another source")
        } catch {}
        try DictionarySourceConfiguration(directory: DictionarySourceConfiguration.resolve(moved).path).save(for: db)
        let afterMove = try await provider.retrieve(for: saved)
        XCTAssertEqual(afterMove.sourceKey, "100002-0000")
        XCTAssertEqual(try store.getEntry(entry.id), saved)
    }
}
