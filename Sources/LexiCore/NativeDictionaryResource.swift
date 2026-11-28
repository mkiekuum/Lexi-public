import Foundation
import CryptoKit

/// Read a supported installed product without writing to its resource directory.
public enum NativeDictionaryResource {
    public static func executable() -> URL? {
        let path = ProcessInfo.processInfo.environment["LEXI_NATIVE_READER"]
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let candidates = [
            LexiPaths.enclosingApplication?.resourceURL?.appendingPathComponent("lexi-dictionary-reader"),
            binary.deletingLastPathComponent().appendingPathComponent("lexi-dictionary-reader"),
            path.map { URL(fileURLWithPath: $0) },
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/lexi/lexi-dictionary-reader")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func resource(_ root: URL) -> URL {
        return root.appendingPathComponent("Contents/Shogakukan-DJS", isDirectory: true)
    }

    public static func recognizes(_ root: URL) -> Bool {
        let base = resource(root)
        let required = ["headline/headline.headlinestore", "headline/short-headline.headlinestore",
                        "contents/contents.idx", "contents/contents.map"]
        return required.allSatisfy { FileManager.default.isReadableFile(atPath: base.appendingPathComponent($0).path) }
    }

    public static func probe(_ root: URL) throws {
        guard recognizes(root) else { throw DictionarySourceError.resourceUnavailable(root.path) }
        guard let helper = executable() else { throw DictionarySourceError.parserUnavailable }
        let result = try run(helper, ["probe", root.path])
        guard String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "DAIJISEN.J" else {
            throw DictionarySourceError.identityMismatch
        }
    }

    private static func signature(_ root: URL) throws -> String {
        let base = resource(root)
        var values = ["lexi-native-index-v1", root.path]
        for name in ["headline/headline.headlinestore", "headline/short-headline.headlinestore",
                     "contents/contents.idx", "contents/contents.map"] {
            let url = base.appendingPathComponent(name)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber,
                  let modified = attrs[.modificationDate] as? Date else {
                throw DictionarySourceError.resourceUnavailable(url.path)
            }
            values += [name, size.stringValue, String(modified.timeIntervalSince1970)]
        }
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Generate only the two small headline indexes. No article files are exported.
    static func headlineDirectory(_ root: URL) throws -> URL {
        guard let helper = executable(), recognizes(root) else {
            throw DictionarySourceError.resourceUnavailable(root.path)
        }
        let key = try signature(root)
        let fm = FileManager.default
        let cacheBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lexi/NativeHeadlines", isDirectory: true)
        try fm.createDirectory(at: cacheBase, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final = cacheBase.appendingPathComponent(key, isDirectory: true)
        func valid(_ folder: URL) -> Bool {
            ["headline.headlinestore.tsv", "short-headline.headlinestore.tsv"].allSatisfy {
                let url = folder.appendingPathComponent("Headline").appendingPathComponent($0)
                return ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) > 0
            }
        }
        if valid(final) { return final.appendingPathComponent("Headline") }
        let stage = cacheBase.appendingPathComponent(".stage-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        _ = try run(helper, ["index", root.path, stage.path])
        guard valid(stage), try signature(root) == key else {
            throw DictionarySourceError.resourceUnavailable(root.path)
        }
        do { try fm.moveItem(at: stage, to: final) }
        catch {
            // Another GUI/MCP process may have completed the same index first.
            guard valid(final) else { throw error }
        }
        return final.appendingPathComponent("Headline")
    }

    /// Capture only a single requested article in memory. The existing parser handles the XML.
    static func readArticle(_ root: URL, pageID: String, cancellation: ProcessCancellationBox) throws -> Data {
        guard let helper = executable(), recognizes(root),
              !pageID.isEmpty, pageID.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw DictionarySourceError.resourceUnavailable(root.path)
        }
        return try run(helper, ["entry", root.path, pageID], cancellation: cancellation)
    }

    private static func run(_ helper: URL, _ args: [String], cancellation: ProcessCancellationBox? = nil) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        // Use a private temp stderr file to avoid blocking on a second pipe.
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("lexi-native-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let errPath = temp.appendingPathComponent("stderr")
        guard fm.createFile(atPath: errPath.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DictionarySourceError.parserUnavailable
        }
        let stderr = try FileHandle(forWritingTo: errPath)
        defer { try? stderr.close() }
        process.executableURL = helper
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        cancellation?.install(process)
        defer { cancellation?.clear(process) }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errPath, encoding: .utf8)) ?? ""
            throw DictionarySourceError.parserFailed(String(message.prefix(400)))
        }
        return data
    }
}
