import SwiftUI
import AppKit
import LexiCore

// Warm, quiet sage green. All UI text and feedback are Japanese.
enum LexiTheme {
    static let sidebarBackground = adaptive(light: (0.95, 0.96, 0.97), dark: (0.10, 0.11, 0.13))
    static let listBackground = adaptive(light: (0.98, 0.985, 0.99), dark: (0.115, 0.125, 0.14))
    static let contentBackground = adaptive(light: (1, 1, 1), dark: (0.125, 0.137, 0.15))
    static let subtleFill = Color.primary.opacity(0.045)
    static let accent = adaptive(light: (0.20, 0.40, 0.28), dark: (0.54, 0.67, 0.57))
    static let headword = adaptive(light: (0.18, 0.44, 0.28), dark: (0.36, 0.70, 0.50))
    static let idiom = adaptive(light: (0.50, 0.34, 0.10), dark: (0.86, 0.70, 0.36))
    static let example = adaptive(light: (0.62, 0.23, 0.24), dark: (0.80, 0.43, 0.43))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static let darkSelected = Color.white.opacity(0.105)
    static func selected(_ dark: Bool) -> Color { dark ? darkSelected : Color(red: 0.88, green: 0.93, blue: 0.88) }
    static func hovered(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035) }
    static func searchBackground(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.075) : Color(red: 0.94, green: 0.955, blue: 0.932)
    }
}

enum LexiTypography {
    static let caption: CGFloat = 11
    static let control: CGFloat = 13
    static let search: CGFloat = 13
    static let body: CGFloat = 14
    static let screenTitle: CGFloat = 16
    static let detailTitle: CGFloat = 26
}

struct LexiRowSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    let selected: Bool
    let height: CGFloat
    var joinsPrevious = false
    var joinsNext = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: selected && joinsPrevious ? 0 : 7,
                                       bottomLeadingRadius: selected && joinsNext ? 0 : 7,
                                       bottomTrailingRadius: selected && joinsNext ? 0 : 7,
                                       topTrailingRadius: selected && joinsPrevious ? 0 : 7)
                    .fill(
                        selected ? LexiTheme.selected(colorScheme == .dark)
                            : hovering ? LexiTheme.hovered(colorScheme == .dark) : .clear
                    )
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

enum LexiLayout {
    static let folderRowHeight: CGFloat = 40
    static let entryRowHeight: CGFloat = 40
    static let listTopSpacing: CGFloat = 8
    // Keep row controls out of the macOS overlay scrollbar hit region.
    static let listScrollerGutter: CGFloat = 16
}

extension LexiPreferences.Appearance {
    var title: String { self == .light ? "ライト" : "ダーク" }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn:"#"))
        guard let n = UInt64(clean,radix:16), clean.count == 6 else { self = LexiTheme.accent; return }
        self.init(red: Double((n >> 16) & 255)/255, green:Double((n >> 8) & 255)/255, blue:Double(n & 255)/255)
    }
}


// One hit surface and visual language for application-owned controls.
struct LexiControlIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
            .frame(width: 20, height: 20).contentShape(Rectangle())
    }
}

struct LexiControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(minWidth: 36, minHeight: 34)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? LexiTheme.accent.opacity(0.20) : LexiTheme.subtleFill,
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
    }
}

private struct LexiPopupDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var lexiDismissPopup: () -> Void {
        get { self[LexiPopupDismissKey.self] }
        set { self[LexiPopupDismissKey.self] = newValue }
    }
}

struct LexiPopupButton<Content: View>: View {
    let symbol: String
    let title: String
    let identifier: String
    var active = false
    var fillsWidth = false
    @ViewBuilder let content: () -> Content
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? LexiTheme.accent : Color.primary)
                .frame(minWidth: 36, maxWidth: fillsWidth ? .infinity : 36, minHeight: 34)
                .contentShape(Rectangle())
                .background(active ? LexiTheme.accent.opacity(0.20) : LexiTheme.subtleFill,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) { content() }
                .padding(8).frame(minWidth: 180)
                .environment(\.lexiDismissPopup, { showing = false })
        }
    }
}

struct LexiPopupRow: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.lexiDismissPopup) private var dismiss
    @Environment(\.lexiFontSizeOffset) private var fontOffset
    @State private var hovering = false
    init(_ title: String, symbol: String? = nil, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action; self.destructive = destructive
    }
    var body: some View {
        Button { dismiss(); DispatchQueue.main.async { action() } } label: {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 17) }
                else { Color.clear.frame(width: 17, height: 1) }
                Text(title).lexiFont(LexiTypography.control)
                Spacer(minLength: 4)
            }.padding(.horizontal, 8).frame(minHeight: 34 + CGFloat(max(0, fontOffset))).contentShape(Rectangle())
                .background(hovering ? LexiTheme.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .opacity(enabled ? 1 : 0.45)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

extension View {
    func lexiSheet() -> some View {
        self.padding(24).frame(width: 420)
            .background(LexiTheme.contentBackground)
            .tint(LexiTheme.accent)
    }
}


/// A single-level menu with explicit navigation instead of ambiguous +/- accordions.
struct LexiEntryActionMenu: View {
    enum Page: String { case root, folders, types }
    let folders: [Folder]
    let folderPath: (String) -> String
    let folderIDs: Set<String>?
    let currentType: EntryType?
    let rename: (() -> Void)?
    let canRename: Bool
    let canDelete: Bool
    let changeFolder: (String) -> Void
    let changeType: (EntryType) -> Void
    let delete: () -> Void
    @State private var page: Page = .root
    @State private var search = ""
    @Environment(\.lexiDismissPopup) private var dismiss
    @Environment(\.lexiFontSizeOffset) private var fontOffset
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch page {
            case .root:
                if let rename {
                    LexiPopupRow("名前を変更", symbol: "pencil", action: rename)
                        .disabled(!canRename)
                        .accessibilityIdentifier("actionRename")
                    Divider()
                }
                navigationRow(folderIDs == nil ? "フォルダに追加" : "所属フォルダ", symbol: "folder", page: .folders)
                    .disabled(folders.isEmpty)
                    .accessibilityIdentifier("actionFolders")
                navigationRow("種類を変更", symbol: "textformat", page: .types)
                    .accessibilityIdentifier("actionTypes")
                Divider()
                LexiPopupRow("項目を削除", symbol: "trash", destructive: true, action: delete)
                    .disabled(!canDelete)
                    .accessibilityIdentifier("actionDelete")
            case .folders:
                backRow(folderIDs == nil ? "追加先を選択" : "所属フォルダ")
                Divider()
                if folders.count > 8 {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("検索", text: $search).textFieldStyle(.plain)
                            .lexiFont(LexiTypography.search)
                            .accessibilityIdentifier("actionFolderSearch")
                    }.padding(8)
                        .background(LexiTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let visible = folders.filter { search.isEmpty || folderPath($0.id).localizedCaseInsensitiveContains(search) }
                        if visible.isEmpty { Text("該当なし").foregroundStyle(.secondary).padding(8) }
                        ForEach(visible) { folder in
                            optionRow(folderPath(folder.id), checked: folderIDs?.contains(folder.id),
                                      symbol: "folder", identifier: "actionFolder-" + folder.id) {
                                changeFolder(folder.id)
                            }
                        }
                    }
                }.frame(height: 244)
            case .types:
                backRow("種類を選択")
                Divider()
                ForEach(EntryType.allCases, id: \.self) { type in
                    optionRow(type.japanese, checked: currentType.map { $0 == type }, symbol: nil,
                              identifier: "actionType-" + type.rawValue) { changeType(type) }
                }
            }
        }.frame(width: 264, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
    }
    private func navigationRow(_ title: String, symbol: String, page destination: Page) -> some View {
        Button {
            search = ""; page = destination
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 17)
                Text(title).lexiFont(LexiTypography.control)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }.padding(.horizontal, 8).frame(minHeight: 34 + CGFloat(max(0, fontOffset)))
                .contentShape(Rectangle())
        }.buttonStyle(LexiActionRowStyle())
    }
    private func backRow(_ title: String) -> some View {
        Button { search = ""; page = .root } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 17)
                    .foregroundStyle(LexiTheme.accent)
                Text(title).lexiFont(LexiTypography.control, weight: .semibold)
                Spacer(minLength: 4)
            }.padding(.horizontal, 8).frame(minHeight: 34 + CGFloat(max(0, fontOffset)))
                .contentShape(Rectangle())
        }.buttonStyle(LexiActionRowStyle())
            .accessibilityLabel("戻る、" + title).accessibilityIdentifier("actionBack")
    }
    private func optionRow(_ title: String, checked: Bool?, symbol: String?, identifier: String, action: @escaping () -> Void) -> some View {
        Button { dismiss(); DispatchQueue.main.async { action() } } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 17)
                        .foregroundStyle(.secondary)
                }
                Text(title).lexiFont(LexiTypography.control).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let checked {
                    Image(systemName: symbol == nil ? (checked ? "checkmark.circle.fill" : "circle") : (checked ? "checkmark.square.fill" : "square"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(checked ? LexiTheme.accent : .secondary)
                        .frame(width: 17)
                }
            }.padding(.horizontal, 8).padding(.vertical, 5)
                .frame(minHeight: 34 + CGFloat(max(0, fontOffset)))
                .background(checked == true ? LexiTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(LexiActionRowStyle())
            .accessibilityLabel(title)
            .accessibilityValue(checked.map { $0 ? "選択済み" : "未選択" } ?? "")
            .accessibilityIdentifier(identifier)
            .help(title)
    }
}

private struct LexiActionRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LexiTheme.accent.opacity(0.17) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
    }
}
