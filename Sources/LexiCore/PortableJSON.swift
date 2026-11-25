import Foundation

public struct LexiPortableEntry: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let fullTitle: String
    public let type: EntryType
    public let note: String
    public let parentID: String?
    public let needsReview: Bool
    public let createdAt: Double
    public let archiveVersion: String?
    public let sourceID: String?
    public let dictionaryID: String?
    public let contentVersion: String?
    public let sourceEntryID: String?
    public let sourceSubentryID: String?
    public let dictionaryText: String?
    public let dictionaryRawXML: String?
    public let dictionaryStructured: String?
    public let dictionarySearchText: String?
    public let dictionaryParserVersion: String?
    public let dictionaryContentHash: String?
    public let dictionaryParseStatus: String?
    public let dictionaryParseError: String?

    public init(
        id: String,
        title: String,
        fullTitle: String,
        type: EntryType,
        note: String,
        parentID: String?,
        needsReview: Bool,
        createdAt: Double,
        archiveVersion: String?,
        sourceID: String? = nil,
        dictionaryID: String? = nil,
        contentVersion: String? = nil,
        sourceEntryID: String? = nil,
        sourceSubentryID: String? = nil,
        dictionaryText: String? = nil,
        dictionaryRawXML: String? = nil,
        dictionaryStructured: String? = nil,
        dictionarySearchText: String? = nil,
        dictionaryParserVersion: String? = nil,
        dictionaryContentHash: String? = nil,
        dictionaryParseStatus: String? = nil,
        dictionaryParseError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.fullTitle = fullTitle
        self.type = type
        self.note = note
        self.parentID = parentID
        self.needsReview = needsReview
        self.createdAt = createdAt
        self.archiveVersion = archiveVersion
        self.sourceID = sourceID
        self.dictionaryID = dictionaryID
        self.contentVersion = contentVersion
        self.sourceEntryID = sourceEntryID
        self.sourceSubentryID = sourceSubentryID
        self.dictionaryText = dictionaryText
        self.dictionaryRawXML = dictionaryRawXML
        self.dictionaryStructured = dictionaryStructured
        self.dictionarySearchText = dictionarySearchText
        self.dictionaryParserVersion = dictionaryParserVersion
        self.dictionaryContentHash = dictionaryContentHash
        self.dictionaryParseStatus = dictionaryParseStatus
        self.dictionaryParseError = dictionaryParseError
    }
}

public struct LexiPortableFolderLink: Codable, Equatable, Sendable {
    public let entryID: String
    public let folderID: String
}

public struct LexiPortableArchive: Codable, Equatable, Sendable {
    public let format: String
    public let version: Int
    public let entries: [LexiPortableEntry]
    public let folders: [Folder]
    public let folderLinks: [LexiPortableFolderLink]
    public let folderPaths: [String: String]

    private enum CodingKeys: String, CodingKey {
        case format, version, entries, folders, folderLinks, folderPaths
    }

    public init(
        format: String,
        version: Int,
        entries: [LexiPortableEntry],
        folders: [Folder],
        folderLinks: [LexiPortableFolderLink],
        folderPaths: [String: String] = [:]
    ) {
        self.format = format
        self.version = version
        self.entries = entries
        self.folders = folders
        self.folderLinks = folderLinks
        self.folderPaths = folderPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode([LexiPortableEntry].self, forKey: .entries)
        folders = try container.decode([Folder].self, forKey: .folders)
        folderLinks = try container.decode([LexiPortableFolderLink].self, forKey: .folderLinks)
        folderPaths = try container.decodeIfPresent([String: String].self, forKey: .folderPaths) ?? [:]
    }
}

public struct LexiPortableImportConflict: Codable, Equatable, Sendable {
    public let entryID: String
    public let title: String
    public let existingIDs: [String]
    public let reason: String
}

public struct LexiPortableImportIssue: Codable, Equatable, Sendable {
    public let item: String
    public let reason: String
}

public struct LexiPortableImportPlan: Sendable {
    public let archive: LexiPortableArchive
    public let invalidItems: [LexiPortableImportIssue]

    public static func decode(_ data: Data) throws -> LexiPortableImportPlan {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = root["entries"] as? [Any],
              let rawFolders = root["folders"] as? [Any] else {
            throw LexiError.input("JSON の基本構造が正しくありません。ファイルを確認してください。")
        }

        let decoder = JSONDecoder()
        var issues: [LexiPortableImportIssue] = []
        var validEntryObjects: [Any] = []
        var validEntries: [LexiPortableEntry] = []
        var seenIDs: Set<String> = []
        for (index, object) in rawEntries.enumerated() {
            let label = "項目 \(index + 1)"
            do {
                let entry = try decoder.decode(
                    LexiPortableEntry.self,
                    from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
                )
                guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      entry.createdAt.isFinite else {
                    issues.append(.init(item: label, reason: "ID、項目名、作成日時のいずれかが不正です"))
                    continue
                }
                guard seenIDs.insert(entry.id).inserted else {
                    issues.append(.init(item: entry.title, reason: "JSON 内で項目 ID が重複しています"))
                    continue
                }
                validEntries.append(entry)
                validEntryObjects.append(object)
            } catch {
                issues.append(.init(item: label, reason: "項目データの形式が正しくありません"))
            }
        }

        while true {
            let ids = Set(validEntries.map(\.id))
            let invalidIndexes = validEntries.indices.filter { index in
                guard let parentID = validEntries[index].parentID else { return false }
                return parentID == validEntries[index].id || !ids.contains(parentID)
            }
            guard !invalidIndexes.isEmpty else { break }
            for index in invalidIndexes.reversed() {
                issues.append(.init(
                    item: validEntries[index].title,
                    reason: "親項目が存在しないか、自分自身を参照しています"
                ))
                validEntries.remove(at: index)
                validEntryObjects.remove(at: index)
            }
        }

        let entriesByID = Dictionary(uniqueKeysWithValues: validEntries.map { ($0.id, $0) })
        let cyclicIDs = Set(validEntries.compactMap { entry -> String? in
            var visited: Set<String> = []
            var currentID: String? = entry.id
            while let id = currentID, let current = entriesByID[id] {
                guard visited.insert(id).inserted else { return id }
                currentID = current.parentID
            }
            return nil
        })
        if !cyclicIDs.isEmpty {
            for index in validEntries.indices.reversed() where cyclicIDs.contains(validEntries[index].id) {
                issues.append(.init(item: validEntries[index].title, reason: "親項目の関係が循環しています"))
                validEntries.remove(at: index)
                validEntryObjects.remove(at: index)
            }
            while true {
                let ids = Set(validEntries.map(\.id))
                let invalidIndexes = validEntries.indices.filter { index in
                    validEntries[index].parentID.map { !ids.contains($0) } ?? false
                }
                guard !invalidIndexes.isEmpty else { break }
                for index in invalidIndexes.reversed() {
                    issues.append(.init(item: validEntries[index].title, reason: "親項目が有効な JSON 項目に含まれていません"))
                    validEntries.remove(at: index)
                    validEntryObjects.remove(at: index)
                }
            }
        }

        var validFolderObjects: [Any] = []
        var validFolders: [Folder] = []
        var seenFolderIDs: Set<String> = []
        for (index, object) in rawFolders.enumerated() {
            do {
                let folder = try decoder.decode(
                    Folder.self,
                    from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
                )
                guard !folder.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    issues.append(.init(item: "フォルダ \(index + 1)", reason: "ID またはフォルダ名が不正です"))
                    continue
                }
                guard seenFolderIDs.insert(folder.id).inserted else {
                    issues.append(.init(item: folder.name, reason: "JSON 内でフォルダ ID が重複しています"))
                    continue
                }
                validFolders.append(folder)
                validFolderObjects.append(object)
            } catch {
                issues.append(.init(item: "フォルダ \(index + 1)", reason: "フォルダデータの形式が正しくありません"))
            }
        }
        while true {
            let ids = Set(validFolders.map(\.id))
            let invalidIndexes = validFolders.indices.filter { index in
                guard let parentID = validFolders[index].parentID else { return false }
                return parentID == validFolders[index].id || !ids.contains(parentID)
            }
            guard !invalidIndexes.isEmpty else { break }
            for index in invalidIndexes.reversed() {
                issues.append(.init(
                    item: validFolders[index].name,
                    reason: "親フォルダが存在しないか、自分自身を参照しています"
                ))
                validFolders.remove(at: index)
                validFolderObjects.remove(at: index)
            }
        }
        let foldersByID = Dictionary(uniqueKeysWithValues: validFolders.map { ($0.id, $0) })
        let cyclicFolderIDs = Set(validFolders.compactMap { folder -> String? in
            var visited: Set<String> = []
            var currentID: String? = folder.id
            while let id = currentID, let current = foldersByID[id] {
                guard visited.insert(id).inserted else { return id }
                currentID = current.parentID
            }
            return nil
        })
        if !cyclicFolderIDs.isEmpty {
            for index in validFolders.indices.reversed() where cyclicFolderIDs.contains(validFolders[index].id) {
                issues.append(.init(item: validFolders[index].name, reason: "親フォルダの関係が循環しています"))
                validFolders.remove(at: index)
                validFolderObjects.remove(at: index)
            }
            while true {
                let ids = Set(validFolders.map(\.id))
                let invalidIndexes = validFolders.indices.filter { index in
                    validFolders[index].parentID.map { !ids.contains($0) } ?? false
                }
                guard !invalidIndexes.isEmpty else { break }
                for index in invalidIndexes.reversed() {
                    issues.append(.init(item: validFolders[index].name, reason: "親フォルダが有効な JSON フォルダに含まれていません"))
                    validFolders.remove(at: index)
                    validFolderObjects.remove(at: index)
                }
            }
        }
        let validFolderIDs = Set(validFolders.map(\.id))
        let validEntryIDs = Set(validEntries.map(\.id))
        var validLinkObjects: [Any] = []
        if let rawLinks = root["folderLinks"] as? [Any] {
            for (index, object) in rawLinks.enumerated() {
                do {
                    let link = try decoder.decode(
                        LexiPortableFolderLink.self,
                        from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
                    )
                    guard validEntryIDs.contains(link.entryID), validFolderIDs.contains(link.folderID) else {
                        issues.append(.init(item: "所属情報 \(index + 1)", reason: "項目またはフォルダの参照先がありません"))
                        continue
                    }
                    validLinkObjects.append(object)
                } catch {
                    issues.append(.init(item: "所属情報 \(index + 1)", reason: "フォルダ所属データの形式が正しくありません"))
                }
            }
        } else {
            throw LexiError.input("JSON のフォルダ所属情報が正しくありません。")
        }
        root["entries"] = validEntryObjects
        root["folders"] = validFolderObjects
        root["folderLinks"] = validLinkObjects
        if let folderPaths = root["folderPaths"] as? [String: Any] {
            root["folderPaths"] = folderPaths.filter { validFolderIDs.contains($0.key) }
        }
        let sanitizedData = try JSONSerialization.data(withJSONObject: root, options: [.fragmentsAllowed])
        let archive = try decoder.decode(LexiPortableArchive.self, from: sanitizedData)
        return LexiPortableImportPlan(archive: archive, invalidItems: issues)
    }
}

public struct LexiPortableImportPreview: Codable, Equatable, Sendable {
    public let entriesToCreate: Int
    public let entriesToReuse: Int
    public let notesToFill: Int
    public let foldersToCreate: Int
    public let folderLinksToAdd: Int
    public let conflicts: [LexiPortableImportConflict]
    public let invalidItems: [LexiPortableImportIssue]

    public init(
        entriesToCreate: Int,
        entriesToReuse: Int,
        notesToFill: Int,
        foldersToCreate: Int,
        folderLinksToAdd: Int,
        conflicts: [LexiPortableImportConflict],
        invalidItems: [LexiPortableImportIssue] = []
    ) {
        self.entriesToCreate = entriesToCreate
        self.entriesToReuse = entriesToReuse
        self.notesToFill = notesToFill
        self.foldersToCreate = foldersToCreate
        self.folderLinksToAdd = folderLinksToAdd
        self.conflicts = conflicts
        self.invalidItems = invalidItems
    }

    public func includingInvalidItems(_ items: [LexiPortableImportIssue]) -> LexiPortableImportPreview {
        LexiPortableImportPreview(
            entriesToCreate: entriesToCreate,
            entriesToReuse: entriesToReuse,
            notesToFill: notesToFill,
            foldersToCreate: foldersToCreate,
            folderLinksToAdd: folderLinksToAdd,
            conflicts: conflicts,
            invalidItems: items
        )
    }
}

extension LexiStore {
    public func portableArchive(folderID: String? = nil) throws -> LexiPortableArchive {
        try portableArchive(folderIDs: folderID.map { [$0] })
    }

    public func portableArchive(folderIDs: [String]?) throws -> LexiPortableArchive {
        let allFolders = try listFolders()
        let allFolderIDs = Set(allFolders.map(\.id))
        var selectedFolderScope = allFolderIDs
        if let folderIDs {
            guard !folderIDs.isEmpty else { throw LexiError.input("フォルダを選択してください") }
            selectedFolderScope = Set(folderIDs)
            guard selectedFolderScope.isSubset(of: allFolderIDs) else {
                throw LexiError.notFound("指定したフォルダが見つかりません")
            }
            var changed = true
            while changed {
                changed = false
                for folder in allFolders where folder.parentID.map(selectedFolderScope.contains) == true {
                    if selectedFolderScope.insert(folder.id).inserted { changed = true }
                }
            }
        }

        var includedFolderIDs = selectedFolderScope
        if let folderIDs {
            let foldersByID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
            for folderID in folderIDs {
                var current = foldersByID[folderID]?.parentID
                var visited: Set<String> = [folderID]
                while let id = current, visited.insert(id).inserted,
                      let parent = foldersByID[id] {
                    includedFolderIDs.insert(id)
                    current = parent.parentID
                }
            }
        }
        let folders = allFolders.filter { includedFolderIDs.contains($0.id) }
        let allEntries = try listEntries()
        let entries = folderIDs == nil
            ? allEntries
            : allEntries.filter { $0.folderIDs.contains(where: selectedFolderScope.contains) }
        let entryIDs = Set(entries.map(\.id))
        let portableEntries = entries.map {
            LexiPortableEntry(
                id: $0.id,
                title: $0.title,
                fullTitle: $0.fullTitle,
                type: $0.type,
                note: $0.note,
                parentID: $0.parentID.flatMap { entryID in
                    entryIDs.contains(entryID) ? entryID : nil
                },
                needsReview: $0.needsReview,
                createdAt: $0.createdAt,
                archiveVersion: nil,
                sourceID: $0.sourceID,
                dictionaryID: $0.dictionaryID,
                contentVersion: $0.contentVersion,
                sourceEntryID: $0.sourceEntryID,
                sourceSubentryID: $0.sourceSubentryID,
                dictionaryText: $0.dictionaryText.isEmpty ? nil : $0.dictionaryText,
                dictionaryRawXML: $0.dictionaryRawXML,
                dictionaryStructured: $0.dictionaryStructured,
                dictionarySearchText: $0.dictionarySearchText,
                dictionaryParserVersion: $0.dictionaryParserVersion,
                dictionaryContentHash: $0.dictionaryContentHash,
                dictionaryParseStatus: $0.dictionaryParseStatus,
                dictionaryParseError: $0.dictionaryParseError
            )
        }
        let folderLinks = entries.flatMap { entry in
            entry.folderIDs.filter(selectedFolderScope.contains).map {
                LexiPortableFolderLink(entryID: entry.id, folderID: $0)
            }
        }
        let foldersByID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
        let folderPaths = Dictionary(uniqueKeysWithValues: folders.map { folder in
            var path = [folder.name]
            var parentID = folder.parentID
            var visited: Set<String> = [folder.id]
            while let id = parentID, let parent = foldersByID[id], visited.insert(id).inserted {
                path.insert(parent.name, at: 0)
                parentID = parent.parentID
            }
            return (folder.id, path.joined(separator: "/"))
        })
        return LexiPortableArchive(
            format: "lexi-portable",
            version: 1,
            entries: portableEntries,
            folders: folders,
            folderLinks: folderLinks,
            folderPaths: folderPaths
        )
    }

    public func exportPortableJSON(to destination: URL, folderID: String? = nil) throws {
        try exportPortableJSON(to: destination, folderIDs: folderID.map { [$0] })
    }

    public func exportPortableJSON(to destination: URL, folderIDs: [String]?) throws {
        let archive = try portableArchive(folderIDs: folderIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(archive).write(to: destination, options: .atomic)
    }

    public func previewPortableImport(_ archive: LexiPortableArchive) throws -> LexiPortableImportPreview {
        try validatePortableArchive(archive)
        let currentEntries = try listEntries(SearchOptions(archiveMode: "all"))
        let entriesByID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        let folders = try listFolders()
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var creates = 0
        var reuses = 0
        var notesToFill = 0
        var conflicts: [LexiPortableImportConflict] = []
        for incoming in archive.entries {
            if let existing = entriesByID[incoming.id] {
                if existing.type != incoming.type {
                    conflicts.append(.init(
                        entryID: incoming.id,
                        title: incoming.title,
                        existingIDs: [existing.id],
                        reason: "同じ ID の項目種別が一致しません"
                    ))
                } else if existing.title != incoming.title {
                    conflicts.append(.init(
                        entryID: incoming.id,
                        title: incoming.title,
                        existingIDs: [existing.id],
                        reason: "同じ ID の項目名が一致しません"
                    ))
                } else {
                    reuses += 1
                    if existing.note.isEmpty && !incoming.note.isEmpty { notesToFill += 1 }
                    if let incomingParentID = incoming.parentID,
                       let existingParentID = existing.parentID,
                       incomingParentID != existingParentID {
                        conflicts.append(.init(
                            entryID: incoming.id,
                            title: incoming.title,
                            existingIDs: [existing.id],
                            reason: "既存項目の親項目が JSON と一致しません"
                        ))
                    }
                }
                continue
            }
            creates += 1
        }

        var foldersToCreate = 0
        var folderIDMap: [String: String] = [:]
        var pendingFolders = archive.folders
        while !pendingFolders.isEmpty {
            var progressed = false
            for folder in pendingFolders {
                guard folder.parentID == nil || folderIDMap[folder.parentID!] != nil else { continue }
                let mappedParentID = folder.parentID.flatMap { folderIDMap[$0] }
                if let existing = foldersByID[folder.id] {
                    if existing.name != folder.name || existing.parentID != mappedParentID {
                        conflicts.append(.init(
                            entryID: folder.id,
                            title: folder.name,
                            existingIDs: [existing.id],
                            reason: "同じ ID のフォルダ階層が一致しません"
                        ))
                    }
                    folderIDMap[folder.id] = existing.id
                } else if let samePath = folders.first(where: {
                    $0.name == folder.name && $0.parentID == mappedParentID
                }) {
                    folderIDMap[folder.id] = samePath.id
                } else {
                    foldersToCreate += 1
                    folderIDMap[folder.id] = folder.id
                }
                pendingFolders.removeAll { $0.id == folder.id }
                progressed = true
                break
            }
            if !progressed {
                conflicts.append(.init(
                    entryID: "folder-tree",
                    title: "フォルダ階層",
                    existingIDs: [],
                    reason: "JSON のフォルダ階層に循環または不足があります"
                ))
                break
            }
        }

        var linksToAdd = 0
        for link in archive.folderLinks {
            guard let entry = entriesByID[link.entryID] else {
                linksToAdd += 1
                continue
            }
            if let destinationFolderID = folderIDMap[link.folderID],
               !entry.folderIDs.contains(destinationFolderID) {
                linksToAdd += 1
            }
        }
        return LexiPortableImportPreview(
            entriesToCreate: creates,
            entriesToReuse: reuses,
            notesToFill: notesToFill,
            foldersToCreate: foldersToCreate,
            folderLinksToAdd: linksToAdd,
            conflicts: conflicts
        )
    }

    public func importPortableArchive(_ archive: LexiPortableArchive) throws -> LexiPortableImportPreview {
        let preview = try previewPortableImport(archive)
        guard preview.conflicts.isEmpty else {
            throw LexiError.conflict("JSON 取込に未解決の競合があります。プレビューを確認してください")
        }
        try withImportTransaction {
            let existingFolders = try listFolders()
            let foldersByID = Dictionary(uniqueKeysWithValues: existingFolders.map { ($0.id, $0) })
            var folderIDMap: [String: String] = [:]
            var pending = archive.folders
            while !pending.isEmpty {
                var progressed = false
                for folder in pending {
                    guard folder.parentID == nil || folderIDMap[folder.parentID!] != nil
                    else { continue }
                    let parentID = folder.parentID.flatMap { folderIDMap[$0] }
                    if let existing = foldersByID[folder.id] {
                        folderIDMap[folder.id] = existing.id
                        pending.removeAll { $0.id == folder.id }
                        progressed = true
                        break
                    }
                    if let samePath = existingFolders.first(where: {
                        $0.name == folder.name && $0.parentID == parentID
                    }) {
                        folderIDMap[folder.id] = samePath.id
                        pending.removeAll { $0.id == folder.id }
                        progressed = true
                        break
                    }
                    let created = try createFolder(name: folder.name, parentID: parentID, id: folder.id)
                    folderIDMap[folder.id] = created.id
                    pending.removeAll { $0.id == folder.id }
                    progressed = true
                    break
                }
                guard progressed else { throw LexiError.input("JSON のフォルダ階層に循環または不足があります") }
            }

            var entriesByID = Dictionary(uniqueKeysWithValues: try listEntries(SearchOptions(archiveMode: "all")).map { ($0.id, $0) })
            for incoming in archive.entries where entriesByID[incoming.id] == nil {
                let created = try createEntry(
                    title: incoming.title,
                    fullTitle: incoming.fullTitle,
                    type: incoming.type,
                    note: incoming.note,
                    createdAt: incoming.createdAt,
                    needsReview: incoming.needsReview,
                    id: incoming.id
                )
                entriesByID[incoming.id] = created
            }
            for incoming in archive.entries {
                guard var existing = try? getEntry(incoming.id) else {
                    throw LexiError.notFound("JSON 項目が見つかりません: \(incoming.id)")
                }
                var existingChanged = false
                if existing.note.isEmpty && !incoming.note.isEmpty {
                    existing.note = incoming.note
                    existingChanged = true
                }
                if let parentID = incoming.parentID {
                    guard entriesByID[parentID] != nil else {
                        throw LexiError.conflict("親項目が JSON に含まれていません: \(parentID)")
                    }
                    if existing.parentID == nil && existing.id != parentID {
                        existing.parentID = parentID
                        existingChanged = true
                    }
                }
                if existing.dictionaryText.isEmpty && existing.dictionaryStructured == nil {
                    if let body = incoming.dictionaryText, !body.isEmpty {
                        // Validate structured source identity where present. Legacy plain-text exports remain readable.
                        if let raw = incoming.dictionaryStructured {
                            let document = try JSONDecoder().decode(DictionaryStructuredDocument.self, from: Data(raw.utf8))
                            guard !document.plainText.isEmpty,
                                  let entryID = incoming.sourceEntryID,
                                  let subID = incoming.sourceSubentryID,
                                  Int(document.sourceEntryID) == Int(entryID),
                                  (document.entryKind == existing.type.rawValue &&
                                   document.sourceSubentryID.uppercased() == subID.uppercased())
                                  || (existing.type == .example && document.entryKind == "headword" &&
                                      DictionarySourceIdentity.referenceCount(in: document, sourceKey: entryID + "-" + subID) == 1)
                            else { throw LexiError.conflict("JSON 辞典本文の識別子が一致しません: " + existing.title) }
                        }
                        existing.dictionaryText = body
                        existing.dictionaryRawXML = incoming.dictionaryRawXML
                        existing.dictionaryStructured = incoming.dictionaryStructured
                        existing.dictionarySearchText = incoming.dictionarySearchText
                        existing.dictionaryParserVersion = incoming.dictionaryParserVersion
                        existing.dictionaryContentHash = incoming.dictionaryContentHash
                        existing.dictionaryParseStatus = incoming.dictionaryParseStatus
                        existing.dictionaryParseError = incoming.dictionaryParseError
                        existingChanged = true
                    }
                    // IDs are references, never the identity of the user's independent entry.
                    if existing.sourceEntryID == nil && existing.sourceSubentryID == nil {
                        existing.sourceEntryID = incoming.sourceEntryID
                        existing.sourceSubentryID = incoming.sourceSubentryID
                        existing.sourceID = incoming.sourceID
                        existing.dictionaryID = incoming.dictionaryID
                        existing.contentVersion = incoming.contentVersion
                        existingChanged = existingChanged || incoming.sourceEntryID != nil || incoming.sourceID != nil || incoming.dictionaryID != nil
                    } else if incoming.dictionaryText?.isEmpty == false &&
                        (existing.sourceEntryID != incoming.sourceEntryID || existing.sourceSubentryID != incoming.sourceSubentryID) {
                        throw LexiError.conflict("JSON 辞典 ID が既存の参照と一致しません: " + existing.title)
                    }
                }
                if existingChanged { try updateEntry(existing) }
            }
            for link in archive.folderLinks {
                guard let folderID = folderIDMap[link.folderID],
                      entriesByID[link.entryID] != nil else {
                    throw LexiError.input("JSON のフォルダ所属先が不正です")
                }
                try addFolder(folderID, to: link.entryID)
            }
        }
        return preview
    }

    public func importPortableJSON(from source: URL) throws -> LexiPortableImportPreview {
        let archive = try JSONDecoder().decode(LexiPortableArchive.self, from: Data(contentsOf: source))
        return try importPortableArchive(archive)
    }

    private func validatePortableArchive(_ archive: LexiPortableArchive) throws {
        guard archive.format == "lexi-portable", archive.version == 1 else {
            throw LexiError.input("未対応の Lexi JSON 形式です")
        }
        let entryIDs = archive.entries.map(\.id)
        let folderIDs = archive.folders.map(\.id)
        guard Set(entryIDs).count == entryIDs.count, Set(folderIDs).count == folderIDs.count else {
            throw LexiError.conflict("JSON 内で項目 ID またはフォルダ ID が重複しています")
        }
        let entrySet = Set(entryIDs)
        let folderSet = Set(folderIDs)
        guard archive.folderLinks.allSatisfy({ entrySet.contains($0.entryID) && folderSet.contains($0.folderID) }) else {
            throw LexiError.input("JSON に不正なフォルダ所属関係があります")
        }
        guard archive.entries.allSatisfy({
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.createdAt.isFinite
                && ($0.parentID == nil || entrySet.contains($0.parentID!))
        }) else {
            throw LexiError.input("JSON に項目名または親項目 ID の不整合があります")
        }
    }

    private static func portableDuplicateKey(title: String, type: EntryType) -> String {
        "\(type.rawValue)\u{1f}\(JapaneseSearch.normalized(title))"
    }
}
