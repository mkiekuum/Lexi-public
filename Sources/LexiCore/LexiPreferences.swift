import Foundation

/// Shared by the GUI and local MCP, scoped to the selected database.
public struct LexiPreferences: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable {
        case light, dark
    }

    public var appearance: Appearance = .light
    public var fontFamily: String?
    public var fontSizeOffset: Int?
    public init(appearance: Appearance = .light, fontFamily: String? = nil, fontSizeOffset: Int? = nil) {
        self.appearance = appearance
        self.fontFamily = fontFamily
        self.fontSizeOffset = fontSizeOffset.map { min(6, max(-3, $0)) }
    }

    public static func url(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("preferences.json")
    }

    public static func load(for databaseURL: URL) throws -> Self {
        let path = url(for: databaseURL)
        guard FileManager.default.fileExists(atPath: path.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    public func save(for databaseURL: URL) throws {
        let path = Self.url(for: databaseURL)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
    }

    public static func mcpConfiguration(for databaseURL: URL) throws -> String {
        let standalone = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lexi-mcp")
        let bundled = LexiPaths.enclosingApplication?.resourceURL?.appendingPathComponent("LexiMCP")
        let executable = bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil } ?? standalone
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["lexi": [
            "command": executable.path, "args": ["--db", databaseURL.path]
        ]]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
