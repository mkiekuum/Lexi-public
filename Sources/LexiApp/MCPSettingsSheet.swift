import AppKit
import SwiftUI

struct MCPSettingsSheet: View {
    let configuration: String
    @Binding var isPresented: Bool
    @State private var copied = false
    @State private var showingConfiguration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ローカルMCP").lexiFont(22, weight: .bold)
            DisclosureGroup("接続設定", isExpanded: $showingConfiguration) {
                Text(configuration)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mcpConfigurationText")
            }
            HStack {
                Spacer()
                Button("閉じる") { isPresented = false }.buttonStyle(LexiControlStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("closeMCPSettingsButton")
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(configuration, forType: .string)
                } label: {
                    Label(copied ? "コピー済み" : "設定をコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help(copied ? "コピー済み" : "設定をコピー")
                .buttonStyle(LexiControlStyle())
                .accessibilityIdentifier("copyMCPConfigurationButton")
            }
        }
        .lexiSheet()
    }
}
