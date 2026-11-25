import XCTest
import AppKit
import SwiftUI
import LexiCore
@testable import LexiApp

final class LexiLayoutTests: XCTestCase {
    /// Renders only application-owned views with synthetic data, never the user's screen.
    @MainActor
    func testWorkspaceLayoutsWithSyntheticData() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEXI_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LEXI_UI_SNAPSHOT_DIR to render isolated layout previews")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lexi-layout-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let databaseURL = temporary.appendingPathComponent("fixture.sqlite")
        let store = try LexiStore(url: databaseURL)
        let entry = try store.createEntry(title: "ことば【言葉】", note: "これはレイアウト確認専用のサンプルです。")
        _ = try store.createEntry(title: "一期一会", type: .idiom)
        _ = try store.createEntry(title: "言葉を交わす", type: .example)
        let model = LexiViewModel(databaseURL: databaseURL)
        for _ in 0..<500 {
            if !model.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.loadFailed)
        model.selectEntry(entry.id)
        for _ in 0..<500 {
            if model.selectedEntry?.id == entry.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.selectedEntry?.id, entry.id)
        _ = NSApplication.shared
        let suiteName = "LexiLayoutTests.\(UUID())"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        for dark in [true, false] {
            model.appearance = dark ? "dark" : "light"
            for size in [NSSize(width: 1190, height: 760), NSSize(width: 920, height: 580)] {
                let controller = NSHostingController(rootView:
                    ContentView()
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environmentObject(model).defaultAppStorage(settings))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = controller
                window.setContentSize(size)
                controller.view.frame = NSRect(origin: .zero, size: size)
                // Let SwiftUI finish its initial navigation layout without showing a window.
                for _ in 0..<10 {
                    controller.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                }
                let view = controller.view
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 5000, "Preview should contain rendered controls")
                let name = "workspace-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                try png.write(to: output.appendingPathComponent(name))
                window.close()
            }
        }
    }
}
