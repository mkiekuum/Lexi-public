import Foundation

// Lexi's application does not parse or import dictionary bundles.
// Data arrives through the validated portable JSON contract.
public struct LexiImportDocument: Codable {
    public var entries: [LexiEntryInput]
    public var folders: [LexiFolderInput]?
    public var tags: [LexiTagInput]?
    public var source: String?
    public var folderMode: String?
    public var completeSnapshot: Bool?
    public var adoptLegacyFolderLinks: [LexiLegacyFolderLink]?
    public init(entries: [LexiEntryInput] = [], folders: [LexiFolderInput]? = nil, tags: [LexiTagInput]? = nil,
                source: String? = nil, folderMode: String? = nil, completeSnapshot: Bool? = nil,
                adoptLegacyFolderLinks: [LexiLegacyFolderLink]? = nil) {
        self.entries = entries; self.folders = folders; self.tags = tags
        self.source = source; self.folderMode = folderMode; self.completeSnapshot = completeSnapshot
        self.adoptLegacyFolderLinks = adoptLegacyFolderLinks
    }
}
public struct LexiLegacyFolderLink: Codable {
    public var sourceID: String
    public var folderPath: String
    public init(sourceID: String, folderPath: String) {
        self.sourceID = sourceID; self.folderPath = folderPath
    }
}
public struct LexiEntryInput: Codable {
    public var id: String?
    public var title: String?
    public var fullTitle: String?
    public var type: EntryType?
    public var note: String?
    public var dictionaryText: String?
    public var sourceID: String?
    public var dictionaryID: String?
    public var contentVersion: String?
    public var sourceEntryID: String?
    public var sourceSubentryID: String?
    public var dictionaryRawXML: String?
    public var dictionaryStructured: String?
    public var dictionarySearchText: String?
    public var dictionaryParserVersion: String?
    public var dictionaryContentHash: String?
    public var dictionaryParseStatus: String?
    public var dictionaryParseError: String?
    public var archiveVersion: String?
    public var parentID: String?
    public var confirmedParent: Bool?
    public var needsReview: Bool?
    public var createdAt: Double?
    public var folders: [String]?
    public var tags: [String]?
    public init(title: String, fullTitle: String = "", type: EntryType = .headword, note: String = "", dictionaryText: String = "", sourceID: String? = nil, folders: [String] = [], tags: [String] = []) {
        self.id = nil; self.title = title; self.fullTitle = fullTitle; self.type = type; self.note = note
        self.dictionaryText = dictionaryText; self.sourceID = sourceID; self.parentID = nil
        self.confirmedParent = nil; self.needsReview = nil; self.createdAt = nil; self.folders = folders; self.tags = tags
        self.dictionaryID = nil; self.contentVersion = nil; self.sourceEntryID = nil; self.sourceSubentryID = nil
        self.dictionaryRawXML = nil; self.dictionaryStructured = nil; self.dictionarySearchText = nil
        self.dictionaryParserVersion = nil; self.dictionaryContentHash = nil; self.dictionaryParseStatus = nil
        self.dictionaryParseError = nil; self.archiveVersion = nil
    }
}
public struct LexiFolderInput: Codable {
    public var path: String
    public init(path: String) { self.path = path }
}
public struct LexiTagInput: Codable {
    public var name: String
    public var color: String?
    public init(name: String, color: String? = nil) { self.name = name; self.color = color }
}
public struct LexiImportReport: Codable {
    public var created: Int = 0
    public var updated: Int = 0
    public var foldersCreated: Int = 0
    public var tagsCreated: Int = 0
    public var folderLinksAdded: Int = 0
    public var folderLinksRemoved: Int = 0
    public var legacyFolderLinksAdopted: Int = 0
    public init() {}
}
public struct LexiSourceAlias: Codable {
    public let sourceID: String
    public let entryID: String
    public init(sourceID: String, entryID: String) { self.sourceID = sourceID; self.entryID = entryID }
}
public struct LexiArchive: Codable {
    public let version: Int
    public let entries: [Entry]
    public let folders: [Folder]
    public let tags: [Tag]
    public let aliases: [LexiSourceAlias]?
}

extension LexiStore {
    public func withImportTransaction<T>(_ body: () throws -> T) throws -> T { try dbTransaction(body) }
    public func setDictionaryText(entryID: String, text: String) throws {
        var entry = try getEntry(entryID)
        entry.dictionaryText = text
        try updateEntry(entry)
    }
    /// Apply a provider-verified result without exposing dictionary identifiers to users.
    public func refreshDictionaryContent(requested: Entry, result: DictionarySourceResult) throws -> Bool {
        try withImportTransaction {
            let current = try getEntry(requested.id)
            guard current.title == requested.title, current.type == requested.type,
                  let matched = result.matchedShortTitle,
                  matched.utf8.elementsEqual(DictionaryDisplayText.clean(current.title).utf8) else {
                throw LexiError.conflict("項目名または種類が一致しません。")
            }
            let parts = result.sourceKey.split(separator: "-").map(String.init)
            guard parts.count == 2, DictionarySourceIdentity.normalizedKey(result.sourceKey) != nil else {
                throw LexiError.input("辞典の見出しを確認できませんでした。")
            }
            // Old source IDs and version identity are not used for refresh.
            try rawExecute("UPDATE entries SET source_id=NULL,dictionary_id=NULL,content_version=NULL,source_entry_id=?,source_subentry_id=? WHERE id=?",
                           [.text(parts[0]), .text(parts[1]), .text(current.id)])
            return try updateDictionaryContent(entryID: current.id, result: result)
        }
    }

    /// Apply multiple verified dictionary senses atomically. Preserve the original note
    /// and memberships; never merge independent same-title entries.
    public func applyDictionaryChoices(requested: Entry, choices: [(DictionaryMatch, DictionarySourceResult)]) throws -> (updated: Int, unchanged: Int, created: Int) {
        try withImportTransaction {
            guard !choices.isEmpty, Set(choices.map { $0.0.id }).count == choices.count else {
                throw LexiError.input("辞典候補が重複しています")
            }
            let original = try getEntry(requested.id)
            guard original.title == requested.title, original.type == requested.type,
                  original.archiveVersion == nil else { throw LexiError.conflict("項目が変更されました") }
            var updated = 0, unchanged = 0, created = 0
            // Prefer retaining an existing dictionary association on the original ID.
            let existingKey = [original.sourceEntryID, original.sourceSubentryID].compactMap { $0 }.joined(separator: "-")
            var ordered = choices
            if let i = ordered.firstIndex(where: { $0.0.locator == existingKey }), i != 0 {
                ordered.swapAt(0, i)
            }
            for (index, pair) in ordered.enumerated() {
                let (match, result) = pair
                guard match.locator == result.sourceKey,
                      match.shortTitle.utf8.elementsEqual(DictionaryDisplayText.clean(original.title).utf8),
                      result.matchedShortTitle == match.shortTitle,
                      result.providerName == match.dictionary else {
                    throw LexiError.conflict("辞典候補が一致しません")
                }
                var target = original
                if index > 0 {
                    target = try createEntry(title: original.title, type: original.type, note: original.note)
                    target.folderIDs = original.folderIDs
                    target.tagIDs = original.tagIDs
                    target.parentID = original.parentID
                    target.needsReview = original.needsReview
                    created += 1
                }
                target.fullTitle = match.heading
                try updateEntry(target)
                if try refreshDictionaryContent(requested: target, result: result) { updated += 1 }
                else { unchanged += 1 }
            }
            return (updated, unchanged, created)
        }
    }

    @discardableResult
    public func updateDictionaryContent(entryID: String, result: DictionarySourceResult) throws -> Bool {
        guard !result.structured.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.rawXML.isEmpty else {
            throw LexiError.input("空の辞典本文は保存できません")
        }
        let existing = try getEntry(entryID)
        let expectedKey = [existing.sourceEntryID, existing.sourceSubentryID]
            .compactMap { $0 }
            .joined(separator: "-")
        let exactExampleContext = existing.type == .example
            && result.sourceKind == .example
            && result.structured.entryKind == EntryType.headword.rawValue
            && existing.sourceEntryID.map {
                DictionarySourceIdentity.matches("\($0)-0000", "\(result.structured.sourceEntryID)-0000")
            } == true
            && DictionarySourceIdentity.referenceCount(
                in: result.structured,
                sourceKey: expectedKey
            ) == 1
        let exactEntry = result.sourceKind == existing.type
            && result.structured.entryKind == existing.type.rawValue
        guard expectedKey == result.sourceKey, exactEntry || exactExampleContext else {
            throw LexiError.conflict("辞典本文と項目の識別子または種別が一致しません")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let structuredData = try encoder.encode(result.structured)
        guard let structured = String(data: structuredData, encoding: .utf8) else {
            throw LexiError.database("構造化辞典本文を文字列に変換できません")
        }
        let text = result.structured.plainText
        guard existing.dictionaryText != text
                || existing.dictionaryRawXML != result.rawXML
                || existing.dictionaryStructured != structured
                || existing.dictionaryContentHash != result.contentHash
                || existing.dictionaryParserVersion != result.parserVersion else {
            return false
        }
        try rawExecute("""
            UPDATE entries
            SET dictionary_text=?, dictionary_raw_xml=?, dictionary_structured=?,
                dictionary_search_text=?, dictionary_content_hash=?, dictionary_parser_version=?,
                dictionary_parse_status=?, dictionary_parse_error=NULL, updated_at=?
            WHERE id=?
            """, [
                .text(text), .text(result.rawXML), .text(structured), .text(text),
                .text(result.contentHash), .text(result.parserVersion),
                .text(result.structured.parseStatus), .real(Date().timeIntervalSince1970), .text(entryID)
            ])
        return true
    }
    public func findOrCreateFolder(path: String) throws -> (folder: Folder, created: Int) {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { throw LexiError.input("フォルダのパスが空です") }
        var parent: String? = nil
        var last: Folder? = nil
        var count = 0
        for name in segments {
            let matches = try listFolders().filter { $0.name == name && $0.parentID == parent }
            if let found = matches.first { last = found }
            else { last = try createFolder(name: name, parentID: parent); count += 1 }
            parent = last?.id
        }
        return (last!, count)
    }
    private func findFolderID(path: String) throws -> String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return nil }
        var parent: String? = nil
        for name in segments {
            guard let found = try listFolders().first(where: { $0.name == name && $0.parentID == parent }) else { return nil }
            parent = found.id
        }
        return parent
    }
    private func importEntry(for key: String, input: LexiEntryInput? = nil) throws -> Entry? {
        if let input, let dictionaryID = input.dictionaryID, let version = input.contentVersion,
           let sourceEntryID = input.sourceEntryID, let subentryID = input.sourceSubentryID {
            let rows = try db.query("""
                SELECT id FROM entries
                WHERE dictionary_id=? AND content_version=? AND source_entry_id=? AND source_subentry_id=?
                """, [.text(dictionaryID), .text(version), .text(sourceEntryID), .text(subentryID)])
            guard rows.count <= 1 else { throw LexiError.conflict("複合Source Identityが重複しています: \(key)") }
            if let id = rows.first?["id"]?.string { return try getEntry(id) }
            let unclassified = try db.query("""
                SELECT id FROM entries WHERE source_id=? AND archive_version IS NULL
                  AND content_version IS NULL
                """, [.text(key)]).compactMap { $0["id"]?.string }
            guard unclassified.count <= 1 else {
                throw LexiError.conflict("バージョン未確定のSource IDが複数あります: \(key)")
            }
            if let id = unclassified.first { return try getEntry(id) }
            return nil
        }
        let matches = try db.query("""
            SELECT id FROM entries WHERE id=? OR (source_id=? AND archive_version IS NULL)
            UNION SELECT entry_id AS id FROM source_aliases WHERE source_id=?
            """, [.text(key), .text(key), .text(key)]).compactMap { $0["id"]?.string }
        let ids = Set(matches)
        guard ids.count <= 1 else {
            throw LexiError.conflict("Source IDが複数の辞典バージョンに存在します: \(key)")
        }
        guard let id = ids.first else { return nil }
        return try getEntry(id)
    }
    public func importRecords(_ document: LexiImportDocument) throws -> LexiImportReport {
        var report = LexiImportReport()
        let source = document.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderMode = document.folderMode ?? "merge"
        guard folderMode == "merge" || folderMode == "reconcile" else {
            throw LexiError.input("folderMode は merge または reconcile で指定してください")
        }
        if folderMode == "reconcile" {
            guard source?.isEmpty == false, document.completeSnapshot == true else {
                throw LexiError.input("Reconcile には source と completeSnapshot: true が必要です")
            }
        }
        if let source, source.isEmpty { throw LexiError.input("source が空です") }
        try withImportTransaction {
            var desiredFolderLinks = Set<String>()
            var seenSourceIDs = Set<String>()
            for folder in document.folders ?? [] {
                report.foldersCreated += try findOrCreateFolder(path: folder.path).created
            }
            for input in document.tags ?? [] {
                guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LexiError.input("タグ名が空です") }
                if let found = try listTags().first(where: { $0.name == input.name }) {
                    if let color = input.color { var copy = found; copy.color = color; try updateTag(copy) }
                } else {
                    _ = try createTag(name: input.name, color: input.color ?? "#77A98B")
                    report.tagsCreated += 1
                }
            }
            for input in document.entries {
                if source != nil, input.folders == nil {
                    throw LexiError.input("同期元の各項目に folders 配列が必要です")
                }
                if let sourceID = input.sourceID,
                   sourceID.isEmpty || sourceID != sourceID.trimmingCharacters(in: .whitespacesAndNewlines) {
                    throw LexiError.input("Source ID が空か前後に空白があります")
                }
                if let sourceID = input.sourceID, !seenSourceIDs.insert(sourceID).inserted {
                    throw LexiError.conflict("入力に重複した Source ID があります: \(sourceID)")
                }
                let idMatch = try input.id.flatMap { try importEntry(for: $0) }
                let hasCompleteIdentity = input.dictionaryID != nil && input.contentVersion != nil
                    && input.sourceEntryID != nil && input.sourceSubentryID != nil
                let byID: Entry?
                if hasCompleteIdentity, let idMatch,
                   idMatch.contentVersion != nil, idMatch.contentVersion != input.contentVersion {
                    byID = nil
                } else {
                    byID = idMatch
                }
                let bySource = try input.sourceID.flatMap { try importEntry(for: $0, input: input) }
                if let byID, let bySource, byID.id != bySource.id {
                    throw LexiError.conflict("内部 ID と Source ID が別々の項目を指しています: \(input.sourceID ?? "")")
                }
                let previous = byID ?? bySource
                if let previous, let sourceID = input.sourceID,
                   let currentSourceID = previous.sourceID, currentSourceID != sourceID, source != nil {
                    throw LexiError.conflict("Source ID \(sourceID) は既存項目の \(currentSourceID) と一致しません")
                }
                var entry: Entry
                if let previous {
                    entry = previous
                } else {
                    guard let title = input.title else { throw LexiError.input("新規項目には title が必要です") }
                    entry = try createEntry(title: title, fullTitle: input.fullTitle ?? "", type: input.type ?? .headword,
                                            note: input.note ?? "",
                                            sourceID: input.contentVersion == nil ? input.sourceID : nil,
                                            needsReview: input.needsReview ?? false, id: input.id)
                    report.created += 1
                }
                if let title = input.title { entry.title = title }
                if let full = input.fullTitle { entry.fullTitle = full }
                if let type = input.type { entry.type = type }
                if source == nil, let note = input.note { entry.note = note }
                if let text = input.dictionaryText { entry.dictionaryText = text }
                if let value = input.dictionaryID { entry.dictionaryID = value }
                if let value = input.contentVersion { entry.contentVersion = value }
                if let value = input.sourceEntryID { entry.sourceEntryID = value }
                if let value = input.sourceSubentryID { entry.sourceSubentryID = value }
                if let value = input.dictionaryRawXML { entry.dictionaryRawXML = value }
                if let value = input.dictionaryStructured { entry.dictionaryStructured = value }
                if let value = input.dictionarySearchText { entry.dictionarySearchText = value }
                if let value = input.dictionaryParserVersion { entry.dictionaryParserVersion = value }
                if let value = input.dictionaryContentHash { entry.dictionaryContentHash = value }
                if let value = input.dictionaryParseStatus { entry.dictionaryParseStatus = value }
                if let value = input.dictionaryParseError { entry.dictionaryParseError = value }
                if let value = input.archiveVersion { entry.archiveVersion = value }
                if let source = input.sourceID, entry.sourceID == nil || entry.sourceID == source {
                    entry.sourceID = source.isEmpty ? nil : source
                }
                if let needs = input.needsReview { entry.needsReview = needs }
                if let parent = input.parentID {
                    guard input.confirmedParent == true else { throw LexiError.input("親項目の指定には confirmedParent: true が必要です") }
                    entry.parentID = parent.isEmpty ? nil : try getEntry(parent).id
                }
                if source == nil, let folderPaths = input.folders {
                    entry.folderIDs = try folderPaths.map {
                        let resolution = try findOrCreateFolder(path: $0)
                        report.foldersCreated += resolution.created
                        return resolution.folder.id
                    }
                }
                if let names = input.tags {
                    entry.tagIDs = try names.map { name in
                        if let tag = try listTags().first(where: { $0.name == name }) { return tag.id }
                        report.tagsCreated += 1
                        return try createTag(name: name).id
                    }
                }
                if previous == nil {
                    try updateEntry(entry)
                } else if let previous {
                    var comparableEntry = entry
                    var comparablePrevious = previous
                    comparableEntry.folderIDs.sort()
                    comparableEntry.tagIDs.sort()
                    comparablePrevious.folderIDs.sort()
                    comparablePrevious.tagIDs.sort()
                    if comparableEntry != comparablePrevious {
                        try updateEntry(entry)
                        report.updated += 1
                    }
                }
                if let source, let folderPaths = input.folders {
                    for path in folderPaths {
                        let resolution = try findOrCreateFolder(path: path)
                        report.foldersCreated += resolution.created
                        let key = entry.id + "\u{1f}" + resolution.folder.id
                        desiredFolderLinks.insert(key)
                        let existed = try db.scalar(
                            "SELECT COUNT(*) FROM entry_folders WHERE entry_id=? AND folder_id=?",
                            [.text(entry.id), .text(resolution.folder.id)]
                        ).double ?? 0
                        if existed == 0 { report.folderLinksAdded += 1 }
                        try db.execute("INSERT OR IGNORE INTO entry_folders(entry_id,folder_id) VALUES(?,?)",
                                       [.text(entry.id), .text(resolution.folder.id)])
                        try db.execute("INSERT OR IGNORE INTO entry_folder_sources(source,entry_id,folder_id) VALUES(?,?,?)",
                                       [.text(source), .text(entry.id), .text(resolution.folder.id)])
                    }
                }
                if previous == nil, let created = input.createdAt, created.isFinite, created > 0 {
                    try rawExecute("UPDATE entries SET created_at=?,updated_at=? WHERE id=?", [.real(created),.real(created),.text(entry.id)])
                }
            }
            if let source, folderMode == "reconcile" {
                for legacyLink in document.adoptLegacyFolderLinks ?? [] {
                    guard let folderID = try findFolderID(path: legacyLink.folderPath),
                          let entry = try importEntry(for: legacyLink.sourceID) else { continue }
                    let exists = (try db.scalar(
                        "SELECT COUNT(*) FROM entry_folders WHERE entry_id=? AND folder_id=?",
                        [.text(entry.id), .text(folderID)]
                    ).double ?? 0) > 0
                    guard exists else { continue }
                    try db.execute("DELETE FROM entry_folder_manual WHERE entry_id=? AND folder_id=?",
                                   [.text(entry.id), .text(folderID)])
                    let wasManual = (try db.scalar("SELECT changes()").double ?? 0) > 0
                    try db.execute("INSERT OR IGNORE INTO entry_folder_sources(source,entry_id,folder_id) VALUES(?,?,?)",
                                   [.text(source), .text(entry.id), .text(folderID)])
                    if wasManual { report.legacyFolderLinksAdopted += 1 }
                }
                let previousLinks = try db.query("SELECT entry_id,folder_id FROM entry_folder_sources WHERE source=?",
                                                 [.text(source)])
                for link in previousLinks {
                    guard let entryID = link["entry_id"]?.string, let folderID = link["folder_id"]?.string else { continue }
                    guard !desiredFolderLinks.contains(entryID + "\u{1f}" + folderID) else { continue }
                    try db.execute("DELETE FROM entry_folder_sources WHERE source=? AND entry_id=? AND folder_id=?",
                                   [.text(source), .text(entryID), .text(folderID)])
                    let hasManual = (try db.scalar("SELECT COUNT(*) FROM entry_folder_manual WHERE entry_id=? AND folder_id=?",
                                                   [.text(entryID), .text(folderID)]).double ?? 0) > 0
                    let hasOtherSource = (try db.scalar("SELECT COUNT(*) FROM entry_folder_sources WHERE entry_id=? AND folder_id=?",
                                                        [.text(entryID), .text(folderID)]).double ?? 0) > 0
                    if !hasManual && !hasOtherSource {
                        try db.execute("DELETE FROM entry_folders WHERE entry_id=? AND folder_id=?",
                                       [.text(entryID), .text(folderID)])
                        report.folderLinksRemoved += 1
                    }
                }
            }
        }
        return report
    }
    public func importRecords(from url: URL) throws -> LexiImportReport {
        let document = try JSONDecoder().decode(LexiImportDocument.self, from: Data(contentsOf: url))
        return try importRecords(document)
    }
    public func exportJSON(to destination: URL) throws {
        let export = LexiArchive(version: 1, entries: try listEntries(SearchOptions(archiveMode: "all")), folders: try listFolders(), tags: try listTags(), aliases: try sourceAliases())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(export).write(to: destination, options: .atomic)
    }
    public func restoreArchive(from source: URL) throws {
        let archive = try JSONDecoder().decode(LexiArchive.self, from: Data(contentsOf: source))
        guard archive.version == 1 else { throw LexiError.input("未対応のバックアップ形式です") }
        try withImportTransaction {
            let existingFolder = Set(try listFolders().map(\.id))
            var addedFolder = existingFolder
            var pending = archive.folders.filter { !existingFolder.contains($0.id) }
            while !pending.isEmpty {
                let ready = pending.filter { $0.parentID == nil || addedFolder.contains($0.parentID!) }
                guard !ready.isEmpty else { throw LexiError.input("フォルダ構造に循環または不足があります") }
                for f in ready {
                    try rawExecute("INSERT INTO folders(id,name,parent_id,sort_order) VALUES(?,?,?,?)", [.text(f.id), .text(f.name), f.parentID.map(SQLValue.text) ?? .null, .integer(Int64(f.sortOrder))])
                    addedFolder.insert(f.id)
                }
                pending.removeAll { addedFolder.contains($0.id) }
            }
            let existingTags = Set(try listTags().map(\.id))
            for tag in archive.tags where !existingTags.contains(tag.id) {
                try rawExecute("INSERT INTO tags(id,name,color) VALUES(?,?,?)", [.text(tag.id), .text(tag.name), .text(tag.color)])
            }
            let existingEntries = Set(try listEntries().map(\.id))
            for entry in archive.entries where !existingEntries.contains(entry.id) {
                try rawExecute("""
                    INSERT INTO entries(id,title,full_title,type,note,dictionary_text,source_id,parent_id,needs_review,
                        created_at,updated_at,dictionary_id,content_version,source_entry_id,source_subentry_id,
                        dictionary_raw_xml,dictionary_structured,dictionary_search_text,dictionary_parser_version,
                        dictionary_content_hash,dictionary_parse_status,dictionary_parse_error,archive_version)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(entry.id), .text(entry.title), .text(entry.fullTitle), .text(entry.type.rawValue),
                          .text(entry.note), .text(entry.dictionaryText), entry.sourceID.map(SQLValue.text) ?? .null,
                          .null, .integer(entry.needsReview ? 1 : 0), .real(entry.createdAt), .real(entry.updatedAt),
                          entry.dictionaryID.map(SQLValue.text) ?? .null, entry.contentVersion.map(SQLValue.text) ?? .null,
                          entry.sourceEntryID.map(SQLValue.text) ?? .null, entry.sourceSubentryID.map(SQLValue.text) ?? .null,
                          entry.dictionaryRawXML.map(SQLValue.text) ?? .null, entry.dictionaryStructured.map(SQLValue.text) ?? .null,
                          entry.dictionarySearchText.map(SQLValue.text) ?? .null, entry.dictionaryParserVersion.map(SQLValue.text) ?? .null,
                          entry.dictionaryContentHash.map(SQLValue.text) ?? .null, entry.dictionaryParseStatus.map(SQLValue.text) ?? .null,
                          entry.dictionaryParseError.map(SQLValue.text) ?? .null, entry.archiveVersion.map(SQLValue.text) ?? .null])
            }
            for alias in archive.aliases ?? [] {
                try rawExecute("INSERT OR IGNORE INTO source_aliases(source_id,entry_id) VALUES(?,?)", [.text(alias.sourceID), .text(alias.entryID)])
            }
            for entry in archive.entries where !existingEntries.contains(entry.id) {
                if let parent = entry.parentID { try rawExecute("UPDATE entries SET parent_id=? WHERE id=?", [.text(parent), .text(entry.id)]) }
                for id in entry.folderIDs { try addFolder(id, to: entry.id) }
                for id in entry.tagIDs { try addTag(id, to: entry.id) }
            }
        }
    }
}
