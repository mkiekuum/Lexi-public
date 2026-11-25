import Foundation
import CryptoKit

public enum DictionarySourceError: Error, LocalizedError {
    case ambiguousTitle([DictionaryMatch])
    case identityMissing
    case identityMismatch
    case resourceUnavailable(String)
    case parserUnavailable
    case parserFailed(String)
    case sourceMismatch
    case emptyBody

    public var errorDescription: String? {
        switch self {
        case .ambiguousTitle:
            "一致する見出しが複数あります。選択してください。"
        case .identityMissing:
            "一致する辞典の見出しが見つかりませんでした。"
        case .identityMismatch:
            "項目と辞典の識別子が一致しません。"
        case .resourceUnavailable(let path):
            "辞典データを読み取れません。辞典の書き出し先を確認してください: \(path)"
        case .parserUnavailable:
            "辞典本文の解析環境が見つかりません。"
        case .parserFailed(let message):
            "辞典本文を解析できませんでした: \(message)"
        case .sourceMismatch:
            "辞典本文の識別子または項目種別が一致しません。既存の本文は変更していません。"
        case .emptyBody:
            "一致する辞典本文が空のため、保存しませんでした。"
        }
    }
}

public struct DictionaryMatch: Codable, Sendable, Equatable, Identifiable {
    public let dictionary: String
    public let shortTitle: String
    public let heading: String
    public let locator: String
    public var id: String { dictionary + ":" + locator }
}

public protocol DictionaryContentProvider: Sendable {
    func matches(for entry: Entry) async throws -> [DictionaryMatch]
    func retrieve(for entry: Entry, match: DictionaryMatch) async throws -> DictionarySourceResult
}

public extension DictionaryContentProvider {
    func retrieve(for entry: Entry) async throws -> DictionarySourceResult {
        let candidates = try await matches(for: entry)
        guard !candidates.isEmpty else { throw DictionarySourceError.identityMissing }
        guard candidates.count == 1 else { throw DictionarySourceError.ambiguousTitle(candidates) }
        return try await retrieve(for: entry, match: candidates[0])
    }
}

public actor DictionaryRegistry: DictionaryContentProvider {
    private let providers: [any DictionaryContentProvider]
    public init(providers: [any DictionaryContentProvider] = [LocalDictionaryProvider()]) {
        self.providers = providers
    }
    public func matches(for entry: Entry) async throws -> [DictionaryMatch] {
        var all: [DictionaryMatch] = []
        for provider in providers { all += try await provider.matches(for: entry) }
        return all.sorted { ($0.dictionary, $0.heading, $0.locator) < ($1.dictionary, $1.heading, $1.locator) }
    }
    public func retrieve(for entry: Entry, match: DictionaryMatch) async throws -> DictionarySourceResult {
        for provider in providers {
            if try await provider.matches(for: entry).contains(match) {
                return try await provider.retrieve(for: entry, match: match)
            }
        }
        throw DictionarySourceError.identityMissing
    }
}

public actor LocalDictionaryProvider: DictionaryContentProvider {
    private let dictionaryName: String
    private let contentsDirectory: URL
    private let parserURL: URL
    private let pythonURL: URL?
    private var exactTitleCache: [String: [DictionaryMatch]]?
    private var exactTitleFingerprint: String?

    public init(
        contentsDirectory: URL = LexiPaths.dictionaryContentsURL,
        parserURL: URL? = LexiPaths.dictionaryParserURL,
        pythonURL: URL? = nil,
        dictionaryName: String = "デジタル大辞泉"
    ) {
        self.dictionaryName = dictionaryName
        self.contentsDirectory = contentsDirectory
        self.parserURL = parserURL ?? URL(fileURLWithPath: "/")
        self.pythonURL = pythonURL ?? Self.findPython()
    }

    public func matches(for entry: Entry) async throws -> [DictionaryMatch] {
        try exactMatches(for: entry)
    }

    public func retrieve(for entry: Entry, match: DictionaryMatch) async throws -> DictionarySourceResult {
        guard try exactMatches(for: entry).contains(match) else { throw DictionarySourceError.identityMissing }
        let sourceKey = match.locator
        let parts = sourceKey.split(separator: "-").map(String.init)
        let sourceEntryID = parts[0]
        let sourceSubentryID = parts[1]
        let contentsDirectory = self.contentsDirectory
        let parserURL = self.parserURL
        let pythonURL = self.pythonURL
        let cancellation = ProcessCancellationBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                try Self.retrieveSynchronously(
                    entryType: entry.type,
                    sourceEntryID: sourceEntryID,
                    subentryID: sourceSubentryID,
                    sourceKey: sourceKey,
                    contentsDirectory: contentsDirectory,
                    parserURL: parserURL,
                    pythonURL: pythonURL,
                    cancellation: cancellation
                )
            }.value
            try Task.checkCancellation()
            var verified = result
            verified.matchedShortTitle = match.shortTitle
            verified.providerName = match.dictionary
            return verified
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func exactMatches(for entry: Entry) throws -> [DictionaryMatch] {
        let root = contentsDirectory.deletingLastPathComponent().appendingPathComponent("Headline")
        let files = ["headline.headlinestore.tsv", "short-headline.headlinestore.tsv"]
        func fingerprint() throws -> String {
            var fields = ["lexi-exact-short-v3", root.path, dictionaryName]
            for name in files {
                let url = root.appendingPathComponent(name)
                guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attr[.size] as? NSNumber, let date = attr[.modificationDate] as? Date else {
                    throw DictionarySourceError.resourceUnavailable(url.path)
                }
                fields += [name, size.stringValue, String(date.timeIntervalSince1970)]
            }
            return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let signature = try fingerprint()
        if exactTitleCache == nil || exactTitleFingerprint != signature {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Lexi/DictionaryIndex")
            let cache = dir?.appendingPathComponent(signature + ".json")
            if let cache, let data = try? Data(contentsOf: cache),
               let decoded = try? JSONDecoder().decode([String: [DictionaryMatch]].self, from: data) {
                exactTitleCache = decoded
            } else {
                func read(_ file: String, consume: @escaping (String, String) -> Void) throws {
                    let url = root.appendingPathComponent(file)
                    let content = try String(contentsOf: url, encoding: .utf8)
                    content.enumerateLines { line, stop in
                        if Task.isCancelled { stop = true; return }
                        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                        guard fields.count >= 2, DictionarySourceIdentity.normalizedKey(String(fields[0])) != nil else { return }
                        consume(String(fields[0]), DictionaryDisplayText.clean(String(fields[1])))
                    }
                    try Task.checkCancellation()
                }
                var headings: [String: String] = [:]
                try read(files[0]) { headings[$0] = $1 }
                var index: [String: [DictionaryMatch]] = [:]
                try read(files[1]) { key, title in
                    guard !title.isEmpty else { return }
                    let candidate = DictionaryMatch(dictionary: self.dictionaryName, shortTitle: title,
                                                    heading: headings[key] ?? title, locator: key)
                    if !(index[title]?.contains(candidate) ?? false) { index[title, default: []].append(candidate) }
                }
                for (key, title) in headings where key.suffix(4).hasPrefix("5") && !title.isEmpty {
                    let candidate = DictionaryMatch(dictionary: dictionaryName, shortTitle: title, heading: title, locator: key)
                    if !(index[title]?.contains(candidate) ?? false) { index[title, default: []].append(candidate) }
                }
                guard try fingerprint() == signature else { throw DictionarySourceError.resourceUnavailable(root.path) }
                exactTitleCache = index
                if let dir, let cache, let data = try? JSONEncoder().encode(index) {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try? data.write(to: cache, options: .atomic)
                }
            }
            exactTitleFingerprint = signature
        }
        // No kana folding, partial lookup, full-title fallback, or legacy source ID.
        let shortTitle = DictionaryDisplayText.clean(entry.title)
        return (exactTitleCache?[shortTitle] ?? []).filter { candidate in
            guard candidate.shortTitle.utf8.elementsEqual(shortTitle.utf8) else { return false }
            let suffix = candidate.locator.suffix(4)
            switch entry.type {
            case .headword: return suffix == "0000"
            case .idiom: return suffix.hasPrefix("4")
            case .example: return suffix.hasPrefix("5")
            }
        }.sorted { ($0.heading, $0.locator) < ($1.heading, $1.locator) }
    }

    private nonisolated static func retrieveSynchronously(
        entryType: EntryType,
        sourceEntryID: String,
        subentryID: String,
        sourceKey: String,
        contentsDirectory: URL,
        parserURL: URL,
        pythonURL: URL?,
        cancellation: ProcessCancellationBox
    ) throws -> DictionarySourceResult {
        let result: DictionarySourceResult
        if entryType == .example {
            let parent = try parseSynchronously(
                sourceEntryID: sourceEntryID,
                subentryID: "0000",
                expectedKind: .headword,
                contentsDirectory: contentsDirectory,
                parserURL: parserURL,
                pythonURL: pythonURL,
                cancellation: cancellation
            )
            guard DictionarySourceIdentity.referenceCount(
                in: parent.structured,
                sourceKey: sourceKey
            ) == 1 else { throw DictionarySourceError.sourceMismatch }
            result = DictionarySourceResult(
                sourceKey: sourceKey,
                sourceKind: .example,
                rawXML: parent.rawXML,
                structured: parent.structured,
                contentHash: parent.contentHash,
                parserVersion: parent.parserVersion
            )
        } else {
            result = try parseSynchronously(
                sourceEntryID: sourceEntryID,
                subentryID: subentryID,
                expectedKind: entryType,
                contentsDirectory: contentsDirectory,
                parserURL: parserURL,
                pythonURL: pythonURL,
                cancellation: cancellation
            )
        }
        return result
    }

    private nonisolated static func parseSynchronously(
        sourceEntryID: String,
        subentryID: String,
        expectedKind: EntryType,
        contentsDirectory: URL,
        parserURL: URL,
        pythonURL: URL?,
        cancellation: ProcessCancellationBox
    ) throws -> DictionarySourceResult {
        guard FileManager.default.fileExists(atPath: contentsDirectory.path) else {
            throw DictionarySourceError.resourceUnavailable(contentsDirectory.path)
        }
        guard FileManager.default.fileExists(atPath: parserURL.path) else {
            throw DictionarySourceError.parserFailed("辞典解析スクリプトが見つかりません")
        }
        guard let pythonURL else {
            throw DictionarySourceError.parserUnavailable
        }
        let sourceKey = "\(sourceEntryID)-\(subentryID)"
        let xmlURL = contentsDirectory.appendingPathComponent("\(sourceEntryID).xml")
        guard FileManager.default.fileExists(atPath: xmlURL.path) else {
            throw DictionarySourceError.resourceUnavailable(xmlURL.path)
        }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [parserURL.path, "--entry", xmlURL.path, "--source-key", sourceKey]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw DictionarySourceError.parserFailed(error.localizedDescription)
        }
        cancellation.install(process)
        defer { cancellation.clear(process) }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if cancellation.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DictionarySourceError.parserFailed(detail.isEmpty ? "終了コード \(process.terminationStatus)" : detail)
        }

        let decoded: ParserOutput
        do {
            decoded = try JSONDecoder().decode(ParserOutput.self, from: outputData)
        } catch {
            throw DictionarySourceError.parserFailed(error.localizedDescription)
        }
        guard decoded.sourceKey == sourceKey,
              decoded.sourceKind == expectedKind,
              decoded.structured.entryKind == expectedKind.rawValue else {
            throw DictionarySourceError.sourceMismatch
        }
        guard !decoded.structured.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !decoded.rawXML.isEmpty else {
            throw DictionarySourceError.emptyBody
        }
        return DictionarySourceResult(
            sourceKey: sourceKey,
            sourceKind: expectedKind,
            rawXML: decoded.rawXML,
            structured: decoded.structured,
            contentHash: decoded.contentHash,
            parserVersion: decoded.parserVersion
        )
    }

    private nonisolated static func findPython() -> URL? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

private final class ProcessCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if let current, current.isRunning { current.terminate() }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }
}

private struct ParserOutput: Decodable {
    let rawXML: String
    let structured: DictionaryStructuredDocument
    let contentHash: String
    let parserVersion: String
    let parseStatus: String
    let sourceKey: String
    let sourceKind: EntryType
}
