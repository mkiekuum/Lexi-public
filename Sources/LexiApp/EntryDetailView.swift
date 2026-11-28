import SwiftUI
import AppKit
import LexiCore

struct EntryDetailView: View {
    @EnvironmentObject private var model: LexiViewModel
    @State private var deletionPrompt = false
    @State private var renameTarget: Entry?
    @State private var renameTitle = ""
    @State private var renaming = false
    @FocusState private var renameFocused: Bool
    @StateObject private var noteController = PlainNoteController()

    var body: some View {
        Group {
            if let entry = model.selectedEntry, model.selectedIDs.count == 1 {
                detail(entry)
            } else if model.selectedIDs.isEmpty {
                ContentUnavailableView(
                    "項目を選択",
                    systemImage: "book.closed"
                )
            } else {
                ProgressView("項目を読み込んでいます…")
            }
        }
        .navigationTitle("辞典")
        .sheet(item: $renameTarget) { target in
            VStack(alignment: .leading, spacing: 16) {
                Text("名前を変更").lexiFont(22, weight: .bold)
                TextField("項目名", text: $renameTitle).textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .accessibilityIdentifier("renameEntryField")
                HStack {
                    Spacer()
                    Button { renameTarget = nil } label: { Label("キャンセル", systemImage: "xmark") }
                        .keyboardShortcut(.cancelAction).help("キャンセル")
                    Button {
                        renaming = true
                        Task {
                            if await model.renameEntry(target, title: renameTitle) { renameTarget = nil }
                            renaming = false
                        }
                    } label: { Label("保存", systemImage: "checkmark") }
                        .keyboardShortcut(.defaultAction).help("保存")
                        .accessibilityIdentifier("saveEntryNameButton")
                        .disabled(renaming || renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.buttonStyle(LexiControlStyle())
            }.lexiSheet().onAppear { renameFocused = true }
        }
        .confirmationDialog("項目を削除しますか？", isPresented: $deletionPrompt) {
            Button("削除", role: .destructive) {
                if let id = model.selectedID { model.deleteEntry(id) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は元に戻せません。")
        }
    }

    private func detail(_ entry: Entry) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                heading(entry).frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 14) {
                    if model.dictionaryOperationRunning {
                        Button { model.cancelDictionaryOperation() } label: {
                            Label("更新を中止", systemImage: "stop.circle")
                        }.labelStyle(.iconOnly).help("更新を中止")
                    } else {
                        Button { model.updateDictionary(for: [entry.id]) } label: {
                            Label("辞典内容を更新", systemImage: "arrow.clockwise")
                        }.labelStyle(.iconOnly).help("辞典内容を更新")
                            .accessibilityIdentifier("updateDictionaryButton")
                    }
                    actions(entry)
                }.buttonStyle(LexiControlStyle()).fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 12)

            if let status = model.dictionaryProgressText {
                Text(status)
                    .lexiFont(LexiTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    contentCard { dictionaryBody(entry) }
                    contentCard { noteBody(entry) }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
        }
        .background(LexiTheme.contentBackground)
    }

    private func contentCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(14)
            .background(LexiTheme.subtleFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private func heading(_ entry: Entry) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(DictionaryDisplayText.clean(entry.title))
                    .lexiFont(LexiTypography.detailTitle, weight: .bold)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            if !entry.fullTitle.isEmpty && entry.fullTitle != entry.title {
                Text(DictionaryDisplayText.clean(entry.fullTitle))
                    .lexiFont(LexiTypography.control)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        }.multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func dictionaryBody(_ entry: Entry) -> some View {
        if entry.type == .example {
            exampleDictionaryBody(entry)
        } else if let document = entry.structuredDocument,
                  !document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading("辞典", symbol: "book.closed")
                DictionaryDocumentView(
                    document: document,
                    entryTitle: entry.title,
                    entryFullTitle: entry.fullTitle,
                    showsDocumentHeading: true,
                    highlightSourceID: nil,
                    onReference: { model.openMonokakidoSearch($0) }
                )
            }
        } else if !entry.dictionaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading("辞典", symbol: "book.closed")
                Text(DictionaryDisplayText.clean(entry.dictionaryText))
                    .lexiFont(LexiTypography.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading("辞典", symbol: "book.closed")
                Text("未取得").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func exampleDictionaryBody(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeading("辞典", symbol: "book.closed")
            if let document = entry.structuredDocument {
                DictionaryDocumentView(document: document, entryTitle: entry.title, entryFullTitle: entry.fullTitle,
                    showsDocumentHeading: true, highlightSourceID: exampleSourceKey(entry),
                    onReference: { model.openMonokakidoSearch($0) })
            } else if !entry.dictionaryText.isEmpty {
                Text(DictionaryDisplayText.clean(entry.dictionaryText)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("未取得").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func noteBody(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionHeading("ノート", symbol: "square.and.pencil")
                Spacer()
                if !model.noteEditing {
                    Button { model.beginNoteEditing() } label: { Label("ノートを編集", systemImage: "pencil") }
                        .labelStyle(.iconOnly).help("ノートを編集")
                        .buttonStyle(LexiControlStyle())
                        .lexiFont(LexiTypography.control)
                        .accessibilityLabel("ノートを編集")
                        .accessibilityIdentifier("editNoteButton")
                }
            }
            if model.noteEditing {
                PlainNoteEditor(text: $model.noteDraft, controller: noteController) { focused in
                    model.textEditorFocused = focused
                }
                .frame(minHeight: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 12) {
                    Button { noteController.paste() } label: { Label("ペースト", systemImage: "clipboard") }
                        .help("ペースト")
                        .keyboardShortcut("v", modifiers: [.command, .shift, .option])
                        .accessibilityIdentifier("pastePlainNoteButton")
                    Spacer()
                    Button { model.cancelNoteEditing() } label: { Label("キャンセル", systemImage: "xmark") }
                        .help("キャンセル").accessibilityIdentifier("cancelNoteButton")
                    Button { model.saveNoteEditing() } label: { Label("保存", systemImage: "checkmark") }
                        .help("保存").accessibilityIdentifier("saveNoteButton")
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.noteDraft == entry.note)
                }.labelStyle(.iconOnly).buttonStyle(LexiControlStyle())
            } else if !entry.note.isEmpty {
                Text(entry.note)
                    .lexiFont(LexiTypography.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func actions(_ entry: Entry) -> some View {
        LexiPopupButton(symbol: "ellipsis.circle", title: "項目の操作", identifier: "entryActionsButton") {
            LexiEntryActionMenu(folders: model.folders, folderPath: model.folderPath,
                folderIDs: Set(entry.folderIDs), currentType: entry.type,
                rename: { renameTitle = entry.title; renameTarget = entry },
                canRename: !model.noteEditing,
                canDelete: !model.noteEditing || model.noteDraft == entry.note,
                changeFolder: { model.toggleFolder($0, entryID: entry.id) },
                changeType: { model.setType($0, for: [entry.id]) },
                delete: { deletionPrompt = true })
        }
    }

    private func exampleSourceKey(_ entry: Entry) -> String? {
        guard entry.type == .example,
              let sourceEntryID = entry.sourceEntryID,
              let subentryID = entry.sourceSubentryID else { return nil }
        return "\(sourceEntryID)-\(subentryID)"
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .lexiFont(LexiTypography.body, weight: .semibold)
            .foregroundStyle(.primary)
    }

}
