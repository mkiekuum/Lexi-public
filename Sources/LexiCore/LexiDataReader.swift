import Foundation

public actor LexiDataService {
    private let store: LexiStore

    public init(url: URL = LexiPaths.databaseURL) throws {
        store = try LexiStore(url: url)
    }

    public func loadWorkspace(_ query: EntrySummaryQuery = EntrySummaryQuery()) throws -> LexiWorkspaceSnapshot {
        let entries = try store.listEntrySummaries(query)
        let folders = try store.listFolders()
        let directCounts = try store.db.query("""
            SELECT ef.folder_id AS root, COUNT(DISTINCT e.id) AS member_count
            FROM entry_folders ef JOIN entries e ON e.id=ef.entry_id
            WHERE e.archive_version IS NULL
            GROUP BY ef.folder_id
            """).reduce(into: [String:Int]()) { result, row in
                if let id = row["root"]?.string {
                    result[id] = Int(row["member_count"]?.double ?? 0)
                }
            }
        // Folder badges count memberships recursively; the entry query remains direct-only.
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var counts = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, 0) })
        for (id, count) in directCounts {
            var current: String? = id
            var visited = Set<String>()
            while let folderID = current, let folder = byID[folderID],
                  visited.insert(folderID).inserted {
                counts[folderID, default: 0] += count
                current = folder.parentID
            }
        }
        return LexiWorkspaceSnapshot(entries: entries, folders: folders, folderCounts: counts)
    }

    public func getEntry(_ id: String) throws -> Entry {
        try store.getEntry(id)
    }

    public func createEntry(title: String, type: EntryType, folderID: String? = nil) throws -> Entry {
        try store.withImportTransaction {
            let entry = try store.createEntry(title: title, type: type)
            if let folderID { try store.addFolder(folderID, to: entry.id) }
            return entry
        }
    }

    public func renameEntry(entryID: String, title: String, baselineTitle: String? = nil) throws -> Entry {
        try store.withImportTransaction {
            var entry = try store.getEntry(entryID)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw LexiError.input("項目名を入力してください") }
            if let baselineTitle, entry.title != baselineTitle, entry.title != title {
                throw LexiError.conflict("項目名が変更されました。もう一度お試しください。")
            }
            guard entry.title != title else { return entry }
            if entry.fullTitle == entry.title { entry.fullTitle = title }
            entry.title = title
            try store.updateEntry(entry)
            return try store.getEntry(entryID)
        }
    }

    public func saveNote(entryID: String, note: String, baselineNote: String? = nil) throws -> Entry {
        try store.withImportTransaction {
            var entry = try store.getEntry(entryID)
            if let baselineNote, entry.note != baselineNote, entry.note != note {
                throw LexiError.conflict("ノートが変更されました。下書きをコピーしてから読み直してください。")
            }
            guard entry.note != note else { return entry }
            entry.note = note
            try store.updateEntry(entry)
            return try store.getEntry(entryID)
        }
    }

    public func deleteEntries(_ ids: [String]) throws {
        try store.withImportTransaction {
            for id in Set(ids) { try store.deleteEntry(id) }
        }
    }

    public func addFolder(_ folderID: String, to entryIDs: [String]) throws {
        try store.withImportTransaction {
            for id in Set(entryIDs) { try store.addFolder(folderID, to: id) }
        }
    }

    public func setType(_ type: EntryType, for entryIDs: [String]) throws {
        try store.withImportTransaction {
            for id in Set(entryIDs) {
                var entry = try store.getEntry(id)
                guard entry.type != type else { continue }
                entry.type = type
                try store.updateEntry(entry)
            }
        }
    }

    public func createFolder(name: String, parentID: String?) throws -> Folder {
        try store.createFolder(name: name, parentID: parentID)
    }

    public func updateFolder(_ folder: Folder) throws {
        try store.updateFolder(folder)
    }

    public func arrangeFolders(_ ids: [String], parentID: String?, beforeID: String? = nil) throws {
        try store.arrangeFolders(ids, parentID: parentID, beforeID: beforeID)
    }

    public func deleteFolders(_ ids: [String]) throws { try store.deleteFolders(ids) }

    public func deleteFolder(_ id: String) throws {
        try store.deleteFolder(id)
    }

    public func toggleFolder(_ id: String, entryID: String) throws {
        let current = try store.getEntry(entryID)
        if current.folderIDs.contains(id) {
            try store.removeFolder(id, from: entryID)
        } else {
            try store.addFolder(id, to: entryID)
        }
    }

    public func refreshDictionaryContent(requested: Entry, result: DictionarySourceResult) throws -> Bool {
        try store.refreshDictionaryContent(requested: requested, result: result)
    }

    public func applyDictionaryChoices(requested: Entry, choices: [(DictionaryMatch, DictionarySourceResult)]) throws -> (updated: Int, unchanged: Int, created: Int) {
        try store.applyDictionaryChoices(requested: requested, choices: choices)
    }

    public func updateDictionaryContent(entryID: String, result: DictionarySourceResult) throws -> Bool {
        try store.updateDictionaryContent(entryID: entryID, result: result)
    }

    public func backup(to url: URL) throws {
        try store.backup(to: url)
    }

    public func dataVersion() throws -> Int { try store.dataVersion() }

    public func exportPortableJSON(to url: URL, folderID: String? = nil) throws {
        try store.exportPortableJSON(to: url, folderID: folderID)
    }

    public func exportPortableJSON(to url: URL, folderIDs: [String]?) throws {
        try store.exportPortableJSON(to: url, folderIDs: folderIDs)
    }

    public func previewPortableImport(_ archive: LexiPortableArchive) throws -> LexiPortableImportPreview {
        try store.previewPortableImport(archive)
    }

    public func importPortableArchive(_ archive: LexiPortableArchive) throws -> LexiPortableImportPreview {
        try store.importPortableArchive(archive)
    }

}
