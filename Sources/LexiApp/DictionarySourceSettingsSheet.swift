import SwiftUI
import LexiCore

struct DictionarySourceSettingsSheet: View {
    @EnvironmentObject private var model: LexiViewModel
    private var connected: Bool { model.dictionarySource.available }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("辞典設定").lexiFont(20, weight: .semibold)
            VStack(alignment: .leading, spacing: 6) {
                Label(connected ? "接続済み" : (model.dictionarySource.root == nil ? "未接続" : "接続先なし"),
                      systemImage: connected ? "checkmark.circle.fill" : "circle")
                    .lexiFont(LexiTypography.control, weight: .medium)
                    .foregroundStyle(connected ? LexiTheme.accent : Color.secondary)
                    .accessibilityIdentifier("dictionarySourceStatus")
                if let path = model.dictionarySource.directory {
                    Text(path).lexiFont(LexiTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled).help(path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(LexiTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
            if let error = model.dictionarySourceError {
                Text(error).lexiFont(LexiTypography.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dictionarySourceError")
            }
            HStack(spacing: 8) {
                Button { model.chooseDictionarySource() } label: {
                    Label("接続", systemImage: "folder")
                }
                .accessibilityIdentifier("chooseDictionarySource")
                .disabled(model.dictionaryOperationRunning)
                Button { model.disconnectDictionarySource() } label: {
                    Label("解除", systemImage: "link.badge.minus")
                }
                .accessibilityIdentifier("disconnectDictionarySource")
                .disabled(model.dictionaryOperationRunning || model.dictionarySource.root == nil)
                Spacer()
                Button { model.dictionarySourceError = nil; model.showDictionarySettings = false } label: {
                    Label("閉じる", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("closeDictionarySourceSettings")
            }
            .lexiFont(LexiTypography.control)
            .buttonStyle(LexiControlStyle())
        }
        .lexiSheet()
    }
}
