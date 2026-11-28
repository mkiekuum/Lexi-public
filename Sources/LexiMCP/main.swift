import Foundation
import LexiCore

private struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: [String: JSONValue]?
}

private enum JSONRPCID: Decodable {
    case string(String)
    case integer(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .integer(try container.decode(Int.self))
        }

    }

    var value: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        }
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.any)
        case .array(let value): value.map(\.any)
        case .null: NSNull()
        }
    }
}

private struct BatchOperation: Codable {
    let op: String
    let id: String?
    let title: String?
    let fullTitle: String?
    let type: EntryType?
    let note: String?
    let folderID: String?
    let name: String?
    let parentID: String?

    enum CodingKeys: String, CodingKey {
        case op, id, title, type, note, name
        case fullTitle = "full_title"
        case folderID = "folder_id"
        case parentID = "parent_id"
    }

    init(
        op: String,
        id: String? = nil,
        title: String? = nil,
        fullTitle: String? = nil,
        type: EntryType? = nil,
        note: String? = nil,
        folderID: String? = nil,
        name: String? = nil,
        parentID: String? = nil
    ) {
        self.op = op
        self.id = id
        self.title = title
        self.fullTitle = fullTitle
        self.type = type
        self.note = note
        self.folderID = folderID
        self.name = name
        self.parentID = parentID
    }
}

private struct PendingBatch: Codable {
    let operations: [BatchOperation]
    let before: [String: Entry]
    let createdIDs: [String]
    let beforeFolders: [Folder]
    let createdFolderIDs: [String]
    let impactCount: Int
}

private struct PreviewBatch {
    let operations: [BatchOperation]
    let before: [String: Entry]
    let beforeFolders: [Folder]
}

private struct PortablePreviewResponse: Encodable {
    let previewToken: String
    let preview: LexiPortableImportPreview
    enum CodingKeys: String, CodingKey {
        case preview = "preview"
        case previewToken = "preview_token"
    }
}

private struct PortableImportResponse: Encodable {
    let preview: LexiPortableImportPreview
    let undoToken: String
    enum CodingKeys: String, CodingKey {
        case preview = "preview"
        case undoToken = "undo_token"
    }
}

private struct BatchPreviewResponse: Encodable {
    let previewToken: String
    let operationCount: Int
    let operations: [BatchOperation]
    enum CodingKeys: String, CodingKey {
        case operations
        case previewToken = "preview_token"
        case operationCount = "operation_count"
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private final class MCPServer {
    private let store: LexiStore
    private let dictionaryProvider: any DictionaryContentProvider
    private let logURL: URL
    private let undoURL: URL
    private var previews: [String: PreviewBatch] = [:]
    private var importPreviews: [String: LexiPortableArchive] = [:]
    private var undo: [String: PendingBatch] = [:]

    init(databaseURL: URL) throws {
        store = try LexiStore(url: databaseURL)
        dictionaryProvider = ConfiguredDictionaryProvider(databaseURL: databaseURL)
        let configuredLogPath = ProcessInfo.processInfo.environment["LEXI_MCP_LOG_PATH"]
        let logs = configuredLogPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Lexi", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = configuredLogPath.map(URL.init(fileURLWithPath:))
            ?? logs.appendingPathComponent("mcp-operations.jsonl")
        undoURL = databaseURL.appendingPathExtension("mcp-undo.json")
        if FileManager.default.fileExists(atPath: undoURL.path) {
            undo = try JSONDecoder().decode([String: PendingBatch].self, from: Data(contentsOf: undoURL))
        }
    }

    func run() async throws {
        while let line = readLine() {
            guard !line.isEmpty else { continue }
            do {
                let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(line.utf8))
                if let response = try await handle(request) {
                    try write(response)
                }
            } catch {
                try write([
                    "jsonrpc": "2.0",
                    "id": NSNull(),
                    "error": ["code": -32700, "message": error.localizedDescription]
                ])
            }
        }
    }

    private func handle(_ request: JSONRPCRequest) async throws -> [String: Any]? {
        guard request.jsonrpc == "2.0" else {
            return errorResponse(request.id, code: -32600, message: "Invalid JSON-RPC version")
        }
        if request.method.hasPrefix("notifications/") { return nil }
        switch request.method {
        case "initialize":
            return response(request.id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "lexi-local", "version": "3.7.0"]
            ])
        case "ping":
            return response(request.id, result: [String: String]())
        case "tools/list":
            return response(request.id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let params = request.params ?? [:]
            guard let name = params["name"]?.stringValue,
                  let arguments = params["arguments"]?.objectValue else {
                return errorResponse(request.id, code: -32602, message: "tools/call requires name and arguments")
            }
            let started = Date()
            do {
                let result = try await call(name: name, arguments: arguments)
                do {
                    try log(name: name, arguments: arguments, success: true, detail: "ok", elapsed: Date().timeIntervalSince(started))
                } catch {
                    return response(request.id, result: [
                        "content": [[
                            "type": "text",
                            "text": "操作は実行されましたが、操作ログに記録できませんでした: \(error.localizedDescription)"
                        ]],
                        "isError": true
                    ])
                }
                return response(request.id, result: [
                    "content": [["type": "text", "text": try jsonText(result)]],
                    "isError": false
                ])
            } catch let operationError {
                let message: String
                do {
                    try log(name: name, arguments: arguments, success: false, detail: operationError.localizedDescription, elapsed: Date().timeIntervalSince(started))
                    message = operationError.localizedDescription
                } catch let logError {
                    message = "\(operationError.localizedDescription)（操作ログの記録にも失敗: \(logError.localizedDescription)）"
                }
                return response(request.id, result: [
                    "content": [["type": "text", "text": message]],
                    "isError": true
                ])
            }
        default:
            return errorResponse(request.id, code: -32601, message: "Method not found")
        }
    }

    private func call(name: String, arguments: [String: JSONValue]) async throws -> Any {
        try validateArguments(name: name, arguments: arguments)
        switch name {
        case "lexi_status":
            let entries = try store.listEntrySummaries()
            let source = try DictionarySourceConfiguration.load(for: store.url)
            return [
                "version": "3.7.0", "transport": "stdio", "database": store.url.path,
                "entry_count": entries.count, "folder_count": try store.listFolders().count,
                "dictionary_available": source.available,
                "dictionary_format": source.format as Any? ?? NSNull(),
                "dictionary_directory": source.directory as Any? ?? NSNull(),
                "tool_count": Self.toolDefinitions.count,
                "configuration": try LexiPreferences.mcpConfiguration(for: store.url)
            ] as [String: Any]
        case "lexi_preferences":
            var preferences = try LexiPreferences.load(for: store.url)
            if let raw = arguments["appearance"]?.stringValue {
                guard let mode = LexiPreferences.Appearance(rawValue: raw) else {
                    throw LexiError.input("appearance は light または dark を指定してください")
                }
                preferences.appearance = mode
                try preferences.save(for: store.url)
            }
            return preferences
        case "lexi_dictionary_source":
            var source = try DictionarySourceConfiguration.load(for: store.url)
            let action = arguments["action"]?.stringValue ?? "get"
            if action != "connect", arguments["path"] != nil {
                throw LexiError.input("path は connect の場合のみ指定できます")
            }
            switch action {
            case "get": break
            case "connect":
                let url = try absoluteURL(required(arguments, "path"))
                source = DictionarySourceConfiguration(directory: try DictionarySourceConfiguration.resolve(url).path)
                try source.save(for: store.url)
            case "disconnect":
                source = DictionarySourceConfiguration()
                try source.save(for: store.url)
            default: throw LexiError.input("不明な操作です")
            }
            return ["directory": source.directory as Any? ?? NSNull(), "available": source.available,
                    "state": source.available ? "connected" : (source.directory == nil ? "disconnected" : "missing"),
                    "format": source.format as Any? ?? NSNull()] as [String: Any]
        case "lexi_backup":
            let path = try absoluteURL(required(arguments, "path"))
            try store.backup(to: path)
            return ["path": path.path, "created": true] as [String: Any]
        case "lexi_search":
            let query = arguments["query"]?.stringValue ?? ""
            let folderID = arguments["folder_id"]?.stringValue
            let type = try entryType(arguments["type"]?.stringValue)
            let summaries = try store.listEntrySummaries(EntrySummaryQuery(
                query: query,
                type: type,
                folderID: folderID,
                includeDescendantFolders: arguments["include_descendants"]?.boolValue ?? false,
                hasDictionary: arguments["has_dictionary"]?.boolValue,
                hasNote: arguments["has_note"]?.boolValue,
                unorganizedOnly: arguments["unorganized_only"]?.boolValue ?? false
            ))
            let limit = try integer(arguments["limit"], default: 100, range: 1...500, key: "limit")
            let offset = try integer(arguments["offset"], default: 0, range: 0...Int.max, key: "offset")
            return Array(summaries.dropFirst(offset).prefix(limit))
        case "lexi_get_entry":
            return try currentEntry(required(arguments, "id"))
        case "lexi_create_entry":
            let title = try required(arguments, "title")
            let type = try entryType(arguments["type"]?.stringValue) ?? .headword
            let entry = try store.withImportTransaction {
                let created = try store.createEntry(
                    title: title,
                    fullTitle: arguments["full_title"]?.stringValue ?? "",
                    type: type,
                    note: arguments["note"]?.stringValue ?? "",
                    id: arguments["id"]?.stringValue
                )
                if let folderID = arguments["folder_id"]?.stringValue {
                    try store.addFolder(folderID, to: created.id)
                }
                return try store.getEntry(created.id)
            }
            return entry
        case "lexi_update_entry":
            let id = try required(arguments, "id")
            return try store.withImportTransaction {
            var entry = try currentEntry(id)
            if let baseline = arguments["baseline_title"]?.stringValue,
               entry.title != baseline, entry.title != arguments["title"]?.stringValue {
                throw LexiError.conflict("項目名が変更されました。")
            }
            if let baseline = arguments["baseline_note"]?.stringValue,
               entry.note != baseline, entry.note != arguments["note"]?.stringValue {
                throw LexiError.conflict("ノートが変更されました。")
            }
            if let value = arguments["title"]?.stringValue { entry.title = value }
            if let value = arguments["full_title"]?.stringValue { entry.fullTitle = value }
            if let value = arguments["type"]?.stringValue { entry.type = try entryType(value) ?? entry.type }
            if let value = arguments["note"]?.stringValue { entry.note = value }
            if let value = arguments["folder_ids"]?.arrayValue {
                entry.folderIDs = try value.map {
                    guard case .string(let id) = $0 else { throw LexiError.input("folder_ids は文字列の配列で指定してください") }
                    return id
                }
            }
            try store.updateEntry(entry)
            return try currentEntry(id)
            }
        case "lexi_delete_entry":
            let id = try required(arguments, "id")
            let token = try required(arguments, "preview_token")
            guard let operations = previews[token]?.operations,
                  operations.count == 1,
                  operations[0].op == "delete_entry",
                  operations[0].id == id else {
                throw LexiError.conflict("削除内容に一致する有効なプレビューがありません")
            }
            return try applyPreview(token)
        case "lexi_list_folders":
            return try store.listFolders()
        case "lexi_browse_folder":
            let folderID = arguments["folder_id"]?.stringValue
            let folders = try store.listFolders()
            if let folderID, !folders.contains(where: { $0.id == folderID }) {
                throw LexiError.notFound("フォルダが見つかりません")
            }
            let entries = try store.listEntrySummaries(EntrySummaryQuery(folderID: folderID, includeDescendantFolders: false, unorganizedOnly: folderID == nil))
            let limit = try integer(arguments["limit"], default: 100, range: 1...500, key: "limit")
            let offset = try integer(arguments["offset"], default: 0, range: 0...Int.max, key: "offset")
            let list: [String: Any] = [
                "folders": try JSONSerialization.jsonObject(with: JSONEncoder().encode(folders.filter { $0.parentID == folderID })),
                "entries": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(entries.dropFirst(offset).prefix(limit)))),
                "entry_count": entries.count
            ]
            return list
        case "lexi_arrange_folders":
            let ids = try entryIDs(arguments["ids"])
            try store.arrangeFolders(ids, parentID: arguments["parent_id"]?.stringValue, beforeID: arguments["before_id"]?.stringValue)
            return try store.listFolders()
        case "lexi_create_folder":
            return try store.createFolder(name: required(arguments, "name"), parentID: arguments["parent_id"]?.stringValue)
        case "lexi_update_folder":
            let id = try required(arguments, "id")
            guard var folder = try store.listFolders().first(where: { $0.id == id }) else {
                throw LexiError.notFound("フォルダが見つかりません")
            }
            if let name = arguments["name"]?.stringValue { folder.name = name }
            if let parent = arguments["parent_id"] {
                switch parent {
                case .null: folder.parentID = nil
                case .string(let id): folder.parentID = id
                default: throw LexiError.input("parent_id は文字列または null を指定してください")
                }
            }
            try store.updateFolder(folder)
            return folder
        case "lexi_delete_folder":
            let id = try required(arguments, "id")
            let token = try required(arguments, "preview_token")
            guard let operations = previews[token]?.operations,
                  operations.count == 1,
                  operations[0].op == "delete_folder",
                  operations[0].id == id else {
                throw LexiError.conflict("削除内容に一致する有効なプレビューがありません")
            }
            return try applyPreview(token)
        case "lexi_update_note":
            let id = try required(arguments, "id")
            let service = try LexiDataService(url: store.url)
            return try await service.saveNote(entryID: id, note: required(arguments, "note", allowEmpty: true), baselineNote: arguments["baseline_note"]?.stringValue)
        case "lexi_dictionary_refresh":
            if let id = arguments["id"]?.stringValue {
                guard arguments["ids"] == nil else { throw LexiError.input("id または ids のいずれかを指定してください") }
                let entry = try currentEntry(id)
                let matches = try await dictionaryProvider.matches(for: entry)
                guard !matches.isEmpty else { throw DictionarySourceError.identityMissing }
                let choice = arguments["candidate"]?.stringValue
                let chosen: DictionaryMatch
                if let choice {
                    guard let match = matches.first(where: { $0.id == choice }) else { throw DictionarySourceError.identityMissing }
                    chosen = match
                } else if matches.count == 1 {
                    chosen = matches[0]
                } else {
                    return ["status": "ambiguous", "candidates": matches.map { ["candidate": $0.id, "heading": $0.heading, "dictionary": $0.dictionary] }] as [String: Any]
                }
                let result = try await dictionaryProvider.retrieve(for: entry, match: chosen)
                let changed = try store.refreshDictionaryContent(requested: entry, result: result)
                return ["updated": changed, "parser_version": result.parserVersion] as [String: Any]
            }
            let ids = try entryIDs(arguments["ids"])
            var results: [[String: Any]] = []
            for id in ids {
                do {
                    let entry = try currentEntry(id)
                    let result = try await dictionaryProvider.retrieve(for: entry)
                    let changed = try store.refreshDictionaryContent(requested: entry, result: result)
                    results.append(["id": id, "status": changed ? "updated" : "unchanged"])
                } catch DictionarySourceError.ambiguousTitle(let matches) {
                    results.append(["id": id, "status": "ambiguous", "candidates": matches.map {
                        ["candidate": $0.id, "heading": $0.heading, "dictionary": $0.dictionary]
                    }])
                } catch {
                    results.append(["id": id, "status": "failed", "error": error.localizedDescription])
                }
            }
            return ["results": results, "updated": results.filter { $0["status"] as? String == "updated" }.count,
                    "ambiguous": results.filter { $0["status"] as? String == "ambiguous" }.count,
                    "failed": results.filter { $0["status"] as? String == "failed" }.count] as [String: Any]
        case "lexi_batch_preview":
            var operations = try decodeOperations(arguments["operations"])
            operations = operations.map { operation in
                guard ["create_entry", "create_folder"].contains(operation.op), operation.id == nil else { return operation }
                return BatchOperation(
                    op: operation.op,
                    id: UUID().uuidString,
                    title: operation.title,
                    fullTitle: operation.fullTitle,
                    type: operation.type,
                    note: operation.note,
                    folderID: operation.folderID,
                    name: operation.name,
                    parentID: operation.parentID
                )
            }
            try validate(operations)
            let token = UUID().uuidString
            let snapshot = try capture(operations)
            previews[token] = PreviewBatch(
                operations: operations,
                before: snapshot.entries,
                beforeFolders: snapshot.folders
            )
            return BatchPreviewResponse(
                previewToken: token,
                operationCount: operations.count,
                operations: operations
            )
        case "lexi_batch_apply":
            return try applyPreview(required(arguments, "preview_token"))
        case "lexi_batch_rollback":
            return try rollback(required(arguments, "undo_token"))
        case "lexi_json_export":
            let archive = try store.portableArchive(folderID: arguments["folder_id"]?.stringValue)
            if let path = arguments["path"]?.stringValue {
                let url = try absoluteURL(path)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw LexiError.conflict("出力先は既に存在します") }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(archive).write(to: url, options: .withoutOverwriting)
                return ["path": url.path, "created": true] as [String: Any]
            }
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive))
        case "lexi_json_import_preview":
            guard (arguments["json"] != nil) != (arguments["path"] != nil) else {
                throw LexiError.input("json または path のどちらか一方を指定してください")
            }
            let data: Data
            if let path = arguments["path"]?.stringValue {
                data = try Data(contentsOf: absoluteURL(path))
            } else { data = Data(try required(arguments, "json").utf8) }
            let archive = try JSONDecoder().decode(LexiPortableArchive.self, from: data)
            let preview = try store.previewPortableImport(archive)
            let token = UUID().uuidString
            if preview.conflicts.isEmpty { importPreviews[token] = archive }
            return PortablePreviewResponse(previewToken: token, preview: preview)
        case "lexi_json_import":
            let token = try required(arguments, "preview_token")
            guard let archive = importPreviews.removeValue(forKey: token) else {
                throw LexiError.conflict("有効な JSON 取込プレビューがありません")
            }
            let preview = try store.previewPortableImport(archive)
            guard preview.conflicts.isEmpty else {
                throw LexiError.conflict("プレビュー後に競合が発生しました。再度プレビューしてください")
            }
            let existingEntries = Dictionary(
                uniqueKeysWithValues: try store.listEntries(SearchOptions(archiveMode: "all")).map { ($0.id, $0) }
            )
            let before = Dictionary(uniqueKeysWithValues: archive.entries.compactMap { incoming in
                existingEntries[incoming.id].map { (incoming.id, $0) }
            })
            let oldFolders = try store.listFolders()
            let newFolderIDs = try predictedNewFolderIDs(archive.folders, existing: oldFolders)
            let newEntryIDs = archive.entries.map(\.id).filter { existingEntries[$0] == nil }
            let undoToken = UUID().uuidString
            undo[undoToken] = PendingBatch(
                operations: [],
                before: before,
                createdIDs: newEntryIDs,
                beforeFolders: [],
                createdFolderIDs: newFolderIDs,
                impactCount: archive.entries.count + archive.folderLinks.count
            )
            try persistUndo()
            do {
                _ = try store.importPortableArchive(archive)
            } catch {
                undo.removeValue(forKey: undoToken)
                try? persistUndo()
                throw error
            }
            return PortableImportResponse(preview: preview, undoToken: undoToken)
        default:
            throw LexiError.notFound("Unknown tool: \(name)")
        }
    }

    private func currentEntry(_ id: String) throws -> Entry {
        let entry = try store.getEntry(id)
        guard entry.archiveVersion == nil else { throw LexiError.notFound("現行項目が見つかりません: \(id)") }
        return entry
    }

    private func validate(_ operations: [BatchOperation]) throws {
        guard !operations.isEmpty, operations.count <= 500 else {
            throw LexiError.input("一括操作は1〜500件で指定してください")
        }
        for operation in operations {
            switch operation.op {
            case "set_note", "set_type", "add_folder", "remove_folder", "delete_entry":
                guard let id = operation.id else { throw LexiError.input("一括操作に id がありません") }
                _ = try currentEntry(id)
                if operation.op == "set_type", operation.type == nil {
                    throw LexiError.input("set_type には type が必要です")
                }
                if ["add_folder", "remove_folder"].contains(operation.op),
                   operation.folderID == nil {
                    throw LexiError.input("フォルダ操作には folder_id が必要です")
                }
                if let folderID = operation.folderID,
                   !(try store.listFolders()).contains(where: { $0.id == folderID }) {
                    throw LexiError.notFound("フォルダが見つかりません: \(folderID)")
                }
            case "create_entry":
                guard let title = operation.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LexiError.input("create_entry には title が必要です")
                }
                if let id = operation.id, (try? store.getEntry(id)) != nil {
                    throw LexiError.conflict("作成する ID は既に使用されています: \(id)")
                }
            case "create_folder":
                guard let name = operation.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LexiError.input("create_folder には name が必要です")
                }
                if let parentID = operation.parentID,
                   !(try store.listFolders()).contains(where: { $0.id == parentID }) {
                    throw LexiError.notFound("親フォルダが見つかりません: \(parentID)")
                }
                if let id = operation.id,
                   (try store.listFolders()).contains(where: { $0.id == id }) {
                    throw LexiError.conflict("作成するフォルダ ID は既に使用されています: \(id)")
                }
            case "rename_folder", "delete_folder":
                guard let id = operation.id,
                      (try store.listFolders()).contains(where: { $0.id == id }) else {
                    throw LexiError.notFound("対象フォルダが見つかりません")
                }
                if operation.op == "rename_folder",
                   operation.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    throw LexiError.input("rename_folder には name が必要です")
                }
            default:
                throw LexiError.input("未対応の一括操作です: \(operation.op)")
            }
        }
    }

    private func decodeOperations(_ value: JSONValue?) throws -> [BatchOperation] {
        guard let value else { throw LexiError.input("operations がありません") }
        let data = try JSONSerialization.data(withJSONObject: value.any, options: [.fragmentsAllowed])
        return try JSONDecoder().decode([BatchOperation].self, from: data)
    }

    private func applyPreview(_ token: String) throws -> [String: Any] {
        guard let preview = previews[token] else {
            throw LexiError.conflict("プレビューが存在しないか、すでに使用されています")
        }
        let operations = preview.operations
        try validate(operations)
        let currentSnapshot = try capture(operations)
        guard currentSnapshot.entries == preview.before,
              currentSnapshot.folders == preview.beforeFolders else {
            previews.removeValue(forKey: token)
            throw LexiError.conflict("プレビュー後に対象データが変更されました。再度プレビューしてください")
        }
        previews.removeValue(forKey: token)
        let before = preview.before
        let beforeFolders = preview.beforeFolders
        let created = operations.filter { $0.op == "create_entry" }.compactMap(\.id)
        let createdFolders = operations.filter { $0.op == "create_folder" }.compactMap(\.id)
        let undoToken = UUID().uuidString
        undo[undoToken] = PendingBatch(
            operations: operations,
            before: before,
            createdIDs: created,
            beforeFolders: beforeFolders,
            createdFolderIDs: createdFolders,
            impactCount: operations.count
        )
        try persistUndo()
        do {
            try store.withImportTransaction {
                for operation in operations {
                switch operation.op {
                case "set_note":
                    var entry = try currentEntry(operation.id!)
                    entry.note = operation.note ?? ""
                    try store.updateEntry(entry)
                case "set_type":
                    var entry = try currentEntry(operation.id!)
                    entry.type = operation.type!
                    try store.updateEntry(entry)
                case "add_folder":
                    try store.addFolder(operation.folderID!, to: operation.id!)
                case "remove_folder":
                    try store.removeFolder(operation.folderID!, from: operation.id!)
                case "delete_entry":
                    try store.deleteEntry(operation.id!)
                case "create_entry":
                    let id = operation.id ?? UUID().uuidString
                    _ = try store.createEntry(
                        title: operation.title!,
                        fullTitle: operation.fullTitle ?? "",
                        type: operation.type ?? .headword,
                        note: operation.note ?? "",
                        id: id
                    )
                case "create_folder":
                    _ = try store.createFolder(
                        name: operation.name!,
                        parentID: operation.parentID,
                        id: operation.id
                    )
                case "rename_folder":
                    guard var folder = try store.listFolders().first(where: { $0.id == operation.id }) else {
                        throw LexiError.notFound("フォルダが見つかりません")
                    }
                    folder.name = operation.name!
                    try store.updateFolder(folder)
                case "delete_folder":
                    try store.deleteFolder(operation.id!)
                default:
                    throw LexiError.input("未対応の一括操作です")
                }
            }
            }
        } catch {
            undo.removeValue(forKey: undoToken)
            try? persistUndo()
            throw error
        }
        return ["applied": operations.count, "undo_token": undoToken]
    }

    private func capture(_ operations: [BatchOperation]) throws -> (entries: [String: Entry], folders: [Folder]) {
        var targetIDs = Set(operations.filter {
            ["set_note", "set_type", "add_folder", "remove_folder", "delete_entry"].contains($0.op)
        }.compactMap(\.id))
        let allEntries = try store.listEntries(SearchOptions(archiveMode: "all"))
        var folderIDs = Set<String>()
        let allFolders = try store.listFolders()
        for operation in operations where ["delete_folder", "rename_folder"].contains(operation.op) {
            guard let id = operation.id else { continue }
            folderIDs.insert(id)
            if operation.op == "delete_folder" {
                var changed = true
                while changed {
                    changed = false
                    for folder in allFolders where folder.parentID.map(folderIDs.contains) == true {
                        if folderIDs.insert(folder.id).inserted { changed = true }
                    }
                }
            }
        }
        if !folderIDs.isEmpty {
            for entry in allEntries where entry.folderIDs.contains(where: folderIDs.contains) {
                targetIDs.insert(entry.id)
            }
        }
        for id in Array(targetIDs) {
            for entry in allEntries where entry.parentID == id { targetIDs.insert(entry.id) }
        }
        var entries: [String: Entry] = [:]
        for id in targetIDs { entries[id] = try store.getEntry(id) }
        let folders = allFolders.filter { folderIDs.contains($0.id) }
        return (entries, folders)
    }

    private func predictedNewFolderIDs(_ incoming: [Folder], existing: [Folder]) throws -> [String] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var mappings: [String: String] = [:]
        var pending = incoming
        var created: [String] = []
        while !pending.isEmpty {
            var progressed = false
            for folder in pending {
                guard folder.parentID == nil || mappings[folder.parentID!] != nil else { continue }
                let parentID = folder.parentID.flatMap { mappings[$0] }
                if let current = existingByID[folder.id] {
                    guard current.name == folder.name, current.parentID == parentID else {
                        throw LexiError.conflict("フォルダ ID が JSON と一致しません: \(folder.id)")
                    }
                    mappings[folder.id] = current.id
                } else if let samePath = existing.first(where: { $0.name == folder.name && $0.parentID == parentID }) {
                    mappings[folder.id] = samePath.id
                } else {
                    mappings[folder.id] = folder.id
                    created.append(folder.id)
                }
                pending.removeAll { $0.id == folder.id }
                progressed = true
                break
            }
            guard progressed else { throw LexiError.input("JSON のフォルダ階層を解決できません") }
        }
        return created
    }

    private func persistUndo() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(undo)
        try FileManager.default.createDirectory(
            at: undoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: undoURL, options: .atomic)
    }

    private func rollback(_ token: String) throws -> [String: Any] {
        guard let batch = undo[token] else {
            throw LexiError.conflict("ロールバック用データが存在しないか、すでに使用されています")
        }
        try store.withImportTransaction {
            for id in batch.createdIDs where (try? store.getEntry(id)) != nil {
                try store.deleteEntry(id)
            }
            let existingFolderIDs = Set(try store.listFolders().map(\.id))
            var pendingFolders = batch.beforeFolders.filter { !existingFolderIDs.contains($0.id) }
            while !pendingFolders.isEmpty {
                var progressed = false
                for folder in pendingFolders {
                    if let parentID = folder.parentID,
                       !(try store.listFolders().contains(where: { $0.id == parentID })) {
                        continue
                    }
                    _ = try store.createFolder(name: folder.name, parentID: folder.parentID, id: folder.id)
                    pendingFolders.removeAll { $0.id == folder.id }
                    progressed = true
                    break
                }
                guard progressed else { throw LexiError.conflict("削除したフォルダ階層を復元できません") }
            }
            for folder in batch.beforeFolders {
                guard var current = try store.listFolders().first(where: { $0.id == folder.id }) else { continue }
                current.name = folder.name
                current.parentID = folder.parentID
                current.sortOrder = folder.sortOrder
                try store.updateFolder(current)
            }
            for entry in batch.before.values where (try? store.getEntry(entry.id)) == nil {
                _ = try store.createEntry(
                    title: entry.title,
                    fullTitle: entry.fullTitle,
                    type: entry.type,
                    note: entry.note,
                    sourceID: entry.sourceID,
                    createdAt: entry.createdAt,
                    needsReview: entry.needsReview,
                    id: entry.id
                )
            }
            for entry in batch.before.values {
                try store.updateEntry(entry)
            }
            for id in batch.createdFolderIDs {
                if (try store.listFolders()).contains(where: { $0.id == id }) {
                    try store.deleteFolder(id)
                }
            }
        }
        undo.removeValue(forKey: token)
        try persistUndo()
        return ["rolled_back": batch.impactCount]
    }

    private func entryIDs(_ value: JSONValue?) throws -> [String] {
        guard let list = value?.arrayValue, !list.isEmpty, list.count <= 500 else {
            throw LexiError.input("ids は1〜500件の配列で指定してください")
        }
        var seen = Set<String>()
        return try list.map { value in
            guard let id = value.stringValue, !id.isEmpty, seen.insert(id).inserted else {
                throw LexiError.input("ids に空欄または重複があります")
            }
            return id
        }
    }

    private func entryType(_ raw: String?) throws -> EntryType? {
        guard let raw else { return nil }
        guard let type = EntryType(rawValue: raw) else { throw LexiError.input("type は headword、idiom、example のいずれかで指定してください") }
        return type
    }

    private func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw LexiError.input("ローカルファイルの絶対パスを指定してください")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func integer(_ value: JSONValue?, default fallback: Int, range: ClosedRange<Int>, key: String) throws -> Int {
        guard let value else { return fallback }
        guard case .number(let number) = value, number.isFinite, number.rounded() == number,
              let result = Int(exactly: number), range.contains(result) else {
            throw LexiError.input("\(key) の範囲または型が不正です")
        }
        return result
    }

    private func validateArguments(name: String, arguments: [String: JSONValue]) throws {
        guard let tool = Self.toolDefinitions.first(where: { $0["name"] as? String == name }),
              let schema = tool["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: [String: Any]] else {
            throw LexiError.notFound("Unknown tool: \(name)")
        }
        for key in schema["required"] as? [String] ?? [] where arguments[key] == nil {
            throw LexiError.input("\(key) を指定してください")
        }
        for (key, value) in arguments {
            guard let rule = properties[key] else { throw LexiError.input("未対応の引数です: \(key)") }
            let types = (rule["type"] as? [String]) ?? [rule["type"] as? String ?? ""]
            let actual: String
            switch value {
            case .string: actual = "string"
            case .bool: actual = "boolean"
            case .number: actual = "integer"
            case .array: actual = "array"
            case .object: actual = "object"
            case .null: actual = "null"
            }
            guard types.contains(actual) else { throw LexiError.input("\(key) の型が不正です") }
            if let choices = rule["enum"] as? [String], let string = value.stringValue,
               !choices.contains(string) { throw LexiError.input("\(key) の値が不正です") }
        }
    }

    private func required(_ values: [String: JSONValue], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = values[key]?.stringValue,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LexiError.input("\(key) を指定してください")
        }
        return value
    }

    private func jsonText(_ value: Any) throws -> String {
        let data: Data
        if JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber {
            data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        } else if let encodable = value as? any Encodable {
            data = try JSONEncoder().encode(AnyEncodable(value: encodable))
        } else {
            throw LexiError.database("MCP 応答を JSON に変換できません")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func response(_ id: JSONRPCID?, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id?.value ?? NSNull(), "result": result]
    }

    private func errorResponse(_ id: JSONRPCID?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id?.value ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func write(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private func log(name: String, arguments: [String: JSONValue], success: Bool, detail: String, elapsed: TimeInterval) throws {
        let ids = ["id", "folder_id", "preview_token", "undo_token"].compactMap { arguments[$0]?.stringValue }
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "tool": name,
            "ids": ids,
            "success": success,
            "detail": detail,
            "elapsed_ms": Int(elapsed * 1000)
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                throw LexiError.database("MCP 操作ログを作成できません")
            }
        }
        let handle = try FileHandle(forWritingTo: logURL)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static let toolDefinitions: [[String: Any]] = [
        tool("lexi_status", "ローカルMCPの版、データ件数、辞典の利用可否とクライアント設定を取得します。", [:], []),
        tool("lexi_preferences", "外観を読み取り、必要なら light または dark に変更します。GUIにも反映されます。", [
            "appearance": ["type": "string", "enum": ["light", "dark"]]
        ], []),
        tool("lexi_dictionary_source", "辞典の状態確認(get)、接続・変更(connect: pathに絶対パス)、解除(disconnect)。GUI不要。保存済み本文は変更しません。", [
            "action": ["type": "string", "enum": ["get", "connect", "disconnect"]],
            "path": optionalString
        ], []),
        tool("lexi_backup", "SQLiteの整合性を保つローカルバックアップを作成します。既存ファイルは上書きしません。", [
            "path": stringSchema
        ], ["path"]),
        tool("lexi_search", "項目を検索します。フォルダ指定時は直下のみ。include_descendants:true で下位も検索します。", [
            "query": optionalString, "type": entryTypeSchema, "folder_id": optionalString,
            "has_dictionary": optionalBoolean, "has_note": optionalBoolean, "unorganized_only": optionalBoolean,
            "include_descendants": optionalBoolean,
            "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 100],
            "offset": ["type": "integer", "minimum": 0, "default": 0]
        ], []),
        tool("lexi_get_entry", "IDで項目と保存済み辞典情報を取得します。", ["id": stringSchema], ["id"]),
        tool("lexi_create_entry", "項目を作成し、必要ならフォルダに追加します。", [
            "id": optionalString, "title": stringSchema, "full_title": optionalString,
            "type": entryTypeSchema, "note": optionalString, "folder_id": optionalString
        ], ["title"]),
        tool("lexi_update_entry", "項目名、種別、ノート、フォルダ所属を変更します。", [
            "id": stringSchema, "title": optionalString, "full_title": optionalString,
            "type": entryTypeSchema, "note": optionalString, "folder_ids": stringArraySchema,
            "baseline_title": optionalString, "baseline_note": optionalString
        ], ["id"]),
        tool("lexi_delete_entry", "事前プレビューで発行したトークンを指定して項目を削除します。", [
            "id": stringSchema, "preview_token": stringSchema
        ], ["id", "preview_token"]),
        tool("lexi_list_folders", "フォルダと階層を一覧します。", [:], []),
        tool("lexi_browse_folder", "フォルダ直下のフォルダと項目をまとめて取得します。folder_id を省略すると最上位を表示します。", [
            "folder_id": optionalString, "limit": ["type": "integer", "minimum": 1, "maximum": 500],
            "offset": ["type": "integer", "minimum": 0]
        ], []),
        tool("lexi_arrange_folders", "複数フォルダを移動・並べ替えします。parent_id:null は最上位。before_id 省略時は末尾。", [
            "ids": stringArraySchema, "parent_id": ["type": ["string", "null"]], "before_id": optionalString
        ], ["ids", "parent_id"]),
        tool("lexi_create_folder", "フォルダを作成します。", [
            "name": stringSchema, "parent_id": optionalString
        ], ["name"]),
        tool("lexi_update_folder", "フォルダ名と移動先を変更します。parent_id:nullで最上位に移動します。循環参照は拒否します。", [
            "id": stringSchema, "name": optionalString, "parent_id": ["type": ["string", "null"]]
        ], ["id"]),
        tool("lexi_delete_folder", "事前プレビューで発行したトークンを指定してフォルダ階層を削除します。項目は削除せず所属だけを外します。", [
            "id": stringSchema, "preview_token": stringSchema
        ], ["id", "preview_token"]),
        tool("lexi_update_note", "個人ノートだけを更新します。", [
            "id": stringSchema, "note": stringSchema, "baseline_note": optionalString
        ], ["id", "note"]),
        tool("lexi_dictionary_refresh", "外部ローカル辞典から本文を更新します。id または ids を指定。複数の場合は個別結果を返します。ノートは変更しません。", [
            "id": stringSchema, "ids": stringArraySchema, "candidate": optionalString
        ], []),
        tool("lexi_batch_preview", "最大500件の一括変更・削除を検証し、実行トークンを返します。", [
            "operations": [
                "type": "array",
                "maxItems": 500,
                "items": [
                    "type": "object",
                    "properties": [
                        "op": ["type": "string", "enum": ["set_note", "set_type", "add_folder", "remove_folder", "delete_entry", "create_entry", "create_folder", "rename_folder", "delete_folder"]],
                        "id": optionalString,
                        "title": optionalString,
                        "full_title": optionalString,
                        "type": entryTypeSchema,
                        "note": optionalString,
                        "folder_id": optionalString,
                        "name": optionalString,
                        "parent_id": optionalString
                    ],
                    "required": ["op"],
                    "additionalProperties": false
                ]
            ]
        ], ["operations"]),
        tool("lexi_batch_apply", "確認済み一括操作を1トランザクションで実行し、ロールバックトークンを返します。", [
            "preview_token": stringSchema
        ], ["preview_token"]),
        tool("lexi_batch_rollback", "直前の一括操作を元に戻します。", [
            "undo_token": stringSchema
        ], ["undo_token"]),
        tool("lexi_json_export", "全データまたは指定フォルダと子フォルダを、辞典本文と参照 ID を含む移植用JSONとして出力します。", [
            "folder_id": optionalString, "path": optionalString
        ], []),
        tool("lexi_json_import_preview", "辞典正文を含まないLexi JSONの競合と変更件数をプレビューします。", [
            "json": optionalString, "path": optionalString
        ], []),
        tool("lexi_json_import", "事前プレビューで発行したトークンの JSON を1トランザクションで取り込み、ロールバック用トークンを返します。", [
            "preview_token": stringSchema
        ], ["preview_token"])
    ]

    private static let stringSchema: [String: Any] = ["type": "string"]
    private static let optionalString: [String: Any] = ["type": "string"]
    private static let optionalBoolean: [String: Any] = ["type": "boolean"]
    private static let stringArraySchema: [String: Any] = ["type": "array", "items": ["type": "string"]]
    private static let entryTypeSchema: [String: Any] = [
        "type": "string", "enum": ["headword", "idiom", "example"]
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: [String: Any]],
        _ required: [String]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ]
        ]
    }
}

let databaseURL: URL
if let index = CommandLine.arguments.firstIndex(of: "--db"),
   CommandLine.arguments.indices.contains(index + 1) {
    databaseURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
} else {
    databaseURL = LexiPaths.databaseURL
}

do {
    try await MCPServer(databaseURL: databaseURL).run()
} catch {
    FileHandle.standardError.write(Data("Lexi MCP 起動エラー: \(error.localizedDescription)\n".utf8))
    exit(1)
}
