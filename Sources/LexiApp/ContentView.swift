import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import LexiCore

struct ContentView: View {
    @EnvironmentObject private var model: LexiViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingNewFolder = false

    var body: some View {
        HSplitView {
            SidebarView(showFolder: $showingNewFolder)
                .padding(.top, 4)
                .background(LexiTheme.sidebarBackground)
                .frame(minWidth: 220, idealWidth: 278, maxWidth: 340)
            EntryListView()
                .padding(.top, -20)
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 380)
            Group {
                if model.selectedFolderIDs.count > 1 {
                    ContentUnavailableView {
                        Label("フォルダを複数選択中", systemImage: "folder")
                    } description: {
                        Text("\(model.folderIDsForExport.count)件選択")
                    } actions: {
                        Button { model.exportSelectedFolders() } label: {
                            Label("JSONを書き出す…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(LexiControlStyle())
                        .accessibilityIdentifier("exportSelectedFoldersButton")
                    }
                    .frame(minWidth: 350)
                } else if model.selectedIDs.count > 1 {
                    BulkEntryDetailView()
                        .frame(minWidth: 350)
                } else {
                    EntryDetailView()
                        .frame(minWidth: 350)
                }
            }
            .padding(.top, -20)
            .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { model.showNewEntry = true } label: {
                        LexiControlIcon(symbol: "plus")
                    }
                    .buttonStyle(LexiControlStyle())
                    .keyboardShortcut("n", modifiers: .command)
                    .help("新規項目（⌘N）")
                    .accessibilityLabel("新規項目")
                    .accessibilityIdentifier("newEntryButton")
                    .disabled(model.isLoading || model.loadFailed || model.selectedFolderIDs.count > 1)
                    LexiPopupButton(symbol: "externaldrive", title: "データ", identifier: "dataMenu") {
                        LexiPopupRow("JSONを取り込む…", symbol: "square.and.arrow.down") { model.importPortableJSON() }
                        if !model.folderIDsForExport.isEmpty {
                            LexiPopupRow("選択したフォルダを書き出す…", symbol: "folder") { model.exportSelectedFolders() }
                        }
                        LexiPopupRow("すべてを書き出す…", symbol: "square.and.arrow.up") { model.exportPortableJSON() }
                        Divider()
                        LexiPopupRow("バックアップを作成…", symbol: "externaldrive.badge.timemachine") { model.saveBackup() }
                    }
                    Button { model.showDictionarySettings = true } label: {
                        LexiControlIcon(symbol: "book")
                    }
                    .buttonStyle(LexiControlStyle())
                    .help("辞典設定")
                    .accessibilityLabel("辞典設定")
                    .accessibilityIdentifier("dictionarySourceSettingsButton")
                    Button {
                        model.appearance = model.appearance == "dark" ? "light" : "dark"
                    } label: {
                        LexiControlIcon(symbol: model.appearance == "dark" ? "sun.max" : "moon")
                    }
                    .buttonStyle(LexiControlStyle())
                    .accessibilityLabel(model.appearance == "dark" ? "ライトに切り替え" : "ダークに切り替え")
                    .accessibilityIdentifier("appearanceToggleButton")
                    .help(model.appearance == "dark" ? "ライトに切り替え" : "ダークに切り替え")
                    Button { model.showMCPSettings = true } label: {
                        LexiControlIcon(symbol: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(LexiControlStyle())
                    .accessibilityLabel("AI接続（MCP）")
                    .accessibilityIdentifier("mcpSettingsButton")
                    .help("AI接続（MCP）")
                    Button { model.showFontSettings = true } label: {
                        LexiControlIcon(symbol: "textformat")
                    }
                    .buttonStyle(LexiControlStyle())
                    .help("フォント設定")
                    .accessibilityLabel("フォント設定")
                    .accessibilityIdentifier("fontSettingsButton")
                    .popover(isPresented: $model.showFontSettings, arrowEdge: .bottom) {
                        LexiFontSettingsSheet()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(LexiTheme.contentBackground)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlayPreferenceValue(BadgeTooltipPreference.self) { tip in
            if let tip { BadgeTooltipOverlay(tip: tip) }
        }
        .tint(LexiTheme.accent)
        .background(LexiTheme.contentBackground)
        .preferredColorScheme(model.appearance == "dark" ? .dark : .light)
        .sheet(isPresented: $model.showNewEntry) {
            NewEntrySheet(isPresented: $model.showNewEntry)
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet(isPresented: $showingNewFolder)
        }
        .sheet(isPresented: $model.showMCPSettings) {
            MCPSettingsSheet(configuration: model.mcpConfiguration, isPresented: $model.showMCPSettings)
        }
        .sheet(isPresented: $model.showDictionarySettings) {
            DictionarySourceSettingsSheet()
        }
        .sheet(item: $model.dictionaryChoice) { choice in
            DictionaryChoiceSheet(choice: choice)
                .interactiveDismissDisabled(true)
        }
        .alert("エラー", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )) {
            Button("閉じる", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
        .confirmationDialog("未保存のノートがあります", isPresented: $model.showUnsavedSelectionPrompt) {
            Button("保存して切り替え") { model.saveAndContinueSelection() }
            Button("保存せずに切り替え", role: .destructive) { model.discardAndContinueSelection() }
            Button("キャンセル", role: .cancel) { model.cancelPendingSelection() }
        } message: {
            Text("項目を切り替える前に、ノートを保存するか破棄してください。")
        }
        .environment(\.lexiFontFamily, model.fontFamily)
        .environment(\.lexiFontSizeOffset, model.fontSizeOffset)
        .font(LexiFontSupport.font(model.fontFamily, size: LexiTypography.body + CGFloat(model.fontSizeOffset)))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.pollExternalChanges() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.pollExternalChanges()
        }
    }
}

private let lexiFolderDragType = UTType.plainText

@MainActor
private func receiveFolderDrop(_ providers: [NSItemProvider], model: LexiViewModel, parent: String?, before: String? = nil) -> Bool {
    guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(lexiFolderDragType.identifier) }) else { return false }
    provider.loadObject(ofClass: NSString.self) { value, _ in
        guard let payload = value as? String, payload.hasPrefix("lexi-folder:"),
              let data = String(payload.dropFirst("lexi-folder:".count)).data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data),
              !ids.isEmpty, !ids.contains(before ?? ""), !ids.contains(parent ?? "") else { return }
        Task { @MainActor in
            guard ids.allSatisfy({ id in model.folders.contains { $0.id == id } }) else { return }
            model.arrangeFolders(ids, parentID: parent, beforeID: before)
        }
    }
    return true
}

struct SidebarView: View {
    @EnvironmentObject private var model: LexiViewModel
    @Binding var showFolder: Bool
    @State private var deleting = false
    @State private var moving = false

    private struct VisibleFolder: Identifiable {
        let folder: Folder
        let depth: Int
        var id: String { folder.id }
    }
    private var visibleFolders: [VisibleFolder] {
        var result: [VisibleFolder] = []
        func append(_ parent: String?, depth: Int) {
            for folder in model.folders where folder.parentID == parent {
                result.append(VisibleFolder(folder: folder, depth: depth))
                if !model.collapsedFolderIDs.contains(folder.id) { append(folder.id, depth: depth + 1) }
            }
        }
        append(nil, depth: 0)
        return result
    }
    private func isSelected(_ id: String) -> Bool {
        model.selectedFolderIDs.contains(id) || (model.selectedFolderIDs.isEmpty && model.navigation == "folder:\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Group {
                    if let url = Bundle.main.url(forResource: "LexiEmblem", withExtension: "png"),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        LexiBrandMark().stroke(LexiTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }.frame(width: 25, height: 25).accessibilityHidden(true)
                Text("Lexi")
                    .lexiFont(21, weight: .semibold)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 3)
            .accessibilityIdentifier("lexiBrand")
            VStack(spacing: 2) {
                navigationRow("すべての項目", symbol: "square.grid.2x2", value: "all")
                    .accessibilityIdentifier("allEntriesButton")
                navigationRow("未整理", symbol: "tray", value: "unorganized")
                    .accessibilityIdentifier("unorganizedButton")
            }
            Button { showFolder = true } label: {
                HStack(spacing: 8) {
                    Text("フォルダ")
                        .lexiFont(LexiTypography.control, weight: .semibold)
                    Spacer(minLength: 4)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(LexiTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("フォルダを追加")
            .accessibilityLabel("フォルダを追加")
            .accessibilityIdentifier("newFolderButton")
                .onDrop(of: [lexiFolderDragType], isTargeted: nil) { providers in
                    receiveFolderDrop(providers, model: model, parent: nil)
                }
            if model.selectedFolderIDs.count > 1 {
                HStack {
                    Text("\(model.selectedFolderIDs.count)件選択").lexiFont(LexiTypography.caption)
                    Spacer()
                    Menu {
                        Button("最上位へ移動") { model.arrangeFolders(Array(model.selectedFolderIDs), parentID: nil) }
                        ForEach(model.folders.filter { candidate in
                            model.selectedFolderIDs.allSatisfy { !model.folderDescendants($0).contains(candidate.id) }
                        }) { f in
                            Button(model.folderPath(f.id)) { model.arrangeFolders(Array(model.selectedFolderIDs), parentID: f.id) }
                        }
                    } label: { LexiControlIcon(symbol: "folder").frame(width: 36, height: 34).contentShape(Rectangle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).help("選択したフォルダを移動")
                    Button { deleting = true } label: { Image(systemName: "trash") }.help("選択したフォルダを削除")
                    Button { model.navigateTo("all") } label: { Image(systemName: "xmark") }.help("選択解除")
                }.buttonStyle(LexiControlStyle()).padding(.horizontal, 7)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let visible = visibleFolders
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        FolderBranch(folder: row.folder, depth: row.depth,
                            joinsPrevious: index > 0 && isSelected(visible[index - 1].id),
                            joinsNext: index + 1 < visible.count && isSelected(visible[index + 1].id))
                    }

                }
            }
            .contentMargins(.trailing, LexiLayout.listScrollerGutter, for: .scrollContent)
            .accessibilityLabel("フォルダ一覧")
        }
        .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LexiTheme.sidebarBackground).navigationTitle("Lexi")
        .confirmationDialog("選択したフォルダを削除しますか？", isPresented: $deleting) {
            Button("削除", role: .destructive) { model.deleteFolders(Array(model.selectedFolderIDs)) }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("下位フォルダも削除されます。項目そのものは削除されません。") }
    }

    private func navigationRow(_ title: String, symbol: String, value: String) -> some View {
        LexiRowSurface(selected: model.selectedFolderIDs.isEmpty && model.navigation == value, height: LexiLayout.entryRowHeight) {
            Button { model.navigateTo(value) } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 17)
                        .foregroundStyle(model.selectedFolderIDs.isEmpty && model.navigation == value ? LexiTheme.accent : .secondary)
                    Text(title).lexiFont(LexiTypography.body, weight: .medium)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: LexiLayout.entryRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct FolderBranch: View {
    @EnvironmentObject private var model: LexiViewModel
    @Environment(\.colorScheme) private var colorScheme
    let folder: Folder
    let depth: Int
    var joinsPrevious = false
    var joinsNext = false
    @State private var renaming = false
    @State private var creating = false
    @State private var name = ""
    @State private var deleting = false
    @State private var dropTarget = false
    @State private var beforeTarget = false
    private var children: [Folder] { model.folders.filter { $0.parentID == folder.id } }
    private var expanded: Bool { !model.collapsedFolderIDs.contains(folder.id) }
    private var selected: Bool {
        model.selectedFolderIDs.contains(folder.id) || (model.selectedFolderIDs.isEmpty && model.navigation == "folder:\(folder.id)")
    }

    var body: some View {
        LexiRowSurface(selected: selected || dropTarget, height: LexiLayout.entryRowHeight,
                       joinsPrevious: joinsPrevious, joinsNext: joinsNext) {
            HStack(spacing: 3) {
                if children.isEmpty {
                    Color.clear.frame(width: 17, height: 1).accessibilityHidden(true)
                } else {
                    Button { model.toggleFolderExpansion(folder.id) } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, height: LexiLayout.entryRowHeight)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(expanded ? "折りたたむ" : "展開")
                        .accessibilityIdentifier("folderDisclosure-\(folder.id)")
                }
                Button { model.selectFolder(folder.id, modifiers: NSEvent.modifierFlags) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded && !children.isEmpty ? "folder.fill" : "folder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? LexiTheme.accent : .secondary)
                            .frame(width: 17)
                        Text(folder.name).lexiFont(LexiTypography.body, weight: .medium)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(model.folderCount(folder.id).formatted())
                            .lexiFont(LexiTypography.caption).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.trailing, 9)
                    .frame(maxWidth: .infinity, minHeight: LexiLayout.entryRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help(folder.name)
                    .accessibilityIdentifier("folder-\(folder.id)")
                    .contextMenu { folderActions }
                    .onDrag {
                        let ids = model.folderActionIDs(folder.id)
                        let payload = (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                        return NSItemProvider(object: ("lexi-folder:" + payload) as NSString)
                    }
                    .onDrop(of: [lexiFolderDragType], isTargeted: $dropTarget) { providers in receiveFolderDrop(providers, model: model, parent: folder.id) }
            }.padding(.leading, 5 + CGFloat(depth) * 12)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(beforeTarget ? LexiTheme.accent : .clear)
                .frame(height: 4).contentShape(Rectangle())
                .onDrop(of: [lexiFolderDragType], isTargeted: $beforeTarget) { providers in
                    receiveFolderDrop(providers, model: model, parent: folder.parentID, before: folder.id)
                }
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $renaming) {
            NameEditSheet(title: "フォルダ名を変更", name: $name, isPresented: $renaming) { model.renameFolder(folder.id, name: name) }
        }
        .sheet(isPresented: $creating) {
            NameEditSheet(title: "新規サブフォルダ", name: $name, isPresented: $creating) {
                model.createFolder(name: name, parent: folder.id)
                if !expanded { model.toggleFolderExpansion(folder.id) }
            }
        }
        .confirmationDialog("フォルダを削除しますか？", isPresented: $deleting) {
            Button("削除", role: .destructive) { model.deleteFolders(model.folderActionIDs(folder.id)) }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("下位フォルダも削除されます。項目そのものは削除されません。") }
    }

    @ViewBuilder private var folderActions: some View {
        Button { name = ""; creating = true } label: { Label("新規サブフォルダ", systemImage: "folder.badge.plus") }
        Button { name = folder.name; renaming = true } label: { Label("名前を変更", systemImage: "pencil") }
        Menu("移動先") {
            Button("最上位") { model.arrangeFolders(model.folderActionIDs(folder.id), parentID: nil) }
            ForEach(model.folders.filter { candidate in
                model.folderActionIDs(folder.id).allSatisfy { !model.folderDescendants($0).contains(candidate.id) }
            }) { f in
                Button(model.folderPath(f.id)) { model.arrangeFolders(model.folderActionIDs(folder.id), parentID: f.id) }
            }
        }
        if model.folderActionIDs(folder.id).count == 1 {
            let siblings = model.folders.filter { $0.parentID == folder.parentID }
            if let i = siblings.firstIndex(where: { $0.id == folder.id }) {
                Button {
                    model.arrangeFolders([folder.id], parentID: folder.parentID, beforeID: siblings[i-1].id)
                } label: { Label("上へ移動", systemImage: "arrow.up") }.disabled(i == 0)
                Button {
                    let before = i + 2 < siblings.count ? siblings[i+2].id : nil
                    model.arrangeFolders([folder.id], parentID: folder.parentID, beforeID: before)
                } label: { Label("下へ移動", systemImage: "arrow.down") }.disabled(i + 1 >= siblings.count)
            }
        }
        Divider()
        Button { model.exportPortableJSON(folderIDs: model.folderActionIDs(folder.id)) } label: {
            Label(model.folderActionIDs(folder.id).count > 1 ? "選択したフォルダのJSONを書き出す…" : "JSONを書き出す…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button("削除", role: .destructive) { deleting = true }
    }
}

extension LexiViewModel {
    func folderDescendants(_ id: String) -> Set<String> {
        var found: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.parentID.map({ found.contains($0) }) ?? false {
                if found.insert(folder.id).inserted { changed = true }
            }
        }
        return found
    }
}

struct EntryListView: View {
    @EnvironmentObject private var model: LexiViewModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var searchFieldState = SearchTextFieldState()

    private var hasSearchFilters: Bool {
        !model.searchText.isEmpty || model.typeFilter != "all" || model.noteFilter != nil || model.dictionaryFilter != nil
    }

    private var childFolders: [Folder] {
        guard let id = model.selectedFolderID else { return [] }
        return model.folders.filter { $0.parentID == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selectedFolderIDs.count > 1 ? "フォルダを選択中" : model.navigationLabel)
                    .lexiFont(LexiTypography.screenTitle, weight: .semibold)
                    .lineLimit(1)
                    .help(model.navigationLabel)
                if !model.isLoading && !model.loadFailed {
                    Text("\(model.entries.count)")
                        .lexiFont(LexiTypography.caption, weight: .semibold).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("\(model.entries.count) 件")
                }
                Spacer(minLength: 4)
                if model.selectedIDs.count > 1 {
                    Text("\(model.selectedIDs.count) 件選択")
                        .lexiFont(LexiTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 5)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SearchTextField(
                    text: $model.searchText,
                    isFocused: $model.searchFieldFocused,
                    state: searchFieldState,
                    onSelectAllEntries: model.selectAllVisible
                )
                .frame(height: 18 + CGFloat(max(0, model.fontSizeOffset)))
                if !model.searchText.isEmpty {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill").frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("検索語を消去")
                        .accessibilityLabel("検索語を消去")
                        .accessibilityIdentifier("clearSearchButton")
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(LexiTheme.searchBackground(colorScheme == .dark), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16)
            .padding(.top, 2)

            EntryFilterBar()
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 7)
            Divider().opacity(0.5)

            Group {
                if model.selectedFolderIDs.count > 1 {
                    ContentUnavailableView("フォルダを複数選択中", systemImage: "folder")
                } else if model.isLoading {
                    ProgressView("項目を読み込んでいます…")
                } else if model.loadFailed && model.entries.isEmpty {
                    ContentUnavailableView {
                        Label("データを読み込めませんでした", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("データの保存先を確認して、もう一度お試しください。")
                    } actions: {
                        Button("再試行") { model.retryLoading() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if model.entries.isEmpty && childFolders.isEmpty {
                    ContentUnavailableView(
                        hasSearchFilters ? "項目が見つかりません" : "項目なし",
                        systemImage: hasSearchFilters ? "magnifyingglass" : "books.vertical"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if !childFolders.isEmpty {
                                HStack {
                                    Text("フォルダ").lexiFont(LexiTypography.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }.padding(.horizontal, 9).padding(.vertical, 6)
                                ForEach(childFolders) { folder in
                                    LexiRowSurface(selected: false, height: LexiLayout.entryRowHeight) {
                                    Button {
                                        model.selectFolder(folder.id)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "folder").font(.system(size: 13, weight: .medium)).foregroundStyle(LexiTheme.accent).frame(width: 17)
                                            Text(folder.name).lexiFont(LexiTypography.body, weight: .medium).lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(model.folderCount(folder.id).formatted()).lexiFont(LexiTypography.caption).foregroundStyle(.secondary).monospacedDigit()
                                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                        }.padding(.horizontal, 9).frame(height: LexiLayout.entryRowHeight).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityIdentifier("childFolder-\(folder.id)")
                                    }
                                }
                                if !model.entries.isEmpty {
                                    Divider().padding(.vertical, 5)
                                    HStack {
                                        Text("項目").lexiFont(LexiTypography.caption).foregroundStyle(.secondary)
                                        Spacer()
                                    }.padding(.horizontal, 9).padding(.vertical, 5)
                                }
                            }
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                LexiRowSurface(
                                    selected: model.selectedIDs.contains(entry.id),
                                    height: LexiLayout.entryRowHeight,
                                    joinsPrevious: index > 0 && model.selectedIDs.contains(model.entries[index - 1].id),
                                    joinsNext: index + 1 < model.entries.count && model.selectedIDs.contains(model.entries[index + 1].id)
                                ) {
                                    EntryListRow(entry: entry) { modifiers in
                                        model.selectEntryFromRow(entry.id, modifiers: modifiers)
                                        model.listSelectionFocused = true
                                        model.searchFieldFocused = false
                                    }
                                }
                                .accessibilityElement(children: .contain)
                            }
                        }
                        .padding(.top, LexiLayout.listTopSpacing)
                        .padding(.horizontal, 8)
                    }
                    .contentMargins(.trailing, LexiLayout.listScrollerGutter, for: .scrollContent)
                    .accessibilityLabel("項目一覧")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .background(LexiTheme.listBackground)
        .onChange(of: model.focusSearchRequest) { _, _ in model.searchFieldFocused = true }
        .background {
            ListSelectAllKeyMonitor(model: model, searchFieldState: searchFieldState)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct SearchTextField: NSViewRepresentable {
    @Environment(\.lexiFontFamily) private var fontFamily
    @Environment(\.lexiFontSizeOffset) private var fontSizeOffset
    @Binding var text: String
    @Binding var isFocused: Bool
    let state: SearchTextFieldState
    let onSelectAllEntries: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, state: state)
    }

    func makeNSView(context: Context) -> CommandSelectAllTextField {
        let field = CommandSelectAllTextField()
        field.delegate = context.coordinator
        state.field = field
        field.onSelectAllEntries = onSelectAllEntries
        field.placeholderString = ""
        field.toolTip = "検索（⌘F）"
        field.font = LexiFontSupport.nativeFont(fontFamily, size: LexiTypography.search + CGFloat(fontSizeOffset))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel("項目を検索")
        field.setAccessibilityIdentifier("entrySearchField")
        return field
    }

    func updateNSView(_ field: CommandSelectAllTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.isFocused = $isFocused
        state.field = field
        field.onSelectAllEntries = onSelectAllEntries
        let desiredFont = LexiFontSupport.nativeFont(fontFamily, size: LexiTypography.search + CGFloat(fontSizeOffset))
        if field.font != desiredFont { field.font = desiredFont }
        if field.stringValue != text { field.stringValue = text }
        if let window = field.window {
            // Never take focus away from the note editor or another text field on
            // an unrelated SwiftUI redraw. React only to an explicit focus request.
            if coordinator.lastRequestedFocus != isFocused {
                coordinator.lastRequestedFocus = isFocused
                if isFocused && window.attachedSheet == nil && window.isKeyWindow {
                    window.makeFirstResponder(field)
                } else if !isFocused && state.ownsFirstResponder {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var lastRequestedFocus = false
        let state: SearchTextFieldState

        init(text: Binding<String>, isFocused: Binding<Bool>, state: SearchTextFieldState) {
            self.text = text
            self.isFocused = isFocused
            self.state = state
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            state.isEditing = true
            lastRequestedFocus = true
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            state.isEditing = false
            lastRequestedFocus = false
            isFocused.wrappedValue = false
        }
    }
}

@MainActor
private final class SearchTextFieldState: ObservableObject {
    weak var field: CommandSelectAllTextField?
    var isEditing = false

    var ownsFirstResponder: Bool {
        guard let field, let responder = field.window?.firstResponder else { return false }
        return responder === field || (field.currentEditor().map { responder === $0 } ?? false)
    }

    func selectAll() {
        guard let editor = field?.currentEditor() else { return }
        editor.selectAll(nil)
    }

}

private final class CommandSelectAllTextField: NSTextField {
    var onSelectAllEntries: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            if stringValue.isEmpty {
                onSelectAllEntries?()
            } else {
                currentEditor()?.selectAll(nil)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct ListSelectAllKeyMonitor: NSViewRepresentable {
    @ObservedObject var model: LexiViewModel
    @ObservedObject var searchFieldState: SearchTextFieldState

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, searchFieldState: searchFieldState)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private let model: LexiViewModel
        private let searchFieldState: SearchTextFieldState
        private var monitor: Any?
        weak var hostView: NSView?

        init(model: LexiViewModel, searchFieldState: SearchTextFieldState) {
            self.model = model
            self.searchFieldState = searchFieldState
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.contains(.command),
                      let host = self?.hostView?.window, event.window === host,
                      host.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                if event.charactersIgnoringModifiers?.lowercased() == "f" {
                    MainActor.assumeIsolated {
                        self?.model.searchFieldFocused = true
                        self?.model.focusSearchRequest += 1
                    }
                    return nil
                }
                guard event.charactersIgnoringModifiers?.lowercased() == "a" else { return event }
                let handled = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if self.model.textEditorFocused { return false }
                    if self.searchFieldState.ownsFirstResponder {
                        if self.model.searchText.isEmpty {
                            guard !self.model.entries.isEmpty else { return false }
                            self.model.selectAllVisible()
                        } else {
                            self.searchFieldState.selectAll()
                        }
                        return true
                    }
                    let textInputIsFocused = Self.isTextResponder(NSApp.keyWindow?.firstResponder)
                    guard !textInputIsFocused, !self.model.entries.isEmpty else { return false }
                    self.model.selectAllVisible()
                    return true
                }
                return handled ? nil : event
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private static func isTextResponder(_ responder: NSResponder?) -> Bool {
            responder is NSTextField || responder is NSTextView
        }
    }
}

struct EntryListRow: View {
    @EnvironmentObject private var model: LexiViewModel
    let entry: EntrySummary
    let onSelect: (NSEvent.ModifierFlags) -> Void

    private var typeColor: Color {
        switch entry.type {
        case .headword: LexiTheme.headword
        case .idiom: LexiTheme.idiom
        case .example: LexiTheme.example
        }
    }

    private var folderBadgeText: String {
        "所属フォルダ：\(entry.folderCount)件\n" + folderNames.joined(separator: "\n")
    }

    private var duplicateBadgeText: String {
        var lines = ["同名項目：\(entry.duplicateCount)件"]
        for (id, count) in (entry.sameTitleInFolderCounts ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append("\(model.folderPath(id))：\(count)件")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onSelect(NSEvent.modifierFlags)
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(typeColor.opacity(0.8)).frame(width: 3, height: 24)
                    Text(DictionaryDisplayText.clean(entry.title))
                        .lexiFont(LexiTypography.body, weight: .medium)
                        .lineLimit(1)
                        .help(entry.fullTitle.isEmpty ? entry.title : entry.fullTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.belongsToMultipleFolders {
                        badge("folder", count: entry.folderCount, detail: folderBadgeText)
                    }
                    if entry.duplicateCount > 1 {
                        badge("square.on.square", count: entry.duplicateCount, detail: duplicateBadgeText)
                    }
                }
                .padding(.leading, 9)
                .frame(maxWidth: .infinity, minHeight: LexiLayout.entryRowHeight, maxHeight: LexiLayout.entryRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: LexiLayout.entryRowHeight, maxHeight: LexiLayout.entryRowHeight)
            .contentShape(Rectangle())
            .accessibilityIdentifier("entry-\(entry.id)")
            .accessibilityLabel(DictionaryDisplayText.clean(entry.title) + (entry.belongsToMultipleFolders ? "、所属フォルダ、\(entry.folderCount)件" : "") + (entry.duplicateCount > 1 ? "、同名項目、\(entry.duplicateCount)件" : ""))
            Button {
                model.openMonokakidoSearch(DictionaryDisplayText.clean(entry.title), type: entry.type)
            } label: {
                Image(systemName: "book.closed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LexiTheme.accent)
                    .frame(width: 40, height: LexiLayout.entryRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help("物書堂で検索")
            .accessibilityLabel("物書堂で検索")
            .accessibilityIdentifier("monokakidoSearch-\(entry.id)")


        }
        .frame(maxWidth: .infinity, minHeight: LexiLayout.entryRowHeight, maxHeight: LexiLayout.entryRowHeight)
        .contentShape(Rectangle())
    }

    private func badge(_ symbol: String, count: Int, detail: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(String(count)).monospacedDigit().font(.system(size: 10, weight: .medium))
        }.foregroundStyle(LexiTheme.accent)
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(LexiTheme.subtleFill, in: RoundedRectangle(cornerRadius: 4))
            .modifier(InstantBadgeTooltip(text: detail))
            .accessibilityHidden(true)
    }

    private var folderNames: [String] {
        entry.folderIDs
            .map { model.folderPath($0) }
            .filter { !$0.isEmpty }
    }
}

struct BulkEntryDetailView: View {
    @EnvironmentObject private var model: LexiViewModel
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.selectedIDs.count) 件を選択中")
                        .lexiFont(LexiTypography.detailTitle, weight: .semibold)
                }
                Spacer(minLength: 4)
                if model.dictionaryOperationRunning {
                    Button { model.cancelDictionaryOperation() } label: {
                        Label("更新を中止", systemImage: "stop.circle")
                    }.labelStyle(.iconOnly).help("更新を中止")
                } else {
                    Button { model.updateDictionary(for: Array(model.selectedIDs)) } label: {
                        Label("辞典内容を更新", systemImage: "arrow.clockwise")
                    }.labelStyle(.iconOnly).help("辞典内容を更新")
                        .accessibilityIdentifier("bulkDictionaryFetch")
                }
                bulkOperationsMenu
            }
            Divider()
            if let progress = model.dictionaryProgressText {
                Text(progress)
                    .lexiFont(LexiTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .buttonStyle(LexiControlStyle())
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("選択した項目を削除しますか？", isPresented: $deleting) {
            Button("削除", role: .destructive) { model.deleteEntries(Array(model.selectedIDs)) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は元に戻せません。")
        }
    }

    private var bulkOperationsMenu: some View {
        LexiPopupButton(symbol: "ellipsis.circle", title: "項目の操作", identifier: "bulkActionsButton") {
            LexiEntryActionMenu(folders: model.folders, folderPath: model.folderPath,
                folderIDs: nil, currentType: nil, rename: nil,
                canRename: false, canDelete: true,
                changeFolder: { model.addFolder($0, to: Array(model.selectedIDs)) },
                changeType: { model.setType($0, for: Array(model.selectedIDs)) },
                delete: { deleting = true })
        }
    }
}
