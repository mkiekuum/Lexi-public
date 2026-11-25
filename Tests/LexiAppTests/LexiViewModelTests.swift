import XCTest
import LexiCore
@testable import LexiApp

final class LexiViewModelTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the workspace", file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lexi-ui-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testFolderSelectionDirectChildrenAndPersistentCollapse() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let parent = try store.createFolder(name: "親")
        let child = try store.createFolder(name: "子", parentID: parent.id)
        let a = try store.createEntry(title: "親だけ")
        let b = try store.createEntry(title: "子だけ")
        try store.addFolder(parent.id, to: a.id)
        try store.addFolder(child.id, to: b.id)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        model.selectFolder(parent.id)
        try await waitUntil { model.entries.map(\.id) == [a.id] }
        model.selectFolder(parent.id)
        XCTAssertEqual(model.navigation, "folder:" + parent.id)
        model.toggleFolderExpansion(parent.id)
        let reopened = LexiViewModel(databaseURL: url)
        XCTAssertTrue(reopened.collapsedFolderIDs.contains(parent.id))
        model.selectFolder(child.id)
        try await waitUntil { model.entries.map(\.id) == [b.id] }
    }

    @MainActor
    func testFolderExportSelectionTracksSingleMultipleAndContextTarget() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B")
        let c = try store.createFolder(name: "C")
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        model.selectFolder(a.id)
        XCTAssertEqual(model.folderIDsForExport, [a.id])
        model.selectFolder(b.id, modifiers: .command)
        XCTAssertEqual(Set(model.folderIDsForExport), [a.id, b.id])
        XCTAssertEqual(Set(model.folderActionIDs(a.id)), [a.id, b.id])
        XCTAssertEqual(model.folderActionIDs(c.id), [c.id])
        model.selectedFolderIDs.removeAll()
        model.navigation = "all"
        XCTAssertTrue(model.folderIDsForExport.isEmpty)
    }

    @MainActor
    func testExternalMCPStyleWritesRefreshDetailAndAppearance() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let writer = try LexiStore(url: url)
        var entry = try writer.createEntry(title: "外部更新", note: "変更前")
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { model.selectedEntry?.id == entry.id }
        entry.note = "AIが更新したノート"
        try writer.updateEntry(entry)
        try LexiPreferences(appearance: .dark).save(for: url)
        model.pollExternalChanges()
        try await waitUntil { model.selectedEntry?.note == entry.note && model.appearance == "dark" }
        XCTAssertEqual(model.noteDraft, entry.note)
    }

    @MainActor
    func testExternalWritePreservesDraftAndRejectsStaleNoteSave() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let writer = try LexiStore(url: url)
        var entry = try writer.createEntry(title: "競合テスト", note: "変更前")
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { model.selectedEntry?.id == entry.id }
        model.beginNoteEditing()
        model.noteDraft = "保存前の手動入力"
        entry.note = "外部AIの変更"
        try writer.updateEntry(entry)
        model.pollExternalChanges()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.noteDraft, "保存前の手動入力")
        model.saveNoteEditing()
        try await waitUntil { model.errorText != nil }
        XCTAssertTrue(model.noteEditing)
        XCTAssertEqual(try writer.getEntry(entry.id).note, "外部AIの変更")
        XCTAssertEqual(model.noteDraft, "保存前の手動入力")
        model.cancelNoteEditing()
        model.pollExternalChanges()
        try await waitUntil { model.selectedEntry?.note == entry.note }
    }

    @MainActor
    func testOpenFailureStopsSpinnerAndRetryRecovers() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        // A directory cannot be opened as a SQLite file. No real user database is involved.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        XCTAssertTrue(model.loadFailed)
        XCTAssertNotNil(model.errorText)
        XCTAssertTrue(model.entries.isEmpty)
        try FileManager.default.removeItem(at: url)
        model.retryLoading()
        try await waitUntil { !model.isLoading }
        XCTAssertFalse(model.loadFailed)
        XCTAssertNil(model.errorText)
        model.createEntry(title: "復旧テスト", type: .headword)
        try await waitUntil { model.entries.count == 1 }
        XCTAssertEqual(model.entries.first?.title, "復旧テスト")
    }

    @MainActor
    func testSearchAndFilterResetRestoresEntries() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        _ = try store.createEntry(title: "春", type: .headword)
        _ = try store.createEntry(title: "一期一会", type: .idiom)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertFalse(model.hasActiveFilters)
        model.searchText = "見つからない語"
        model.typeFilter = "example"
        try await waitUntil { model.entries.isEmpty }
        XCTAssertTrue(model.hasActiveFilters)
        model.clearSearch()
        model.clearFilters()
        try await waitUntil { model.entries.count == 2 }
        XCTAssertFalse(model.hasActiveFilters)
        model.selectAllVisible()
        XCTAssertEqual(model.selectedIDs.count, 2)
    }

    @MainActor
    func testClearingEntryFiltersKeepsCurrentFolderAndSearch() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let folder = try store.createFolder(name: "選択中のフォルダ", parentID: nil)
        let entry = try store.createEntry(title: "春")
        try store.addFolder(folder.id, to: entry.id)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        model.navigation = "folder:\(folder.id)"
        model.searchText = "春"
        model.typeFilter = "example"
        model.noteFilter = true
        try await waitUntil { model.entries.isEmpty }
        model.clearEntryFilters()
        try await waitUntil { model.entries.count == 1 }
        XCTAssertEqual(model.navigation, "folder:\(folder.id)")
        XCTAssertEqual(model.searchText, "春")
        XCTAssertNil(model.noteFilter)
        XCTAssertEqual(model.typeFilter, "all")
    }

    @MainActor
    func testUnsavedNoteIsProtectedWhenChangingSelection() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let first = try store.createEntry(title: "春", note: "元のノート")
        let second = try store.createEntry(title: "夏")
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        model.selectEntry(first.id)
        try await waitUntil { model.selectedEntry?.id == first.id }
        model.beginNoteEditing()
        model.noteDraft = "未保存のノート"
        model.selectEntry(second.id)
        XCTAssertTrue(model.showUnsavedSelectionPrompt)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.noteDraft, "未保存のノート")
        model.cancelPendingSelection()
        XCTAssertFalse(model.showUnsavedSelectionPrompt)
        XCTAssertEqual(model.noteDraft, "未保存のノート")
        XCTAssertEqual(try store.getEntry(first.id).note, "元のノート")
    }

    @MainActor
    func testSavingNotePersistsOnlyToIsolatedDatabase() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let entry = try store.createEntry(title: "テスト項目")
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { model.selectedEntry?.id == entry.id }
        model.beginNoteEditing()
        model.noteDraft = "テストの追記"
        model.saveNoteEditing()
        try await waitUntil { !model.noteEditing }
        XCTAssertEqual(try store.getEntry(entry.id).note, "テストの追記")
        XCTAssertEqual(model.selectedEntry?.note, "テストの追記")
    }
    @MainActor
    func testRapidFolderSwitchResetsFiltersAndRetainsLatestResult() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B")
        let first = try store.createEntry(title: "春", note: "note")
        let second = try store.createEntry(title: "夏", type: .example)
        try store.addFolder(a.id, to: first.id)
        try store.addFolder(b.id, to: second.id)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        for _ in 0..<12 {
            model.selectFolder(a.id)
            model.searchText = "not found"
            model.typeFilter = "idiom"
            model.noteFilter = true
            model.dictionaryFilter = true
            model.selectFolder(b.id)
            XCTAssertEqual(model.searchText, "")
            XCTAssertEqual(model.typeFilter, "all")
            XCTAssertNil(model.noteFilter)
            XCTAssertNil(model.dictionaryFilter)
        }
        try await waitUntil { !model.isLoading && model.entries.map(\.id) == [second.id] && model.selectedEntry?.id == second.id }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.entries.map(\.id), [second.id])
        XCTAssertEqual(model.selectedEntry?.id, second.id)
    }

    @MainActor
    func testFolderNavigationProtectsDraft() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        let store = try LexiStore(url: url)
        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B")
        let first = try store.createEntry(title: "春", note: "original")
        let second = try store.createEntry(title: "夏")
        try store.addFolder(a.id, to: first.id)
        try store.addFolder(b.id, to: second.id)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        model.selectFolder(a.id)
        try await waitUntil { model.selectedEntry?.id == first.id }
        model.beginNoteEditing(); model.noteDraft = "changed"
        model.selectFolder(b.id)
        XCTAssertEqual(model.navigation, "folder:" + a.id)
        XCTAssertTrue(model.showUnsavedSelectionPrompt)
        model.cancelPendingSelection()
        XCTAssertEqual(model.noteDraft, "changed")
        model.selectFolder(b.id)
        model.saveAndContinueSelection()
        try await waitUntil { model.selectedEntry?.id == second.id }
        XCTAssertEqual(try store.getEntry(first.id).note, "changed")
    }

    @MainActor
    func testFontSizeBoundsPersistenceAndAppearance() async throws {
        let url = try temporaryDirectory().appendingPathComponent("workspace.sqlite")
        _ = try LexiStore(url: url)
        let model = LexiViewModel(databaseURL: url)
        try await waitUntil { !model.isLoading }
        model.setFontSizeOffset(999)
        XCTAssertEqual(model.fontSizeOffset, 6)
        model.fontFamily = "Hiragino Sans"
        model.appearance = "dark"
        XCTAssertEqual(try LexiPreferences.load(for: url).fontSizeOffset, 6)
        let reopened = LexiViewModel(databaseURL: url)
        XCTAssertEqual(reopened.fontSizeOffset, 6)
        XCTAssertEqual(reopened.fontFamily, "Hiragino Sans")
        reopened.setFontSizeOffset(-999)
        XCTAssertEqual(reopened.fontSizeOffset, -3)
        reopened.setFontSizeOffset(0)
        XCTAssertEqual(try LexiPreferences.load(for: url).fontSizeOffset, 0)
    }

}
