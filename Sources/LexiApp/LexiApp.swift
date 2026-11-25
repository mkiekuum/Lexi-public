import SwiftUI

@main
struct LexiApp: App {
    @StateObject private var model = LexiViewModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 580)
                .ignoresSafeArea(.container, edges: .top)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1190, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
