// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "LexiCore", targets: ["LexiCore"]),
    .executable(name: "LexiMCP", targets: ["LexiMCP"])
]
// Link SQLite from the active macOS SDK; do not pull a newer Homebrew dylib.
#if os(macOS)
let sqliteTarget: Target = .systemLibrary(name: "CSQLite")
#else
let sqliteTarget: Target = .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])])
#endif
var targets: [Target] = [
    sqliteTarget,
    .target(name: "LexiCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "LexiMCP", dependencies: ["LexiCore"]),
    .testTarget(name: "LexiCoreTests", dependencies: ["LexiCore"])
]
#if os(macOS)
// GUI and MCP server must have distinct product names on case-insensitive APFS.
products.append(.executable(name: "LexiDesktop", targets: ["LexiApp"]))
targets.append(.executableTarget(name: "LexiApp", dependencies: ["LexiCore"]))
targets.append(.testTarget(name: "LexiAppTests", dependencies: ["LexiApp"]))
#endif
let package = Package(name: "Lexi", platforms: [.macOS(.v14)], products: products, targets: targets)
