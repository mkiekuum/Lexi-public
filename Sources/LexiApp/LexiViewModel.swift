import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LexiCore

@MainActor
final class LexiViewModel: ObservableObject {
    @Published private(set) var entries: [EntrySummary] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var folderCounts: [String: Int] = [:]
    @Published var selectedFolderIDs: Set<String> = []
    @Published var collapsedFolderIDs: Set<String> = []
    private var folderAnchorID: String?
    private var sidebarStateURL: URL { databaseURL.appendingPathExtension("sidebar.json") }

    func toggleFolderExpansion(_ id: String) {
        if collapsedFolderIDs.contains(id) { collapsedFolderIDs.remove(id) }
        else { collapsedFolderIDs.insert(id) }
        do { try JSONEncoder().encode(collapsedFolderIDs).write(to: sidebarStateURL, options: .atomic) }
        catch { errorText = "フォルダの表示状態を保存できませんでした。" }
    }

    func selectFolder(_ id: String, modifiers: NSEvent.ModifierFlags = []) {
        guard !noteEditing || noteDraft == noteBaseline else {
            pendingNavigation = { [weak self] in self?.selectFolder(id, modifiers: modifiers) }
            pendingSelection = nil
            showUnsavedSelectionPrompt = true
            return
        }
        if noteEditing { cancelNoteEditing() }

        if modifiers.contains(.shift), let anchor = folderAnchorID {
            func visible(_ parent: String?) -> [String] {
                folders.filter { $0.parentID == parent }.flatMap { f in
                    [f.id] + (collapsedFolderIDs.contains(f.id) ? [] : visible(f.id))
                }
            }
            let rows = visible(nil)
            if let a = rows.firstIndex(of: anchor), let b = rows.firstIndex(of: id) {
                selectedFolderIDs = Set(rows[min(a,b)...max(a,b)])
            }
        } else if modifiers.contains(.command) {
            if selectedFolderIDs.contains(id) { selectedFolderIDs.remove(id) }
            else { selectedFolderIDs.insert(id) }
            folderAnchorID = id
        } else {
            selectedFolderIDs = [id]
            folderAnchorID = id
        }
        if selectedFolderIDs.count == 1, let only = selectedFolderIDs.first { navigation = "folder:" + only }
        else { navigation = "all" }
    }

    func navigateTo(_ value: String) {
        guard !noteEditing || noteDraft == noteBaseline else {
            pendingNavigation = { [weak self] in self?.navigateTo(value) }
            pendingSelection = nil
            showUnsavedSelectionPrompt = true
            return
        }
        if noteEditing { cancelNoteEditing() }
        selectedFolderIDs.removeAll()
        navigation = value
    }

    func folderActionIDs(_ id: String) -> [String] {
        selectedFolderIDs.contains(id) ? Array(selectedFolderIDs) : [id]
    }

    func arrangeFolders(_ ids: [String], parentID: String?, beforeID: String? = nil) {
        guard let service, !ids.isEmpty else { return }
        Task {
            do {
                try await service.arrangeFolders(ids, parentID: parentID, beforeID: beforeID)
                if let parentID, collapsedFolderIDs.contains(parentID) { toggleFolderExpansion(parentID) }
                refresh()
            } catch { errorText = error.localizedDescription }
        }
    }

    func deleteFolders(_ ids: [String]) {
        guard let service else { return }
        Task {
            do {
                try await service.deleteFolders(ids)
                selectedFolderIDs.subtract(ids)
                refresh()
            } catch { errorText = error.localizedDescription }
        }
    }

    @Published private(set) var selectedEntry: Entry?
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailed = false
    @Published var noteDraft = ""
    @Published var noteEditing = false
    @Published var showUnsavedSelectionPrompt = false
    @Published var searchFieldFocused = false
    @Published var textEditorFocused = false
    @Published var listSelectionFocused = false
    @Published var selectedID: String? {
        didSet {
            guard !synchronizingSelection, oldValue != selectedID else { return }
            selectedIDs = selectedID.map { [$0] } ?? []
            loadSelectedEntry()
        }
    }
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = "" { didSet { if !suppressFilterRefresh && oldValue != searchText { refresh(debounced: true) } } }
    @Published var typeFilter = "all" { didSet { if !suppressFilterRefresh && oldValue != typeFilter { refresh() } } }
    @Published var navigation = "all" {
        didSet {
            guard !suppressFilterRefresh, oldValue != navigation else { return }
            // Filters and search belong to the current folder, not the next one.
            suppressFilterRefresh = true
            searchText = ""; typeFilter = "all"; dictionaryFilter = nil; noteFilter = nil
            suppressFilterRefresh = false
            selectionAnchorID = nil
            searchFieldFocused = false
            listSelectionFocused = false
            if !noteEditing { applySelection([]) }
            refresh()
        }
    }
    @Published var dictionaryFilter: Bool? { didSet { if !suppressFilterRefresh && oldValue != dictionaryFilter { refresh() } } }
    @Published var noteFilter: Bool? { didSet { if !suppressFilterRefresh && oldValue != noteFilter { refresh() } } }
    @Published var errorText: String?
    @Published var dictionaryProgressText: String?
    @Published private(set) var dictionaryOperationRunning = false
    @Published var dictionaryChoice: DictionaryChoice?
    struct DictionaryChoice: Identifiable {
        let entry: Entry
        let matches: [DictionaryMatch]
        var id: String { entry.id }
    }
    enum DictionaryDecision {
        case selected([DictionaryMatch]), skip, skipAll
    }
    private var choiceContinuation: CheckedContinuation<DictionaryDecision, Never>?
    func chooseDictionary(_ decision: DictionaryDecision) {
        let continuation = choiceContinuation
        choiceContinuation = nil
        dictionaryChoice = nil
        continuation?.resume(returning: decision)
    }
    func previewDictionary(entry: Entry, match: DictionaryMatch) async throws -> DictionarySourceResult {
        try await dictionaryProvider.retrieve(for: entry, match: match)
    }
    private func chooseMatch(entry: Entry, matches: [DictionaryMatch]) async -> DictionaryDecision {
        if Task.isCancelled { return .skip }
        return await withCheckedContinuation { continuation in
            choiceContinuation = continuation
            dictionaryChoice = DictionaryChoice(entry: entry, matches: matches)
        }
    }
    @Published var showNewEntry = false
    @Published var focusSearchRequest = 0
    @Published var showMCPSettings = false
    @Published var appearance = "light" {
        didSet {
            guard !loadingPreferences, oldValue != appearance,
                  let value = LexiPreferences.Appearance(rawValue: appearance) else { return }
            do { try LexiPreferences(appearance: value, fontFamily: fontFamily, fontSizeOffset: fontSizeOffset).save(for: databaseURL) }
            catch { errorText = error.localizedDescription }
        }
    }

    @Published var showFontSettings = false
    @Published var fontFamily: String? {
        didSet {
            guard !loadingPreferences, oldValue != fontFamily else { return }
            do {
                try LexiPreferences(appearance: .init(rawValue: appearance) ?? .light, fontFamily: fontFamily, fontSizeOffset: fontSizeOffset).save(for: databaseURL)
            } catch { errorText = error.localizedDescription }
        }
    }

    @Published private(set) var fontSizeOffset = 0
    func setFontSizeOffset(_ value: Int) {
        let next = min(6, max(-3, value))
        guard next != fontSizeOffset else { return }
        fontSizeOffset = next
        guard !loadingPreferences else { return }
        do { try LexiPreferences(appearance: .init(rawValue: appearance) ?? .light, fontFamily: fontFamily, fontSizeOffset: next).save(for: databaseURL) }
        catch { errorText = error.localizedDescription }
    }

    private var loadingPreferences = false
    private var service: LexiDataService?
    private let databaseURL: URL
    private var lastDataVersion: Int?
    private var pollingExternalChanges = false
    private var externalRefreshPending = false
    private let dictionaryProvider: any DictionaryContentProvider
    private var lastLoadedQuery: EntrySummaryQuery?
    private var preferredSelectionAfterRefresh: String?
    private var refreshGeneration = 0
    private var selectionGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var dictionaryTask: Task<Void, Never>?
    private var synchronizingSelection = false
    private var suppressFilterRefresh = false
    private var noteBaseline = ""
    private var pendingSelection: Set<String>?
    private var pendingNavigation: (() -> Void)?
    private var selectionAnchorID: String?

    init(databaseURL: URL = LexiPaths.databaseURL, dictionaryProvider: any DictionaryContentProvider = DictionaryRegistry()) {
        self.databaseURL = databaseURL
        self.dictionaryProvider = dictionaryProvider
        if let preferences = try? LexiPreferences.load(for: databaseURL) {
            self.appearance = preferences.appearance.rawValue
            self.fontFamily = preferences.fontFamily
            self.fontSizeOffset = min(6, max(-3, preferences.fontSizeOffset ?? 0))
        }
        if let data = try? Data(contentsOf: sidebarStateURL),
           let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { collapsedFolderIDs = saved }
        Task { await openDataService() }
    }

    var mcpConfiguration: String {
        (try? LexiPreferences.mcpConfiguration(for: databaseURL)) ?? ""
    }

    /// Detect writes from any MCP process, including while Lexi stays in the foreground.
    func pollExternalChanges() {
        guard let service, !pollingExternalChanges else { return }
        pollingExternalChanges = true
        Task {
            defer { pollingExternalChanges = false }
            do {
                let version = try await service.dataVersion()
                if let previous = lastDataVersion, version != previous { externalRefreshPending = true }
                lastDataVersion = version
                if let settings = try? LexiPreferences.load(for: databaseURL) {
                    loadingPreferences = true
                    if settings.appearance.rawValue != appearance { appearance = settings.appearance.rawValue }
                    if settings.fontFamily != fontFamily { fontFamily = settings.fontFamily }
                    setFontSizeOffset(settings.fontSizeOffset ?? 0)
                    loadingPreferences = false
                }
                // Do not replace an active note draft when an AI changes the database.
                guard externalRefreshPending, !noteEditing else { return }
                externalRefreshPending = false
                refresh()
                if selectedIDs.count == 1, let id = selectedID { requestSelectedEntry(id) }
            } catch { errorText = error.localizedDescription }
        }
    }

    var hasActiveFilters: Bool {
        !searchText.isEmpty || navigation != "all" || typeFilter != "all"
            || dictionaryFilter != nil || noteFilter != nil
    }
    var navigationLabel: String {
        if navigation.hasPrefix("folder:") { return nameForFolder(String(navigation.dropFirst(7))) }
        if navigation == "unorganized" { return "未整理" }
        return "すべての項目"
    }

    private func openDataService() async {
        isLoading = true
        loadFailed = false
        errorText = nil
        do {
            let opened = try await Task.detached(priority: .utility) { [databaseURL] in
                try LexiDataService(url: databaseURL)
            }.value
            service = opened
            lastDataVersion = try await opened.dataVersion()
            refresh()
        } catch {
            isLoading = false
            loadFailed = true
            errorText = error.localizedDescription
        }
    }

    func retryLoading() {
        guard !isLoading else { return }
        if service == nil {
            isLoading = true
            Task { await openDataService() }
        } else {
            refresh()
        }
    }

    func refresh(debounced: Bool = false) {
        guard let service else { return }
        if loadFailed { isLoading = true }
        loadFailed = false
        refreshGeneration += 1
        let generation = refreshGeneration
        let query = makeQuery()
        if lastLoadedQuery != query { isLoading = true }
        refreshTask?.cancel()
        refreshTask = Task {
            if debounced {
                do { try await Task.sleep(for: .milliseconds(220)) }
                catch { return }
            }
            do {
                try Task.checkCancellation()
                let snapshot = try await service.loadWorkspace(query)
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                lastLoadedQuery = query
                isLoading = false
                loadFailed = false
                if entries != snapshot.entries { entries = snapshot.entries }
                if folders != snapshot.folders { folders = snapshot.folders }
                let validFolders = selectedFolderIDs.intersection(Set(folders.map(\.id)))
                if validFolders != selectedFolderIDs { selectedFolderIDs = validFolders }
                if folderCounts != snapshot.folderCounts { folderCounts = snapshot.folderCounts }
                if navigation.hasPrefix("folder:"),
                   !folders.contains(where: { $0.id == String(navigation.dropFirst(7)) }) {
                    navigation = "all"
                    return
                }
                let visibleIDs = Set(entries.map(\.id))
                if let preferred = preferredSelectionAfterRefresh {
                    preferredSelectionAfterRefresh = nil
                    if visibleIDs.contains(preferred) { selectEntry(preferred); return }
                }
                let retained = selectedIDs.intersection(visibleIDs)
                if retained != selectedIDs {
                    setSelection(retained)
                }
                if selectedIDs.isEmpty, let first = entries.first {
                    selectEntry(first.id)
                } else if let selectedID, !visibleIDs.contains(selectedID) {
                    selectEntry(entries.first?.id)
                }
            } catch {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                isLoading = false
                loadFailed = true
                errorText = error.localizedDescription
            }
        }
    }

    private func makeQuery() -> EntrySummaryQuery {
        let folderID = navigation.hasPrefix("folder:") ? String(navigation.dropFirst(7)) : nil
        let type = EntryType(rawValue: typeFilter)
        return EntrySummaryQuery(
            query: searchText,
            type: type,
            folderID: folderID,
            includeDescendantFolders: false,
            hasDictionary: dictionaryFilter,
            hasNote: noteFilter,
            unorganizedOnly: navigation == "unorganized"
        )
    }

    func setSelection(_ ids: Set<String>) {
        let visible = Set(entries.map(\.id))
        let valid = ids.intersection(visible)
        if noteEditing, noteDraft != noteBaseline, valid != selectedIDs {
            pendingSelection = valid
            showUnsavedSelectionPrompt = true
            return
        }
        applySelection(valid)
    }

    private func applySelection(_ valid: Set<String>) {
        synchronizingSelection = true
        selectedIDs = valid
        selectedID = valid.count == 1 ? valid.first : nil
        synchronizingSelection = false
        if valid.count == 1, let id = valid.first {
            if selectedEntry?.id != id { requestSelectedEntry(id) }
        }
        else {
            selectionGeneration += 1
            selectionTask?.cancel()
            selectedEntry = nil
        }
    }

    func selectEntry(_ id: String?) {
        guard let id else {
            setSelection([])
            return
        }
        setSelection([id])
    }

    func selectEntryFromRow(_ id: String, modifiers: NSEvent.ModifierFlags) {
        guard let targetIndex = entries.firstIndex(where: { $0.id == id }) else { return }
        if modifiers.contains(.command) {
            var selection = selectedIDs
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            selectionAnchorID = id
            setSelection(selection)
        } else if modifiers.contains(.shift),
                  let selectionAnchorID,
                  let anchorIndex = entries.firstIndex(where: { $0.id == selectionAnchorID }) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            setSelection(Set(range.map { entries[$0].id }))
        } else {
            selectionAnchorID = id
            setSelection([id])
        }
    }

    func selectAllVisible() {
        guard !entries.isEmpty else { return }
        selectionAnchorID = entries.first?.id
        setSelection(Set(entries.map(\.id)))
    }

    private func loadSelectedEntry() {
        guard let selectedID else {
            selectedEntry = nil
            selectionTask?.cancel()
            return
        }
        requestSelectedEntry(selectedID)
    }

    private func requestSelectedEntry(_ id: String) {
        guard let service else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionTask?.cancel()
        selectedEntry = nil
        selectionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, generation == selectionGeneration else { return }
                let entry = try await service.getEntry(id)
                guard !Task.isCancelled, generation == selectionGeneration, selectedID == id else { return }
                selectedEntry = entry
                if !noteEditing {
                    noteDraft = entry.note
                    noteBaseline = entry.note
                }
            } catch {
                guard !Task.isCancelled, generation == selectionGeneration, selectedID == id else { return }
                errorText = error.localizedDescription
            }
        }
    }

    func clearSearch() {
        searchText = ""
    }

    func clearFilters() {
        suppressFilterRefresh = true
        synchronizingSelection = true
        navigation = "all"
        selectedFolderIDs.removeAll()
        typeFilter = "all"
        dictionaryFilter = nil
        noteFilter = nil
        synchronizingSelection = false
        suppressFilterRefresh = false
        refresh()
    }

    func clearEntryFilters() {
        suppressFilterRefresh = true
        typeFilter = "all"
        dictionaryFilter = nil
        noteFilter = nil
        suppressFilterRefresh = false
        refresh()
    }

    func beginNoteEditing() {
        guard let selectedEntry else { return }
        searchFieldFocused = false
        listSelectionFocused = false
        noteDraft = selectedEntry.note
        noteBaseline = selectedEntry.note
        noteEditing = true
    }

    func cancelNoteEditing() {
        noteDraft = noteBaseline
        noteEditing = false
    }

    func saveNoteEditing() {
        guard let current = selectedEntry else { return }
        let id = current.id
        Task {
            guard let service else { return }
            do {
                let saved = try await service.saveNote(entryID: id, note: noteDraft, baselineNote: noteBaseline)
                guard selectedID == id else { return }
                selectedEntry = saved
                noteBaseline = saved.note
                noteDraft = saved.note
                noteEditing = false
                refresh()
                continuePendingSelection()
            } catch { errorText = error.localizedDescription }
        }
    }

    func saveAndContinueSelection() {
        saveNoteEditing()
    }

    func discardAndContinueSelection() {
        noteDraft = noteBaseline
        noteEditing = false
        continuePendingSelection()
    }

    func cancelPendingSelection() {
        pendingSelection = nil
        pendingNavigation = nil
        showUnsavedSelectionPrompt = false
    }

    private func continuePendingSelection() {
        if let action = pendingNavigation {
            pendingNavigation = nil
            pendingSelection = nil
            showUnsavedSelectionPrompt = false
            action()
            return
        }
        guard let pendingSelection else { return }
        self.pendingSelection = nil
        showUnsavedSelectionPrompt = false
        applySelection(pendingSelection)
    }

    func folderCount(_ id: String) -> Int { folderCounts[id, default: 0] }
    func nameForFolder(_ id: String) -> String { folders.first(where: { $0.id == id })?.name ?? "" }
    func folderPath(_ id: String) -> String {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var names: [String] = []
        var current: String? = id
        var visited = Set<String>()
        while let currentID = current, let folder = byID[currentID], visited.insert(currentID).inserted {
            names.insert(folder.name, at: 0)
            current = folder.parentID
        }
        return names.joined(separator: " / ")
    }

    func createEntry(title: String, type: EntryType) {
        guard let service else { return }
        let folderID = navigation.hasPrefix("folder:") ? String(navigation.dropFirst(7)) : nil
        Task {
            do {
                let entry = try await service.createEntry(title: title, type: type, folderID: folderID)
                preferredSelectionAfterRefresh = entry.id
                // A newly created item should not immediately disappear behind an old filter.
                suppressFilterRefresh = true
                searchText = ""; typeFilter = "all"; noteFilter = nil; dictionaryFilter = nil
                suppressFilterRefresh = false
                refresh()
            } catch { errorText = error.localizedDescription }
        }
    }

    func renameEntry(_ entry: Entry, title: String) async -> Bool {
        guard let service else { return false }
        do {
            let saved = try await service.renameEntry(entryID: entry.id, title: title, baselineTitle: entry.title)
            if selectedID == entry.id { selectedEntry = saved }
            refresh()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func deleteEntry(_ id: String) { deleteEntries([id]) }

    func deleteEntries(_ ids: [String]) {
        guard let service, !ids.isEmpty else { return }
        if noteEditing, noteDraft != noteBaseline, selectedID.map(ids.contains) == true {
            errorText = "削除する前に、編集中のノートを保存するかキャンセルしてください。"
            return
        }
        Task {
            do {
                try await service.deleteEntries(ids)
                setSelection([])
                refresh()
            } catch { errorText = error.localizedDescription }
        }
    }

    func createFolder(name: String, parent: String?) {
        guard let service else { return }
        Task {
            do { _ = try await service.createFolder(name: name, parentID: parent); refresh() }
            catch { errorText = error.localizedDescription }
        }
    }

    func renameFolder(_ id: String, name: String) {
        guard let service, var folder = folders.first(where: { $0.id == id }) else { return }
        folder.name = name
        Task {
            do { try await service.updateFolder(folder); refresh() }
            catch { errorText = error.localizedDescription }
        }
    }

    func toggleFolder(_ folderID: String, entryID: String) {
        guard let service else { return }
        Task {
            do { try await service.toggleFolder(folderID, entryID: entryID); refresh(); requestSelectedEntry(entryID) }
            catch { errorText = error.localizedDescription }
        }
    }

    func addFolder(_ folderID: String, to entryIDs: [String]) {
        guard let service else { return }
        Task {
            do { try await service.addFolder(folderID, to: entryIDs); refresh(); reloadSelectedEntry() }
            catch { errorText = error.localizedDescription }
        }
    }

    func setType(_ type: EntryType, for entryIDs: [String]) {
        guard let service else { return }
        Task {
            do { try await service.setType(type, for: entryIDs); refresh(); reloadSelectedEntry() }
            catch { errorText = error.localizedDescription }
        }
    }

    func updateDictionary(for ids: [String]) {
        guard let service, !ids.isEmpty, !dictionaryOperationRunning else { return }
        dictionaryOperationRunning = true
        dictionaryProgressText = "辞典データを確認しています…"
        dictionaryTask = Task {
            var updated = 0
            var unchanged = 0
            var skipped = 0
            var created = 0
            var skipAllAmbiguous = false
            var failures: [String] = []
            for (index, id) in ids.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    let entry = try await service.getEntry(id)
                    dictionaryProgressText = "辞典内容を更新しています… \(index + 1)/\(ids.count)"
                    let matches = try await dictionaryProvider.matches(for: entry)
                    guard !matches.isEmpty else { throw DictionarySourceError.identityMissing }
                    if matches.count == 1 {
                        let result = try await dictionaryProvider.retrieve(for: entry, match: matches[0])
                        try Task.checkCancellation()
                        if try await service.refreshDictionaryContent(requested: entry, result: result) { updated += 1 }
                        else { unchanged += 1 }
                    } else {
                        if skipAllAmbiguous { skipped += 1; continue }
                        let decision = await chooseMatch(entry: entry, matches: matches)
                        try Task.checkCancellation()
                        switch decision {
                        case .skip: skipped += 1
                        case .skipAll: skipAllAmbiguous = true; skipped += 1
                        case .selected(let chosen):
                            guard !chosen.isEmpty, chosen.allSatisfy(matches.contains) else { throw DictionarySourceError.identityMismatch }
                            var results: [(DictionaryMatch, DictionarySourceResult)] = []
                            for match in chosen {
                                results.append((match, try await dictionaryProvider.retrieve(for: entry, match: match)))
                            }
                            try Task.checkCancellation()
                            let result = try await service.applyDictionaryChoices(requested: entry, choices: results)
                            updated += result.updated; unchanged += result.unchanged; created += result.created
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    let title = entries.first(where: { $0.id == id })?.title ?? id
                    failures.append("\(title)：\(error.localizedDescription)")
                }
            }
            refresh()
            reloadSelectedEntry()
            dictionaryOperationRunning = false
            let cancelled = Task.isCancelled
            dictionaryProgressText = "更新 \(updated) 件、追加 \(created) 件、スキップ \(skipped) 件、変更なし \(unchanged) 件、失敗 \(failures.count) 件\(cancelled ? "（中止）" : "")"
            if !failures.isEmpty { errorText = failures.joined(separator: "\n") }
        }
    }

    func cancelDictionaryOperation() {
        dictionaryTask?.cancel()
        chooseDictionary(.skip)
    }

    private func reloadSelectedEntry() {
        if let selectedID { requestSelectedEntry(selectedID) }
    }

    func saveBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lexi-backup-\(Date.now.formatted(.iso8601.year().month().day())).sqlite"
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite")!]
        guard panel.runModal() == .OK, let target = panel.url, let service else { return }
        Task {
            do { try await service.backup(to: target) }
            catch { errorText = error.localizedDescription }
        }
    }

    var selectedFolderID: String? {
        guard navigation.hasPrefix("folder:") else { return nil }
        return String(navigation.dropFirst("folder:".count))
    }

    var folderIDsForExport: [String] {
        let selected = selectedFolderIDs.isEmpty ? Set(selectedFolderID.map { [$0] } ?? []) : selectedFolderIDs
        return folders.filter { selected.contains($0.id) }.map(\.id)
    }

    func exportSelectedFolders() {
        let ids = folderIDsForExport
        guard !ids.isEmpty else { return }
        exportPortableJSON(folderIDs: ids)
    }

    func exportPortableJSON(folderIDs: [String]? = nil) {
        guard let service else {
            errorText = "データベースを開いてから、もう一度お試しください。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        if let folderIDs {
            guard !folderIDs.isEmpty else { return }
            if folderIDs.count == 1, let folder = folders.first(where: { $0.id == folderIDs[0] }) {
                panel.nameFieldStringValue = "Lexi-\(folder.name.replacingOccurrences(of: "/", with: "-")).json"
            } else {
                panel.nameFieldStringValue = "Lexi-\(folderIDs.count)-folders.json"
            }
        } else {
            panel.nameFieldStringValue = "Lexi-export-\(Date.now.formatted(.iso8601.year().month().day())).json"
        }
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                try await service.exportPortableJSON(to: target, folderIDs: folderIDs)
                let alert = NSAlert()
                alert.messageText = "JSONを書き出しました"
                alert.informativeText = target.lastPathComponent
                alert.runModal()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func importPortableJSON() {
        guard let service else {
            errorText = "データベースを開いてから、もう一度お試しください。"
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: source)
                let plan = try LexiPortableImportPlan.decode(data)
                let preview = try await service.previewPortableImport(plan.archive)
                    .includingInvalidItems(plan.invalidItems)
                let alert = NSAlert()
                alert.messageText = preview.conflicts.isEmpty ? "JSONの取込プレビュー" : "JSONに競合があります"
                let summary = """
                新規項目：\(preview.entriesToCreate)
                既存項目の再利用：\(preview.entriesToReuse)
                新規フォルダ：\(preview.foldersToCreate)
                追加する所属：\(preview.folderLinksToAdd)
                既存ノートへの補完：\(preview.notesToFill)
                無効な項目・所属情報：\(preview.invalidItems.count)
                """
                let conflicts = preview.conflicts.prefix(8).map {
                    "・\($0.title)：\($0.reason)"
                }.joined(separator: "\n")
                let invalid = preview.invalidItems.prefix(8).map {
                    "・\($0.item)：\($0.reason)"
                }.joined(separator: "\n")
                var details = summary
                if !conflicts.isEmpty {
                    details += "\n\n競合：\n" + conflicts
                    if preview.conflicts.count > 8 { details += "\nほか \(preview.conflicts.count - 8) 件" }
                }
                if !invalid.isEmpty {
                    details += "\n\n無効な項目：\n" + invalid
                    if preview.invalidItems.count > 8 { details += "\nほか \(preview.invalidItems.count - 8) 件" }
                }
                alert.informativeText = details
                if preview.conflicts.isEmpty {
                    alert.addButton(withTitle: preview.invalidItems.isEmpty ? "取り込む" : "有効なデータを取り込む")
                    alert.addButton(withTitle: "キャンセル")
                } else {
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "閉じる")
                }
                guard alert.runModal() == .alertFirstButtonReturn, preview.conflicts.isEmpty else { return }
                _ = try await service.importPortableArchive(plan.archive)
                refresh()
                let complete = NSAlert()
                complete.messageText = "JSONを取り込みました"
                complete.informativeText = preview.invalidItems.isEmpty
                    ? "既存のノートと辞典本文は保護され、競合のないデータを反映しました。"
                    : "無効な項目・所属情報 \(preview.invalidItems.count) 件を除き、競合のないデータを反映しました。既存のノートと辞典本文は保護されています。"
                complete.runModal()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }


    func openMonokakidoSearch(_ title: String, type: EntryType = .headword) {
        guard let url = MonokakidoURL.searchURL(title: title, type: type) else {
            errorText = "物書堂の検索リンクを作成できませんでした。"
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorText = "物書堂を開けませんでした。アプリがインストールされているか確認してください。"
        }
    }
}
