import Foundation

public enum DictionaryDisplayText {
    public static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "{hyoki-s}", with: "・")
            .replacingOccurrences(of: "{ZS:/}", with: "／")
    }
}

public enum DictionarySourceIdentity {
    public static func normalizedKey(_ sourceKey: String) -> String? {
        let components = sourceKey.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              components[0].allSatisfy(\.isNumber),
              components[1].count == 4,
              components[1].allSatisfy(\.isHexDigit),
              let entryNumber = Int(components[0]) else { return nil }
        return "\(entryNumber)-\(components[1].uppercased())"
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let normalizedLeft = normalizedKey(lhs),
              let normalizedRight = normalizedKey(rhs) else { return false }
        return normalizedLeft == normalizedRight
    }

    public static func referenceCount(
        in document: DictionaryStructuredDocument,
        sourceKey: String
    ) -> Int {
        document.sections.reduce(0) { total, section in
            var count = total
            var insideReference = false
            for segment in section.segments {
                let matchesSource = segment.sourceID.map { matches($0, sourceKey) } ?? false
                if matchesSource && !insideReference { count += 1 }
                insideReference = matchesSource
            }
            return count
        }
    }
}

public enum EntryType: String, Codable, CaseIterable, Sendable {
    case headword, idiom, example
    public var japanese: String {
        switch self {
        case .headword: "見出し"
        case .idiom: "成句"
        case .example: "用例"
        }
    }
    public var scope: String { rawValue }
}

public struct Entry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var fullTitle: String
    public var type: EntryType
    public var note: String
    public var dictionaryText: String
    public var sourceID: String?
    public var parentID: String?
    public var needsReview: Bool
    public var createdAt: Double
    public var updatedAt: Double
    public var folderIDs: [String]
    public var tagIDs: [String]
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

    public init(id: String = UUID().uuidString, title: String, fullTitle: String = "", type: EntryType = .headword, note: String = "", dictionaryText: String = "", sourceID: String? = nil, parentID: String? = nil, needsReview: Bool = false, createdAt: Double = Date().timeIntervalSince1970, updatedAt: Double = Date().timeIntervalSince1970, folderIDs: [String] = [], tagIDs: [String] = [], dictionaryID: String? = nil, contentVersion: String? = nil, sourceEntryID: String? = nil, sourceSubentryID: String? = nil, dictionaryRawXML: String? = nil, dictionaryStructured: String? = nil, dictionarySearchText: String? = nil, dictionaryParserVersion: String? = nil, dictionaryContentHash: String? = nil, dictionaryParseStatus: String? = nil, dictionaryParseError: String? = nil, archiveVersion: String? = nil) {
        self.id = id; self.title = title; self.fullTitle = fullTitle; self.type = type
        self.note = note; self.dictionaryText = dictionaryText; self.sourceID = sourceID
        self.parentID = parentID; self.needsReview = needsReview
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.folderIDs = folderIDs; self.tagIDs = tagIDs
        self.dictionaryID = dictionaryID; self.contentVersion = contentVersion
        self.sourceEntryID = sourceEntryID; self.sourceSubentryID = sourceSubentryID
        self.dictionaryRawXML = dictionaryRawXML; self.dictionaryStructured = dictionaryStructured
        self.dictionarySearchText = dictionarySearchText; self.dictionaryParserVersion = dictionaryParserVersion
        self.dictionaryContentHash = dictionaryContentHash; self.dictionaryParseStatus = dictionaryParseStatus
        self.dictionaryParseError = dictionaryParseError; self.archiveVersion = archiveVersion
    }

    public var sourceIdentity: String? {
        guard let dictionaryID, let contentVersion, let sourceEntryID, let sourceSubentryID else { return nil }
        return [dictionaryID, contentVersion, sourceEntryID, sourceSubentryID].joined(separator: ":")
    }

    public var structuredDocument: DictionaryStructuredDocument? {
        guard let dictionaryStructured, let data = dictionaryStructured.data(using: .utf8) else { return nil }
        guard var document = try? JSONDecoder().decode(DictionaryStructuredDocument.self, from: data) else {
            return nil
        }
        document.heading = document.heading.map(DictionaryDisplayText.clean)
        document.headingSegments = document.headingSegments.map { segment in
            var clean = segment
            clean.text = DictionaryDisplayText.clean(clean.text)
            clean.reading = clean.reading.map(DictionaryDisplayText.clean)
            return clean
        }
        document.writtenForms = document.writtenForms.map(DictionaryDisplayText.clean)
        document.reading = DictionaryDisplayText.clean(document.reading)
        document.accent = DictionaryDisplayText.clean(document.accent)
        document.sections = document.sections.map { section in
            var clean = section
            clean.label = DictionaryDisplayText.clean(clean.label)
            clean.number = DictionaryDisplayText.clean(clean.number)
            clean.text = DictionaryDisplayText.clean(clean.text)
            clean.segments = clean.segments.map { segment in
                var clean = segment
                clean.text = DictionaryDisplayText.clean(clean.text)
                clean.reading = clean.reading.map(DictionaryDisplayText.clean)
                return clean
            }
            return clean
        }
        document.plainText = DictionaryDisplayText.clean(document.plainText)
        return document
    }

    public var hasUsableDictionary: Bool {
        let visibleBody = [dictionaryText, structuredDocument?.plainText ?? ""]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard visibleBody else { return false }
        guard type == .example else { return true }
        guard let sourceEntryID, let sourceSubentryID,
              let document = structuredDocument,
              document.entryKind == EntryType.headword.rawValue,
              let documentSourceEntryNumber = Int(document.sourceEntryID),
              let expectedSourceEntryNumber = Int(sourceEntryID),
              documentSourceEntryNumber == expectedSourceEntryNumber,
              !document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let expectedSourceID = "\(sourceEntryID)-\(sourceSubentryID)"
        return DictionarySourceIdentity.referenceCount(in: document, sourceKey: expectedSourceID) == 1
    }

    public var searchableDictionaryText: String {
        let indexedText = [dictionarySearchText, dictionaryText]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !indexedText.isEmpty { return indexedText.joined(separator: "\n") }
        return structuredDocument?.plainText ?? ""
    }
}

public struct EntrySummary: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let fullTitle: String
    public let type: EntryType
    public let sourceID: String?
    public let parentID: String?
    public let needsReview: Bool
    public let createdAt: Double
    public let updatedAt: Double
    public let folderIDs: [String]
    public let hasDictionary: Bool
    public let hasNote: Bool

    public var sameTitleCount: Int? = nil
    public var sameTitleInFolderCounts: [String: Int]? = nil
    public var duplicateCount: Int { sameTitleCount ?? 1 }

    public var folderCount: Int { folderIDs.count }
    public var belongsToMultipleFolders: Bool { folderCount > 1 }

    public var kanaSortKey: String {
        let candidate = fullTitle.isEmpty ? title : fullTitle
        let reading = candidate.components(separatedBy: "【").first ?? candidate
        return JapaneseSearch.normalized(reading)
    }
}

public struct EntrySummaryQuery: Equatable, Sendable {
    public var query: String
    public var type: EntryType?
    public var folderID: String?
    public var includeDescendantFolders: Bool
    public var hasDictionary: Bool?
    public var hasNote: Bool?
    public var unorganizedOnly: Bool

    public init(
        query: String = "",
        type: EntryType? = nil,
        folderID: String? = nil,
        includeDescendantFolders: Bool = true,
        hasDictionary: Bool? = nil,
        hasNote: Bool? = nil,
        unorganizedOnly: Bool = false
    ) {
        self.query = query
        self.type = type
        self.folderID = folderID
        self.includeDescendantFolders = includeDescendantFolders
        self.hasDictionary = hasDictionary
        self.hasNote = hasNote
        self.unorganizedOnly = unorganizedOnly
    }
}

public struct LexiWorkspaceSnapshot: Sendable {
    public let entries: [EntrySummary]
    public let folders: [Folder]
    public let folderCounts: [String: Int]

    public init(entries: [EntrySummary], folders: [Folder], folderCounts: [String: Int]) {
        self.entries = entries
        self.folders = folders
        self.folderCounts = folderCounts
    }
}

public struct DictionaryStructuredDocument: Codable, Equatable, Sendable {
    public var parserVersion: String
    public var entryKind: String
    public var sourceEntryID: String
    public var sourceSubentryID: String
    public var heading: [String]
    public var headingSegments: [DictionarySegment]
    public var reading: String
    public var writtenForms: [String]
    public var accent: String
    public var sections: [DictionarySection]
    public var plainText: String
    public var unknownTags: [String]
    public var parseStatus: String
}

public struct DictionarySourceResult: Sendable {
    public var matchedShortTitle: String? = nil
    public var providerName: String? = nil
    public let sourceKey: String
    public let sourceKind: EntryType
    public let rawXML: String
    public let structured: DictionaryStructuredDocument
    public let contentHash: String
    public let parserVersion: String
}

public struct DictionarySection: Codable, Equatable, Sendable, Identifiable {
    public var kind: String
    public var label: String
    public var number: String
    public var depth: Int?
    public var text: String
    public var segments: [DictionarySegment]
    public var id: String { "\(kind):\(number):\(label):\(text.prefix(24))" }
}

public struct DictionarySegment: Codable, Equatable, Sendable, Identifiable {
    public var kind: String
    public var text: String
    public var styles: [String]?
    public var reading: String?
    public var target: String?
    public var sourceID: String?
    public var id: String { "\(kind):\(target ?? ""):\(text):\(reading ?? "")" }
}

public struct Folder: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var sortOrder: Int
    public init(id: String = UUID().uuidString, name: String, parentID: String? = nil, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.parentID = parentID; self.sortOrder = sortOrder
    }
}

public struct Tag: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public init(id: String = UUID().uuidString, name: String, color: String = "#77A98B") {
        self.id = id; self.name = name; self.color = color
    }
}

public struct BookmarkImportReport: Codable, Sendable {
    public var inserted = 0
    public var updated = 0
    public var skipped = 0
    public var matched = 0
    public var unmatched = 0
    public var reviewed = 0
    public var warnings: [String] = []
    public init() {}
}

public struct SearchOptions: Sendable {
    public var query: String = ""
    public var type: EntryType? = nil
    public var folderID: String? = nil
    public var tagID: String? = nil
    public var hasDictionary: Bool? = nil
    public var hasNote: Bool? = nil
    public var sort: String = "updated"
    public var archiveMode: String = "current"
    public init(query: String = "", type: EntryType? = nil, folderID: String? = nil, tagID: String? = nil, hasDictionary: Bool? = nil, hasNote: Bool? = nil, sort: String = "updated", archiveMode: String = "current") {
        self.query = query; self.type = type; self.folderID = folderID; self.tagID = tagID
        self.hasDictionary = hasDictionary; self.hasNote = hasNote; self.sort = sort; self.archiveMode = archiveMode
    }
}

public enum EntryFiltering {
    public static func filter(
        entries: [Entry],
        folders: [Folder],
        tags: [Tag],
        navigation: String,
        typeFilter: String,
        query: String,
        dictionaryFilter: Bool?,
        noteFilter: Bool?,
        sortOrder: String
    ) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderID = navigation.hasPrefix("folder:") ? String(navigation.dropFirst(7)) : nil
        let tagID = navigation.hasPrefix("tag:") ? String(navigation.dropFirst(4)) : nil
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let tagByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
        var folderScope: Set<String>?
        if let folderID {
            folderScope = [folderID]
            var changed = true
            while changed {
                changed = false
                for folder in folders where folder.parentID.map({ folderScope?.contains($0) == true }) ?? false {
                    if folderScope?.insert(folder.id).inserted == true { changed = true }
                }
            }
        }

        return entries.filter { entry in
            if navigation == "archive" {
                if entry.archiveVersion == nil { return false }
            } else if entry.archiveVersion != nil {
                return false
            }
            if typeFilter != "all" && entry.type.rawValue != typeFilter { return false }
            if let folderScope, entry.folderIDs.allSatisfy({ !folderScope.contains($0) }) { return false }
            if let tagID, !entry.tagIDs.contains(tagID) { return false }
            if navigation == "missingDictionary", entry.hasUsableDictionary { return false }
            if navigation == "unorganized", (!entry.folderIDs.isEmpty || !entry.tagIDs.isEmpty) { return false }
            if let dictionaryFilter,
               entry.hasUsableDictionary != dictionaryFilter { return false }
            if let noteFilter, (!entry.note.isEmpty) != noteFilter { return false }
            guard !query.isEmpty else { return true }

            let folderNames = entry.folderIDs.compactMap { id -> String? in
                guard folderByID[id] != nil else { return nil }
                var path: [String] = []
                var current: String? = id
                var visited: Set<String> = []
                while let id = current, let folder = folderByID[id], visited.insert(id).inserted {
                    path.insert(folder.name, at: 0)
                    current = folder.parentID
                }
                return path.joined(separator: "/")
            }
            let tagNames = entry.tagIDs.compactMap { tagByID[$0] }
            let haystack = ([entry.title, entry.fullTitle, entry.searchableDictionaryText, entry.note]
                + folderNames + tagNames).joined(separator: "\n")
            return JapaneseSearch.contains(haystack, query)
        }.sorted { lhs, rhs in
            switch sortOrder {
            case "title":
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case "created":
                return lhs.createdAt == rhs.createdAt ? lhs.title < rhs.title : lhs.createdAt > rhs.createdAt
            case "type":
                return lhs.type.rawValue == rhs.type.rawValue ? lhs.title < rhs.title : lhs.type.rawValue < rhs.type.rawValue
            default:
                return lhs.updatedAt == rhs.updatedAt ? lhs.title < rhs.title : lhs.updatedAt > rhs.updatedAt
            }
        }
    }
}

public enum LexiError: Error, LocalizedError {
    case database(String)
    case input(String)
    case notFound(String)
    case conflict(String)
    public var errorDescription: String? {
        switch self {
        case .database(let s), .input(let s), .notFound(let s), .conflict(let s): s
        }
    }
}

public enum LexiPaths {
    public static var enclosingApplication: Bundle? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main }
        var location = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<8 {
            if location.pathExtension == "app", let bundle = Bundle(url: location) { return bundle }
            location = location.deletingLastPathComponent()
        }
        return nil
    }
    public static var databaseURL: URL {
        if enclosingApplication?.bundleIdentifier == "app.local.lexi.preview360" {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Lexi-3.6.0-Preview", isDirectory: true)
                .appendingPathComponent("Lexi.sqlite")
        }
        if let configuredPath = ProcessInfo.processInfo.environment["LEXI_DATABASE_PATH"],
           !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configuredPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Lexi", isDirectory: true).appendingPathComponent("Lexi.sqlite")
    }
    public static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Lexi", isDirectory: true).appendingPathComponent("Dictionary", isDirectory: true)
    }

}

public enum JapaneseSearch {
    public static func normalized(_ text: String) -> String {
        // NFKC: width; hiragana -> katakana for kana matching. No phonetic kanji inference.
        let canonical = text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
        return String(String.UnicodeScalarView(canonical.unicodeScalars.map { scalar in
            let n = scalar.value
            if (0x3041...0x3096).contains(n), let shifted = Unicode.Scalar(n + 0x60) { return shifted }
            return scalar
        }))
    }
    public static func contains(_ text: String, _ query: String) -> Bool {
        let q = normalized(query)
        return q.isEmpty || normalized(text).contains(q)
    }
}

public enum MonokakidoURL {
    public static func searchURL(title: String, type: EntryType) -> URL? {
        var c = URLComponents()
        c.scheme = "mkdictionaries"; c.host = ""; c.path = "/"
        c.queryItems = [URLQueryItem(name: "text", value: title), URLQueryItem(name: "category", value: "ja"), URLQueryItem(name: "scope", value: type.scope)]
        return c.url
    }
}
