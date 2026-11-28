import Foundation

/// A user-selected, read-only source. The notebook database is independent.
public struct DictionarySourceConfiguration: Codable, Equatable, Sendable {
    public var directory: String?
    public init(directory: String? = nil) { self.directory = directory }
    public static func url(for database: URL) -> URL {
        database.appendingPathExtension("dictionary-source.json")
    }
    public static func load(for database: URL) throws -> Self {
        let file = url(for: database)
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }
        // An explicit environment override is useful for isolated QA or managed deployments.
        if let value = ProcessInfo.processInfo.environment["LEXI_DICTIONARY_PATH"], !value.isEmpty {
            return Self(directory: try resolve(URL(fileURLWithPath: value)).path)
        }
        return Self()
    }
    public func save(for database: URL) throws {
        let file = Self.url(for: database)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
    public static func resolve(_ selected: URL) throws -> URL {
        let root = selected.standardizedFileURL.resolvingSymlinksInPath()
        var candidates = [root, root.appendingPathComponent("DAIJISEN.J", isDirectory: true)]
        if ["Contents", "Headline"].contains(root.lastPathComponent) {
            candidates.append(root.deletingLastPathComponent())
        }
        for candidate in candidates where isCompatible(candidate) && hasRecognizedIndexes(candidate) { return candidate }
        throw LexiError.input("対応する辞典フォルダが見つかりません。デジタル大辞泉形式の Contents と Headline（2つのTSV索引）を含むフォルダを選択してください。")
    }
    public static func isCompatible(_ root: URL) -> Bool {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root.appendingPathComponent("Contents").path, isDirectory: &directory),
              directory.boolValue, fm.isReadableFile(atPath: root.appendingPathComponent("Contents").path) else { return false }
        for file in ["headline.headlinestore.tsv", "short-headline.headlinestore.tsv"] {
            let url = root.appendingPathComponent("Headline").appendingPathComponent(file)
            guard fm.isReadableFile(atPath: url.path),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 > 0 else { return false }
        }
        return true
    }
    private static func hasRecognizedIndexes(_ root: URL) -> Bool {
        for name in ["headline.headlinestore.tsv", "short-headline.headlinestore.tsv"] {
            let path = root.appendingPathComponent("Headline").appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65536), !data.isEmpty else { return false }
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            let recognized = lines.prefix(100).contains { line in
                let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count >= 2 else { return false }
                let key = String(fields[0]).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                guard DictionarySourceIdentity.normalizedKey(key) != nil, !fields[1].isEmpty else { return false }
                let entryID = key.split(separator: "-")[0]
                return FileManager.default.isReadableFile(atPath: root.appendingPathComponent("Contents/\(entryID).xml").path)
            }
            guard recognized else { return false }
        }
        return true
    }
    public var root: URL? { directory.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    public var available: Bool { root.map(Self.isCompatible) ?? false }
}

/// Resolve a trusted parser shipped with Lexi, never executable code supplied by a dictionary folder.
public enum DictionaryParserResource {
    public static func locate() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let parent = executable.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var options: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("daijisen_parser.py"),
            parent.appendingPathComponent("daijisen_parser.py"),
            parent.deletingLastPathComponent().appendingPathComponent("Resources/daijisen_parser.py"),
            home.appendingPathComponent(".local/share/lexi/daijisen_parser.py")
        ]
        var ancestor = parent
        for _ in 0..<6 {
            if ancestor.lastPathComponent.hasPrefix(".build") {
                options.append(ancestor.deletingLastPathComponent().appendingPathComponent("Scripts/daijisen_parser.py"))
                break
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return options.compactMap { $0 }.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }
}

/// Keep a cached provider for the current source, re-resolve on every new lookup.
public actor ConfiguredDictionaryProvider: DictionaryContentProvider {
    private let database: URL
    private let parser: URL?
    private var activeRoot: URL?
    private var activeProvider: LocalDictionaryProvider?
    public init(databaseURL: URL, parserURL: URL? = DictionaryParserResource.locate()) {
        database = databaseURL; parser = parserURL
    }
    private func configuration() throws -> URL {
        let settings = try DictionarySourceConfiguration.load(for: database)
        guard let root = settings.root else { throw LexiError.input("辞典が未接続です。辞典設定からフォルダを選択してください。") }
        guard settings.available else { throw DictionarySourceError.resourceUnavailable(root.path) }
        return root
    }
    public func matches(for entry: Entry) async throws -> [DictionaryMatch] {
        let root = try configuration()
        if activeRoot != root || activeProvider == nil {
            activeRoot = root
            activeProvider = LocalDictionaryProvider(contentsDirectory: root.appendingPathComponent("Contents"), parserURL: parser)
        }
        guard let activeProvider else { throw DictionarySourceError.identityMissing }
        let result = try await activeProvider.matches(for: entry)
        guard try configuration() == root else { throw LexiError.conflict("辞典の接続先が変更されました。") }
        return result
    }
    public func retrieve(for entry: Entry, match: DictionaryMatch) async throws -> DictionarySourceResult {
        let root = try configuration()
        guard activeRoot == root, let activeProvider else {
            throw LexiError.conflict("辞典の接続先が変更されました。もう一度検索してください。")
        }
        let result = try await activeProvider.retrieve(for: entry, match: match)
        guard try configuration() == root else { throw LexiError.conflict("辞典の接続先が変更されました。") }
        return result
    }
}
