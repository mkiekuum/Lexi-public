import Foundation

public final class LexiStore {
    let db: SQLiteConnection
    public let url: URL
    public init(url: URL = LexiPaths.databaseURL) throws {
        self.url = url
        self.db = try SQLiteConnection(path: url.path)
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, full_title TEXT NOT NULL DEFAULT '',
                type TEXT NOT NULL CHECK(type IN ('headword','idiom','example')),
                note TEXT NOT NULL DEFAULT '', dictionary_text TEXT NOT NULL DEFAULT '',
                source_id TEXT, parent_id TEXT REFERENCES entries(id) ON DELETE SET NULL,
                needs_review INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                dictionary_id TEXT, content_version TEXT, source_entry_id TEXT, source_subentry_id TEXT,
                dictionary_raw_xml TEXT, dictionary_structured TEXT, dictionary_search_text TEXT,
                dictionary_parser_version TEXT, dictionary_content_hash TEXT,
                dictionary_parse_status TEXT, dictionary_parse_error TEXT, archive_version TEXT
            )
            """)
        try ensureEntryColumns()
        try removeLegacySourceIDUniqueness()
        try db.execute("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES folders(id) ON DELETE CASCADE, sort_order INTEGER NOT NULL DEFAULT 0)")
        try db.execute("CREATE TABLE IF NOT EXISTS tags (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT NOT NULL DEFAULT '#77A98B')")
        try db.execute("CREATE TABLE IF NOT EXISTS entry_folders (entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE, PRIMARY KEY(entry_id,folder_id))")
        try db.execute("CREATE TABLE IF NOT EXISTS entry_folder_manual (entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE, PRIMARY KEY(entry_id,folder_id))")
        try db.execute("CREATE TABLE IF NOT EXISTS entry_folder_sources (source TEXT NOT NULL, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE, PRIMARY KEY(source,entry_id,folder_id))")
        try db.execute("CREATE TABLE IF NOT EXISTS entry_tags (entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY(entry_id,tag_id))")
        try db.execute("CREATE TABLE IF NOT EXISTS source_aliases (source_id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE)")
        try db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_entries_type ON entries(type)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_entries_updated ON entries(updated_at DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_entries_source_id ON entries(source_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_entries_archive ON entries(archive_version)")
        try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_entries_source_identity
            ON entries(dictionary_id,content_version,source_entry_id,source_subentry_id)
            WHERE dictionary_id IS NOT NULL AND content_version IS NOT NULL
              AND source_entry_id IS NOT NULL AND source_subentry_id IS NOT NULL
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_entries_parent ON entries(parent_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_entry_folder_sources_entry ON entry_folder_sources(entry_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_source_aliases_entry ON source_aliases(entry_id)")
        if try db.scalar("SELECT value FROM metadata WHERE key='folder_provenance_migrated'").string == nil {
            try db.execute("INSERT OR IGNORE INTO entry_folder_manual(entry_id,folder_id) SELECT entry_id,folder_id FROM entry_folders")
            try db.execute("INSERT INTO metadata(key,value) VALUES('folder_provenance_migrated','1')")
        }
    }

    private let newEntryColumns: [(String, String)] = [
        ("dictionary_id", "TEXT"), ("content_version", "TEXT"),
        ("source_entry_id", "TEXT"), ("source_subentry_id", "TEXT"),
        ("dictionary_raw_xml", "TEXT"), ("dictionary_structured", "TEXT"),
        ("dictionary_search_text", "TEXT"), ("dictionary_parser_version", "TEXT"),
        ("dictionary_content_hash", "TEXT"), ("dictionary_parse_status", "TEXT"),
        ("dictionary_parse_error", "TEXT"), ("archive_version", "TEXT")
    ]

    private func ensureEntryColumns() throws {
        let columns = Set(try db.query("PRAGMA table_info(entries)").compactMap { $0["name"]?.string })
        for (name, type) in newEntryColumns where !columns.contains(name) {
            try db.execute("ALTER TABLE entries ADD COLUMN \(name) \(type)")
        }
    }

    private func removeLegacySourceIDUniqueness() throws {
        var uniqueSourceIndex = false
        for index in try db.query("PRAGMA index_list(entries)") {
            guard (index["unique"]?.double ?? 0) == 1,
                  let name = index["name"]?.string else { continue }
            if try db.query("PRAGMA index_info('\(name)')").compactMap({ $0["name"]?.string }) == ["source_id"] {
                uniqueSourceIndex = true
                break
            }
        }
        guard uniqueSourceIndex else { return }
        let columns = ["id", "title", "full_title", "type", "note", "dictionary_text", "source_id",
                       "parent_id", "needs_review", "created_at", "updated_at"]
            + newEntryColumns.map(\.0)
        try db.execute("PRAGMA foreign_keys=OFF")
        try db.execute("PRAGMA legacy_alter_table=ON")
        do {
            try db.transaction {
                guard try db.scalar("""
                    SELECT name FROM sqlite_master
                    WHERE type='table' AND name='entries_pre_composite_identity'
                    """).string == nil else {
                    throw LexiError.database("entries_pre_composite_identity が既に存在するため移行を中止しました")
                }
                for index in ["idx_entries_type", "idx_entries_updated", "idx_entries_source_id"] {
                    try db.execute("DROP INDEX IF EXISTS \(index)")
                }
                try db.execute("ALTER TABLE entries RENAME TO entries_pre_composite_identity")
                try db.execute("""
                    CREATE TABLE entries (
                        id TEXT PRIMARY KEY, title TEXT NOT NULL, full_title TEXT NOT NULL DEFAULT '',
                        type TEXT NOT NULL CHECK(type IN ('headword','idiom','example')),
                        note TEXT NOT NULL DEFAULT '', dictionary_text TEXT NOT NULL DEFAULT '',
                        source_id TEXT, parent_id TEXT REFERENCES entries(id) ON DELETE SET NULL,
                        needs_review INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                        dictionary_id TEXT, content_version TEXT, source_entry_id TEXT, source_subentry_id TEXT,
                        dictionary_raw_xml TEXT, dictionary_structured TEXT, dictionary_search_text TEXT,
                        dictionary_parser_version TEXT, dictionary_content_hash TEXT,
                        dictionary_parse_status TEXT, dictionary_parse_error TEXT, archive_version TEXT
                    )
                    """)
                let columnList = columns.joined(separator: ",")
                try db.execute("""
                    INSERT INTO entries(\(columnList))
                    SELECT \(columnList) FROM entries_pre_composite_identity
                    """)
                guard try db.query("SELECT \(columnList) FROM entries_pre_composite_identity EXCEPT SELECT \(columnList) FROM entries").isEmpty,
                      try db.query("SELECT \(columnList) FROM entries EXCEPT SELECT \(columnList) FROM entries_pre_composite_identity").isEmpty,
                      try db.query("PRAGMA foreign_key_check").isEmpty else {
                    throw LexiError.database("移行した項目の確認に失敗しました")
                }
                try db.execute("DROP TABLE entries_pre_composite_identity")
            }
            try db.execute("PRAGMA foreign_keys=ON")
            try db.execute("PRAGMA legacy_alter_table=OFF")
            guard try db.query("PRAGMA foreign_key_check").isEmpty else {
                throw LexiError.database("entries の移行後に外部キー違反があります")
            }
        } catch {
            try? db.execute("PRAGMA foreign_keys=ON")
            try? db.execute("PRAGMA legacy_alter_table=OFF")
            throw error
        }
    }

    public func listEntries(_ options: SearchOptions = SearchOptions()) throws -> [Entry] {
        let archiveClause: String
        switch options.archiveMode {
        case "archive": archiveClause = " WHERE archive_version IS NOT NULL"
        case "all": archiveClause = ""
        default: archiveClause = " WHERE archive_version IS NULL"
        }
        let rows = try db.query("SELECT * FROM entries\(archiveClause)")
        let ef = try db.query("SELECT entry_id,folder_id FROM entry_folders")
        let et = try db.query("SELECT entry_id,tag_id FROM entry_tags")
        let folders = try listFolders()
        let tags = try listTags()
        var foldersByEntry: [String: [String]] = [:]
        var tagsByEntry: [String: [String]] = [:]
        for row in ef { if let e = row["entry_id"]?.string, let f = row["folder_id"]?.string { foldersByEntry[e, default: []].append(f) } }
        for row in et { if let e = row["entry_id"]?.string, let t = row["tag_id"]?.string { tagsByEntry[e, default: []].append(t) } }
        let foldersMap = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let tagsMap = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let folderDescendants = options.folderID.map { id -> Set<String> in
            var ids: Set<String> = [id]
            var changed = true
            while changed {
                changed = false
                for folder in folders where folder.parentID.map({ ids.contains($0) }) ?? false {
                    if ids.insert(folder.id).inserted { changed = true }
                }
            }
            return ids
        }
        let q = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries = rows.map { row -> Entry in
            var item = self.parseEntry(row)
            item.folderIDs = foldersByEntry[item.id] ?? []
            item.tagIDs = tagsByEntry[item.id] ?? []
            return item
        }.filter { entry in
            if let type = options.type, entry.type != type { return false }
            if let folderDescendants, !entry.folderIDs.contains(where: { folderDescendants.contains($0) }) { return false }
            if let tag = options.tagID, !entry.tagIDs.contains(tag) { return false }
            if let has = options.hasDictionary, entry.hasUsableDictionary != has { return false }
            if let has = options.hasNote, (!entry.note.isEmpty) != has { return false }
            if !q.isEmpty {
                let folderNames = entry.folderIDs.compactMap { id -> String? in
                    guard foldersMap[id] != nil else { return nil }
                    var parts: [String] = []
                    var current: String? = id
                    var visited = Set<String>()
                    while let folderID = current, let folder = folders.first(where: { $0.id == folderID }), visited.insert(folderID).inserted {
                        parts.insert(folder.name, at:0)
                        current = folder.parentID
                    }
                    return parts.joined(separator: "/")
                }
                let tagNames = entry.tagIDs.compactMap { tagsMap[$0]?.name }
                let haystack = ([entry.title, entry.fullTitle, entry.searchableDictionaryText, entry.note] + folderNames + tagNames).joined(separator: "\n")
                if !JapaneseSearch.contains(haystack, q) { return false }
            }
            return true
        }
        switch options.sort {
        case "created": entries.sort { $0.createdAt == $1.createdAt ? $0.title < $1.title : $0.createdAt > $1.createdAt }
        case "title": entries.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "type": entries.sort { $0.type.rawValue == $1.type.rawValue ? $0.title < $1.title : $0.type.rawValue < $1.type.rawValue }
        default: entries.sort { $0.updatedAt == $1.updatedAt ? $0.title < $1.title : $0.updatedAt > $1.updatedAt }
        }
        return entries
    }

    public func listEntrySummaries(_ options: EntrySummaryQuery = EntrySummaryQuery()) throws -> [EntrySummary] {
        var clauses = ["e.archive_version IS NULL"]
        var values: [SQLValue] = []
        var folderScope = ""
        if let folderID = options.folderID, options.includeDescendantFolders {
            folderScope = """
                WITH RECURSIVE folder_tree(id) AS (
                    SELECT ?
                    UNION ALL
                    SELECT f.id FROM folders f JOIN folder_tree parent ON f.parent_id=parent.id
                )
                """
            values.append(.text(folderID))
            clauses.append("""
                EXISTS (
                    SELECT 1 FROM entry_folders ef JOIN folder_tree ft ON ft.id=ef.folder_id
                    WHERE ef.entry_id=e.id
                )
                """)
        } else if let folderID = options.folderID {
            clauses.append("EXISTS (SELECT 1 FROM entry_folders ef WHERE ef.entry_id=e.id AND ef.folder_id=?)")
            values.append(.text(folderID))
        }
        if let type = options.type {
            clauses.append("e.type=?")
            values.append(.text(type.rawValue))
        }
        let parentExampleDocument = """
            json_valid(e.dictionary_structured)
            AND json_extract(e.dictionary_structured,'$.entryKind')='headword'
            AND json_extract(e.dictionary_structured,'$.sourceEntryID') NOT GLOB '*[^0-9]*'
            AND e.source_entry_id NOT GLOB '*[^0-9]*'
            AND CAST(json_extract(e.dictionary_structured,'$.sourceEntryID') AS INTEGER)=CAST(e.source_entry_id AS INTEGER)
            AND length(trim(coalesce(json_extract(e.dictionary_structured,'$.plainText'),'')))>0
            AND EXISTS (
                SELECT 1
                FROM json_each(
                    CASE WHEN json_valid(e.dictionary_structured) THEN e.dictionary_structured ELSE '{}' END,
                    '$.sections'
                ) AS section
                JOIN json_each(section.value,'$.segments') AS segment
                WHERE json_extract(segment.value,'$.kind')='example'
                    AND substr(json_extract(segment.value,'$.sourceID'),1,instr(json_extract(segment.value,'$.sourceID'),'-')-1) NOT GLOB '*[^0-9]*'
                    AND length(substr(json_extract(segment.value,'$.sourceID'),1,instr(json_extract(segment.value,'$.sourceID'),'-')-1))>0
                    AND upper(substr(json_extract(segment.value,'$.sourceID'),instr(json_extract(segment.value,'$.sourceID'),'-')+1)) NOT GLOB '*[^0-9A-F]*'
                    AND instr(json_extract(segment.value,'$.sourceID'),'-')>0
                    AND instr(substr(json_extract(segment.value,'$.sourceID'),
                                     instr(json_extract(segment.value,'$.sourceID'),'-')+1),'-')=0
                    AND length(substr(json_extract(segment.value,'$.sourceID'),
                                      instr(json_extract(segment.value,'$.sourceID'),'-')+1))>0
                    AND CAST(substr(json_extract(segment.value,'$.sourceID'),1,
                                    instr(json_extract(segment.value,'$.sourceID'),'-')-1) AS INTEGER)=CAST(e.source_entry_id AS INTEGER)
                    AND upper(substr(json_extract(segment.value,'$.sourceID'),
                                     instr(json_extract(segment.value,'$.sourceID'),'-')+1))=upper(e.source_subentry_id)
            )
            """
        let rawDictionaryAvailable = """
            (
                length(trim(coalesce(e.dictionary_text,'')))>0
                OR (
                    CASE WHEN json_valid(e.dictionary_structured)
                         THEN length(trim(coalesce(json_extract(e.dictionary_structured,'$.plainText'),'')))>0
                         ELSE 0
                    END
                )
            )
            """
        let dictionaryAvailable = """
            CASE WHEN e.type='example' THEN
                CASE WHEN \(parentExampleDocument) THEN 1 ELSE 0 END
            ELSE CASE WHEN \(rawDictionaryAvailable) THEN 1 ELSE 0 END
            END = 1
            """
        if let hasDictionary = options.hasDictionary {
            clauses.append(hasDictionary ? "(\(dictionaryAvailable))" : "NOT (\(dictionaryAvailable))")
        }
        if let hasNote = options.hasNote {
            clauses.append(hasNote ? "length(trim(e.note))>0" : "length(trim(e.note))=0")
        }
        if options.unorganizedOnly {
            clauses.append("""
                NOT EXISTS (SELECT 1 FROM entry_folders ef WHERE ef.entry_id=e.id)
                AND NOT EXISTS (SELECT 1 FROM entry_tags et WHERE et.entry_id=e.id)
                """)
        }
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let variants = Self.searchVariants(query)
            let fields = ["e.title", "e.full_title", "e.dictionary_search_text", "e.dictionary_text", "e.note"]
            let searchClauses = variants.flatMap { _ in fields.map { "\($0) LIKE ? ESCAPE '\\'" } }
            clauses.append("(" + searchClauses.joined(separator: " OR ") + ")")
            for variant in variants {
                let escaped = variant
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                values.append(contentsOf: fields.map { _ in .text("%\(escaped)%") })
            }
        }
        let rows = try db.query("""
            \(folderScope)
            SELECT e.id,e.title,e.full_title,e.type,e.source_id,e.parent_id,e.needs_review,
                   e.created_at,e.updated_at,
                   CASE WHEN \(dictionaryAvailable) THEN 1 ELSE 0 END AS has_dictionary,
                   CASE WHEN length(trim(e.note))>0 THEN 1 ELSE 0 END AS has_note
            FROM entries e
            WHERE \(clauses.joined(separator: " AND "))
            """, values)
        let folderRows = try db.query("SELECT ef.entry_id,ef.folder_id FROM entry_folders ef JOIN entries e ON e.id=ef.entry_id WHERE e.archive_version IS NULL")
        var folderIDsByEntry: [String: [String]] = [:]
        for row in folderRows {
            if let entryID = row["entry_id"]?.string, let folderID = row["folder_id"]?.string {
                folderIDsByEntry[entryID, default: []].append(folderID)
            }
        }
        let summaries = rows.map { row in
            EntrySummary(
                id: row["id"]?.string ?? "",
                title: row["title"]?.string ?? "",
                fullTitle: row["full_title"]?.string ?? "",
                type: EntryType(rawValue: row["type"]?.string ?? "") ?? .headword,
                sourceID: row["source_id"]?.string,
                parentID: row["parent_id"]?.string,
                needsReview: (row["needs_review"]?.double ?? 0) != 0,
                createdAt: row["created_at"]?.double ?? 0,
                updatedAt: row["updated_at"]?.double ?? 0,
                folderIDs: folderIDsByEntry[row["id"]?.string ?? ""] ?? [],
                hasDictionary: (row["has_dictionary"]?.double ?? 0) != 0,
                hasNote: (row["has_note"]?.double ?? 0) != 0
            )
        }
        // Normalize each reading once instead of twice per sorting comparison.
        let locale = Locale(identifier: "ja_JP")
        let options: String.CompareOptions = [.numeric, .caseInsensitive, .widthInsensitive]
        return summaries.map { (entry: $0, key: $0.kanaSortKey) }.sorted { lhs, rhs in
            let order = lhs.key.compare(rhs.key, options: options, locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            let titleOrder = lhs.entry.title.compare(rhs.entry.title, options: options, locale: locale)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.entry.id < rhs.entry.id
        }.map(\.entry)
    }

    private static func searchVariants(_ query: String) -> [String] {
        let compatibility = query.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
        let katakana = JapaneseSearch.normalized(query)
        let hiragana = String(String.UnicodeScalarView(katakana.unicodeScalars.map { scalar in
            if (0x30A1...0x30F6).contains(scalar.value),
               let shifted = Unicode.Scalar(scalar.value - 0x60) {
                return shifted
            }
            return scalar
        }))
        return Array(Set([query, compatibility, katakana, hiragana])).filter { !$0.isEmpty }
    }

    public func getEntry(_ id: String) throws -> Entry {
        let rows = try db.query("""
            SELECT * FROM entries WHERE id=? OR source_id=?
            UNION SELECT entries.* FROM entries JOIN source_aliases ON source_aliases.entry_id=entries.id
            WHERE source_aliases.source_id=?
            """, [.text(id), .text(id), .text(id)])
        let ids = Set(rows.compactMap { $0["id"]?.string })
        guard ids.count <= 1 else {
            throw LexiError.conflict("このSource IDは複数の辞典バージョンに存在します。内部UUIDか完全なSource Identityを指定してください: \(id)")
        }
        guard let row = rows.first else {
            throw LexiError.notFound("項目が見つかりません: \(id)")
        }
        var entry = parseEntry(row)
        entry.folderIDs = try db.query("SELECT folder_id FROM entry_folders WHERE entry_id=?", [.text(entry.id)]).compactMap { $0["folder_id"]?.string }
        entry.tagIDs = try db.query("SELECT tag_id FROM entry_tags WHERE entry_id=?", [.text(entry.id)]).compactMap { $0["tag_id"]?.string }
        return entry
    }

    public func classifySourceVersions(currentSourceIDs: Set<String>, historicalSourceIDs: Set<String>,
                                       currentVersion: String, historicalVersion: String,
                                       dictionaryID: String = "DAIJISEN2",
                                       verifiedCurrentSourceIDs: Set<String> = []) throws -> [String: Int] {
        var counts = ["current": 0, "archived": 0, "unchanged": 0, "unclassified": 0]
        try db.transaction {
            let rows = try db.query("SELECT id,source_id,content_version,archive_version FROM entries WHERE source_id IS NOT NULL")
            for row in rows {
                guard let id = row["id"]?.string, let sourceID = row["source_id"]?.string else { continue }
                let version = row["content_version"]?.string
                let archived = row["archive_version"]?.string
                let isHistorical = historicalSourceIDs.contains(sourceID)
                let isCurrent = currentSourceIDs.contains(sourceID)

                if isHistorical && version == historicalVersion {
                    if archived == historicalVersion {
                        counts["unchanged", default: 0] += 1
                        continue
                    }
                    guard let (entryID, subentryID) = sourceParts(sourceID) else {
                        counts["unclassified", default: 0] += 1
                        continue
                    }
                    try db.execute("""
                        UPDATE entries SET dictionary_id=?,content_version=?,source_entry_id=?,
                            source_subentry_id=?,archive_version=? WHERE id=?
                        """, [.text(dictionaryID), .text(historicalVersion), .text(entryID),
                              .text(subentryID), .text(historicalVersion), .text(id)])
                    counts["archived", default: 0] += 1
                    continue
                }
                if isCurrent && version == currentVersion {
                    if archived == nil {
                        counts["unchanged", default: 0] += 1
                    } else {
                        counts["unclassified", default: 0] += 1
                    }
                    continue
                }
                if version == nil {
                    let provenCurrent = isCurrent && (!isHistorical || verifiedCurrentSourceIDs.contains(sourceID))
                    guard provenCurrent || (isHistorical && !isCurrent),
                          let (entryID, subentryID) = sourceParts(sourceID) else {
                        counts["unclassified", default: 0] += 1
                        continue
                    }
                    let isArchive = !provenCurrent
                    let resolvedVersion = isArchive ? historicalVersion : currentVersion
                    try db.execute("""
                        UPDATE entries SET dictionary_id=?,content_version=?,source_entry_id=?,
                            source_subentry_id=?,archive_version=? WHERE id=?
                        """, [.text(dictionaryID), .text(resolvedVersion), .text(entryID),
                              .text(subentryID), isArchive ? .text(historicalVersion) : .null, .text(id)])
                    counts[isArchive ? "archived" : "current", default: 0] += 1
                    continue
                }
                counts["unclassified", default: 0] += 1
            }
        }
        return counts
    }

    public func sourceEntries(_ sourceID: String) throws -> [Entry] {
        try db.query("SELECT * FROM entries WHERE source_id=? ORDER BY content_version,dictionary_id", [.text(sourceID)])
            .map(parseEntry)
    }

    private func sourceParts(_ sourceID: String) -> (String, String)? {
        let parts = sourceID.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return nil }
        let originalEntryID = parts[0]
        let subentryID = parts[1].uppercased()
        guard originalEntryID.count == 6, originalEntryID.allSatisfy(\.isNumber),
              subentryID.count == 4, subentryID.allSatisfy(\.isHexDigit) else { return nil }
        return (originalEntryID, subentryID)
    }

    private func parseEntry(_ r: [String: SQLValue]) -> Entry {
        Entry(id: r["id"]?.string ?? "", title: r["title"]?.string ?? "", fullTitle: r["full_title"]?.string ?? "", type: EntryType(rawValue: r["type"]?.string ?? "") ?? .headword, note: r["note"]?.string ?? "", dictionaryText: r["dictionary_text"]?.string ?? "", sourceID: r["source_id"]?.string, parentID: r["parent_id"]?.string, needsReview: (r["needs_review"]?.double ?? 0) != 0, createdAt: r["created_at"]?.double ?? 0, updatedAt: r["updated_at"]?.double ?? 0, dictionaryID: r["dictionary_id"]?.string, contentVersion: r["content_version"]?.string, sourceEntryID: r["source_entry_id"]?.string, sourceSubentryID: r["source_subentry_id"]?.string, dictionaryRawXML: r["dictionary_raw_xml"]?.string, dictionaryStructured: r["dictionary_structured"]?.string, dictionarySearchText: r["dictionary_search_text"]?.string, dictionaryParserVersion: r["dictionary_parser_version"]?.string, dictionaryContentHash: r["dictionary_content_hash"]?.string, dictionaryParseStatus: r["dictionary_parse_status"]?.string, dictionaryParseError: r["dictionary_parse_error"]?.string, archiveVersion: r["archive_version"]?.string)
    }

    @discardableResult public func createEntry(title: String, fullTitle: String = "", type: EntryType = .headword, note: String = "", sourceID: String? = nil, createdAt: Double? = nil, needsReview: Bool = false, id: String? = nil) throws -> Entry {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw LexiError.input("項目名を入力してください") }
        if let id {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LexiError.conflict("項目 ID が空か、既に使用されています")
            }
            if try db.scalar("SELECT COUNT(*) FROM entries WHERE id=?", [.text(id)]).double ?? 0 > 0 {
                throw LexiError.conflict("項目 ID が空か、既に使用されています")
            }
        }
        if let sourceID,
           (try db.scalar("SELECT COUNT(*) FROM entries WHERE source_id=?", [.text(sourceID)]).double ?? 0) > 0 {
            throw LexiError.conflict("Source IDは既に使われています。異なる辞典バージョンを登録する場合は完全なSource Identityを指定してください")
        }
        if let sourceID, (try db.scalar("SELECT COUNT(*) FROM source_aliases WHERE source_id=?", [.text(sourceID)]).double ?? 0) > 0 {
            throw LexiError.conflict("辞典IDは既に別の項目で使用されています")
        }
        let item = Entry(id: id ?? UUID().uuidString, title: cleanTitle, fullTitle: fullTitle, type: type, note: note, sourceID: sourceID, needsReview: needsReview, createdAt: createdAt ?? Date().timeIntervalSince1970)
        try db.execute("INSERT INTO entries(id,title,full_title,type,note,dictionary_text,source_id,parent_id,needs_review,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [.text(item.id), .text(item.title), .text(item.fullTitle), .text(item.type.rawValue), .text(item.note), .text(item.dictionaryText), item.sourceID.map(SQLValue.text) ?? .null, .null, .integer(item.needsReview ? 1 : 0), .real(item.createdAt), .real(item.updatedAt)])
        return item
    }

    public func updateEntry(_ entry: Entry) throws {
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LexiError.input("項目名を入力してください") }
        if let parent = entry.parentID {
            guard parent != entry.id else { throw LexiError.input("親項目を自分自身にできません") }
            _ = try getEntry(parent)
            var next = try getEntry(parent).parentID
            var seen: Set<String> = [entry.id, parent]
            while let current = next {
                guard !seen.contains(current) else { throw LexiError.input("項目の循環参照はできません") }
                seen.insert(current)
                next = try getEntry(current).parentID
            }
        }
        if let sourceID = entry.sourceID,
           let aliased = try db.query("SELECT entry_id FROM source_aliases WHERE source_id=?", [.text(sourceID)]).first?["entry_id"]?.string,
           aliased != entry.id { throw LexiError.conflict("辞典IDは別の項目に登録されています") }
        try db.transaction {
            try db.execute("""
                UPDATE entries SET title=?,full_title=?,type=?,note=?,dictionary_text=?,source_id=?,parent_id=?,
                    needs_review=?,updated_at=?,dictionary_id=?,content_version=?,source_entry_id=?,source_subentry_id=?,
                    dictionary_raw_xml=?,dictionary_structured=?,dictionary_search_text=?,dictionary_parser_version=?,
                    dictionary_content_hash=?,dictionary_parse_status=?,dictionary_parse_error=?,archive_version=?
                WHERE id=?
                """, [.text(entry.title), .text(entry.fullTitle), .text(entry.type.rawValue), .text(entry.note),
                      .text(entry.dictionaryText), entry.sourceID.map(SQLValue.text) ?? .null,
                      entry.parentID.map(SQLValue.text) ?? .null, .integer(entry.needsReview ? 1 : 0),
                      .real(Date().timeIntervalSince1970), entry.dictionaryID.map(SQLValue.text) ?? .null,
                      entry.contentVersion.map(SQLValue.text) ?? .null, entry.sourceEntryID.map(SQLValue.text) ?? .null,
                      entry.sourceSubentryID.map(SQLValue.text) ?? .null, entry.dictionaryRawXML.map(SQLValue.text) ?? .null,
                      entry.dictionaryStructured.map(SQLValue.text) ?? .null, entry.dictionarySearchText.map(SQLValue.text) ?? .null,
                      entry.dictionaryParserVersion.map(SQLValue.text) ?? .null, entry.dictionaryContentHash.map(SQLValue.text) ?? .null,
                      entry.dictionaryParseStatus.map(SQLValue.text) ?? .null, entry.dictionaryParseError.map(SQLValue.text) ?? .null,
                      entry.archiveVersion.map(SQLValue.text) ?? .null, .text(entry.id)])
            guard try db.scalar("SELECT changes()").double ?? 0 > 0 else { throw LexiError.notFound("項目が見つかりません") }
            let currentFolders = Set(try db.query("SELECT folder_id FROM entry_folders WHERE entry_id=?", [.text(entry.id)]).compactMap { $0["folder_id"]?.string })
            let desiredFolders = Set(entry.folderIDs)
            for folder in currentFolders.subtracting(desiredFolders) {
                try db.execute("DELETE FROM entry_folders WHERE entry_id=? AND folder_id=?", [.text(entry.id), .text(folder)])
                try db.execute("DELETE FROM entry_folder_manual WHERE entry_id=? AND folder_id=?", [.text(entry.id), .text(folder)])
                try db.execute("DELETE FROM entry_folder_sources WHERE entry_id=? AND folder_id=?", [.text(entry.id), .text(folder)])
            }
            for folder in desiredFolders.subtracting(currentFolders) {
                try db.execute("INSERT INTO entry_folders(entry_id,folder_id) VALUES(?,?)", [.text(entry.id), .text(folder)])
                try db.execute("INSERT INTO entry_folder_manual(entry_id,folder_id) VALUES(?,?)", [.text(entry.id), .text(folder)])
            }
            try db.execute("DELETE FROM entry_tags WHERE entry_id=?", [.text(entry.id)])
            for tag in Set(entry.tagIDs) { try db.execute("INSERT INTO entry_tags(entry_id,tag_id) VALUES(?,?)", [.text(entry.id), .text(tag)]) }
        }
    }

    public func deleteEntry(_ id: String) throws {
        let entry = try getEntry(id)
        try db.execute("DELETE FROM entries WHERE id=?", [.text(entry.id)])
    }
    public func listFolders() throws -> [Folder] {
        try db.query("SELECT * FROM folders ORDER BY sort_order,name").map {
            Folder(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "", parentID: $0["parent_id"]?.string, sortOrder: Int($0["sort_order"]?.double ?? 0))
        }
    }
    @discardableResult public func createFolder(name: String, parentID: String? = nil, id: String? = nil) throws -> Folder {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LexiError.input("フォルダ名を入力してください") }
        if let parentID { guard try listFolders().contains(where: { $0.id == parentID }) else { throw LexiError.notFound("親フォルダが見つかりません") } }
        let folder = Folder(id: id ?? UUID().uuidString, name: clean, parentID: parentID)
        try db.execute("INSERT INTO folders(id,name,parent_id,sort_order) VALUES(?,?,?,?)", [.text(folder.id), .text(folder.name), parentID.map(SQLValue.text) ?? .null, .integer(0)])
        return folder
    }
    public func updateFolder(_ folder: Folder) throws {
        guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LexiError.input("フォルダ名を入力してください") }
        let folders = try listFolders()
        var current = folder.parentID
        var visited: Set<String> = [folder.id]
        while let pid = current {
            guard visited.insert(pid).inserted else { throw LexiError.input("フォルダの循環参照はできません") }
            guard let found = folders.first(where: { $0.id == pid }) else { throw LexiError.notFound("親フォルダが見つかりません") }
            current = found.parentID
        }
        try db.execute("UPDATE folders SET name=?,parent_id=?,sort_order=? WHERE id=?", [.text(folder.name), folder.parentID.map(SQLValue.text) ?? .null, .integer(Int64(folder.sortOrder)), .text(folder.id)])
    }
    /// Reparent and order a group atomically. Moving a parent already carries its children.
    public func arrangeFolders(_ ids: [String], parentID: String?, beforeID: String? = nil) throws {
        try withImportTransaction {
            let all = try listFolders()
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let selected = Set(ids)
            guard !selected.isEmpty, selected.allSatisfy({ byID[$0] != nil }) else {
                throw LexiError.input("移動するフォルダが見つかりません")
            }
            func ancestors(_ id: String?) -> Set<String> {
                var current = id
                var result = Set<String>()
                while let value = current, result.insert(value).inserted { current = byID[value]?.parentID }
                return result
            }
            guard parentID == nil || byID[parentID!] != nil,
                  ancestors(parentID).isDisjoint(with: selected) else {
                throw LexiError.input("自分自身や下位フォルダには移動できません")
            }
            let moving = all.filter { selected.contains($0.id) && ancestors($0.parentID).isDisjoint(with: selected) }
            let movingIDs = Set(moving.map(\.id))
            var siblings = all.filter { $0.parentID == parentID && !movingIDs.contains($0.id) }
            if let beforeID {
                guard let index = siblings.firstIndex(where: { $0.id == beforeID }) else {
                    throw LexiError.input("移動先が変更されました")
                }
                siblings.insert(contentsOf: moving, at: index)
            } else { siblings.append(contentsOf: moving) }
            for (index, var folder) in siblings.enumerated() {
                folder.parentID = parentID
                folder.sortOrder = index
                try updateFolder(folder)
            }
        }
    }

    public func deleteFolders(_ ids: [String]) throws {
        try withImportTransaction {
            for id in Set(ids) { try deleteFolder(id) }
        }
    }

    public func deleteFolder(_ id: String) throws { try db.execute("DELETE FROM folders WHERE id=?", [.text(id)]) }

    public func listTags() throws -> [Tag] {
        try db.query("SELECT * FROM tags ORDER BY name").map { Tag(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "", color: $0["color"]?.string ?? "#77A98B") }
    }
    @discardableResult public func createTag(name: String, color: String = "#77A98B") throws -> Tag {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LexiError.input("タグ名を入力してください") }
        guard color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw LexiError.input("色は #RRGGBB で指定してください") }
        let tag = Tag(name: clean, color: color)
        try db.execute("INSERT INTO tags(id,name,color) VALUES(?,?,?)", [.text(tag.id), .text(tag.name), .text(tag.color)])
        return tag
    }
    public func updateTag(_ tag: Tag) throws {
        guard !tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LexiError.input("タグ名を入力してください") }
        guard tag.color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw LexiError.input("色は #RRGGBB で指定してください") }
        try db.execute("UPDATE tags SET name=?,color=? WHERE id=?", [.text(tag.name), .text(tag.color), .text(tag.id)])
    }
    public func deleteTag(_ id: String) throws { try db.execute("DELETE FROM tags WHERE id=?", [.text(id)]) }
    public func addFolder(_ folderID: String, to entryID: String) throws {
        _ = try getEntry(entryID)
        try db.execute("INSERT OR IGNORE INTO entry_folders(entry_id,folder_id) VALUES(?,?)", [.text(entryID), .text(folderID)])
        try db.execute("INSERT OR IGNORE INTO entry_folder_manual(entry_id,folder_id) VALUES(?,?)", [.text(entryID), .text(folderID)])
    }
    public func removeFolder(_ folderID: String, from entryID: String) throws {
        _ = try getEntry(entryID)
        try db.execute("DELETE FROM entry_folder_sources WHERE entry_id=? AND folder_id=?", [.text(entryID), .text(folderID)])
        try db.execute("DELETE FROM entry_folder_manual WHERE entry_id=? AND folder_id=?", [.text(entryID), .text(folderID)])
        try db.execute("DELETE FROM entry_folders WHERE entry_id=? AND folder_id=?", [.text(entryID), .text(folderID)])
    }
    public func addTag(_ tagID: String, to entryID: String) throws {
        _ = try getEntry(entryID)
        try db.execute("INSERT OR IGNORE INTO entry_tags(entry_id,tag_id) VALUES(?,?)", [.text(entryID), .text(tagID)])
    }
    public func removeTag(_ tagID: String, from entryID: String) throws {
        try db.execute("DELETE FROM entry_tags WHERE entry_id=? AND tag_id=?", [.text(entryID), .text(tagID)])
    }
    // Explicit merge: unions classifications and aliases, and never silently overwrites differing dictionary bodies.
    public func mergeEntries(sourceID: String, targetID: String, dictionaryPreference: String = "reject") throws -> Entry {
        let source = try getEntry(sourceID)
        var target = try getEntry(targetID)
        guard source.id != target.id else { throw LexiError.input("同じ項目は統合できません") }
        guard ["reject","target","source"].contains(dictionaryPreference) else { throw LexiError.input("不正な本文優先設定です") }
        let dictionaryConflict = !source.dictionaryText.isEmpty && !target.dictionaryText.isEmpty && source.dictionaryText != target.dictionaryText
        if dictionaryConflict && dictionaryPreference == "reject" { throw LexiError.conflict("辞典本文が異なります。--dictionary-preference target|source を指定してください") }
        try db.transaction {
            if target.dictionaryText.isEmpty || (dictionaryConflict && dictionaryPreference == "source") {
                target.dictionaryText = source.dictionaryText
            }
            if target.note.isEmpty { target.note = source.note }
            else if !source.note.isEmpty && source.note != target.note {
                target.note += "\n\n—— 統合したノート ——\n" + source.note
            }
            if target.fullTitle.isEmpty { target.fullTitle = source.fullTitle }
            target.folderIDs = Array(Set(target.folderIDs + source.folderIDs))
            target.tagIDs = Array(Set(target.tagIDs + source.tagIDs))
            target.needsReview = target.needsReview || source.needsReview
            if target.parentID == source.id { target.parentID = source.parentID }
            try updateEntry(target)
            let children = try db.query("SELECT id FROM entries WHERE parent_id=?", [.text(source.id)]).compactMap { $0["id"]?.string }
            for child in children where child != target.id {
                try db.execute("UPDATE entries SET parent_id=? WHERE id=?", [.text(target.id), .text(child)])
            }
            // Preserve source IDs of both records. A primary source ID becomes an alias.
            try db.execute("UPDATE source_aliases SET entry_id=? WHERE entry_id=?", [.text(target.id), .text(source.id)])
            if let oldID = source.sourceID, oldID != target.sourceID {
                try db.execute("INSERT OR REPLACE INTO source_aliases(source_id,entry_id) VALUES(?,?)", [.text(oldID), .text(target.id)])
            }
            try db.execute("DELETE FROM entries WHERE id=?", [.text(source.id)])
        }
        return try getEntry(target.id)
    }
    public func sourceAliases() throws -> [LexiSourceAlias] {
        try db.query("SELECT source_id,entry_id FROM source_aliases").compactMap { row in
            guard let source = row["source_id"]?.string, let entry = row["entry_id"]?.string else { return nil }
            return LexiSourceAlias(sourceID:source,entryID:entry)
        }
    }
    public func backup(to destination: URL) throws {
        guard destination.standardizedFileURL != url.standardizedFileURL else { throw LexiError.input("データベースを上書きできません") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LexiError.conflict("バックアップ先にファイルが存在します") }
        try db.backup(to: destination)
    }
    public func dataVersion() throws -> Int { Int(try db.scalar("PRAGMA data_version").double ?? 0) }
    public func seedExamplesIfNeeded() throws {
        let already = try db.scalar("SELECT value FROM metadata WHERE key='examples_initialized'").string
        guard already == nil else { return }
        try db.transaction {
            if (try db.scalar("SELECT COUNT(*) FROM entries").double ?? 0) == 0 {
                let expressions = try createFolder(name: "日本語表現")
                let idioms = try createFolder(name: "慣用句", parentID: expressions.id)
                let study = try createFolder(name: "読書メモ")
                let important = try createTag(name: "重要", color: "#C7846C")
                let conversation = try createTag(name: "会話", color: "#82A6D4")
                let reading = try createTag(name: "読書", color: "#83AB81")
                let samples: [(String,String,EntryType,String,String)] = [
                    ("口", "くち【口】", .headword, "【サンプル本文】\n物を食べたり、言葉を発したりする部分。\n※この説明はデモ用であり、辞典からの引用ではありません。", "「口がうまい」などの表現も確認する。"),
                    ("口がうまい", "くちがうまい【口が上手い】", .idiom, "【サンプル本文】\n話し方が巧みで、人を納得させるのが得意である。", "褒め言葉とは限らない。"),
                    ("気が付く", "きがつく【気が付く】", .headword, "", "気づく、意識する。辞典未取得の例。"),
                    ("雨が降る", "雨が降る", .example, "", "天気に関する用例。"),
                    ("目を通す", "めをとおす【目を通す】", .idiom, "", "資料や文章を一通り読む。")
                ]
                for (i, tuple) in samples.enumerated() {
                    var e = try createEntry(title: tuple.0, fullTitle: tuple.1, type: tuple.2, note: tuple.4)
                    e.dictionaryText = tuple.3
                    e.folderIDs = [i == 3 ? study.id : (i == 1 || i == 4 ? idioms.id : expressions.id)]
                    e.tagIDs = i == 0 ? [important.id] : (i == 1 ? [conversation.id] : [reading.id])
                    try updateEntry(e)
                }
            }
            try db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('examples_initialized','1')")
        }
    }
    public func integrityCheck() throws -> String { try db.scalar("PRAGMA integrity_check").string ?? "unknown" }
    func dbTransaction<T>(_ work: () throws -> T) throws -> T { try db.transaction(work) }
    func rawExecute(_ sql: String, _ values: [SQLValue]) throws { try db.execute(sql, values) }

}
