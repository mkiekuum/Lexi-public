import SwiftUI
import LexiCore

struct NewEntrySheet: View {
    @EnvironmentObject private var model: LexiViewModel
    @Binding var isPresented: Bool
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var type: EntryType = .headword

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新規項目").lexiFont(22, weight: .semibold)
            TextField("項目名", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .accessibilityIdentifier("newEntryTitleField")
            Picker("種類", selection: $type) {
                ForEach(EntryType.allCases, id: \.self) { kind in
                    Text(kind.japanese).tag(kind)
                }
            }.pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("キャンセル") { isPresented = false }.buttonStyle(LexiControlStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelNewEntryButton")
                Button("追加") {
                    model.createEntry(title: title, type: type)
                    isPresented = false
                }
                .buttonStyle(LexiControlStyle())
                .accessibilityIdentifier("createEntryButton")
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .lexiSheet()
        .onAppear {
            if let requested = EntryType(rawValue: model.typeFilter) { type = requested }
            titleFocused = true
        }
    }
}

struct NewFolderSheet: View {
    @EnvironmentObject private var model: LexiViewModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var parentID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新規フォルダ").lexiFont(22, weight: .semibold)
            TextField("フォルダ名", text: $name).textFieldStyle(.roundedBorder)
                .focused($nameFocused).accessibilityIdentifier("newFolderNameField")
            Picker("親フォルダ", selection: $parentID) {
                Text("なし").tag("")
                ForEach(model.folders) { folder in
                    Text(model.folderPath(folder.id)).tag(folder.id)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { isPresented = false }.buttonStyle(LexiControlStyle())
                Button("追加") {
                    model.createFolder(name: name, parent: parentID.isEmpty ? nil : parentID)
                    isPresented = false
                }
                .buttonStyle(LexiControlStyle())
                .accessibilityIdentifier("createFolderButton")
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .lexiSheet()
        .onAppear {
            nameFocused = true
            if model.navigation.hasPrefix("folder:") {
                parentID = String(model.navigation.dropFirst(7))
            }
        }
    }
}

struct NameEditSheet: View {
    let title: String
    @Binding var name: String
    @Binding var isPresented: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).lexiFont(22, weight: .semibold)
            TextField("名前", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("キャンセル") { isPresented = false }.buttonStyle(LexiControlStyle())
                Button("保存") {
                    onSave()
                    isPresented = false
                }
                .buttonStyle(LexiControlStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .lexiSheet()
    }
}
