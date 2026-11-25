import SwiftUI
import AppKit

private struct LexiFontFamilyKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
private struct LexiFontSizeOffsetKey: EnvironmentKey {
    static let defaultValue = 0
}
extension EnvironmentValues {
    var lexiFontSizeOffset: Int {
        get { self[LexiFontSizeOffsetKey.self] }
        set { self[LexiFontSizeOffsetKey.self] = newValue }
    }
    var lexiFontFamily: String? {
        get { self[LexiFontFamilyKey.self] }
        set { self[LexiFontFamilyKey.self] = newValue }
    }
}

enum LexiFontSupport {
    static func nativeFont(_ family: String?, size: CGFloat) -> NSFont {
        guard let family, let font = NSFont(name: family, size: size) ??
                NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
        else { return .systemFont(ofSize: size) }
        return font
    }
    static func font(_ family: String?, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let family, NSFontManager.shared.availableFontFamilies.contains(family) else {
            return .system(size: size, weight: weight)
        }
        return .custom(nativeFont(family, size: size).fontName, size: size).weight(weight)
    }
    static func cssFamily(_ family: String?) -> String {
        let fallback = "-apple-system, BlinkMacSystemFont, sans-serif"
        guard let family, NSFontManager.shared.availableFontFamilies.contains(family) else { return fallback }
        // Escape every non-alphanumeric scalar, including HTML-sensitive characters.
        let escaped = family.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "\\" + String(scalar.value, radix: 16) + " "
        }.joined()
        return "\"" + escaped + "\", " + fallback
    }
}
private struct LexiFontModifier: ViewModifier {
    @Environment(\.lexiFontFamily) private var family
    @Environment(\.lexiFontSizeOffset) private var offset
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content.font(LexiFontSupport.font(family, size: max(8, size + CGFloat(offset)), weight: weight))
    }
}
extension View {
    func lexiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(LexiFontModifier(size: size, weight: weight))
    }
}

struct LexiFontSettingsSheet: View {
    @EnvironmentObject private var model: LexiViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    private var families: [String] {
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { model.setFontSizeOffset(model.fontSizeOffset - 1) } label: { LexiControlIcon(symbol: "minus") }
                    .disabled(model.fontSizeOffset <= -3).accessibilityLabel("文字を小さく").accessibilityIdentifier("fontSizeDecrease")
                Button { model.setFontSizeOffset(0) } label: {
                    Text("\(Int(LexiTypography.body) + model.fontSizeOffset)").monospacedDigit()
                        .frame(maxWidth: .infinity).font(.system(size: 14, weight: .medium))
                }.help("標準サイズ").accessibilityIdentifier("fontSizeReset")
                Button { model.setFontSizeOffset(model.fontSizeOffset + 1) } label: { LexiControlIcon(symbol: "plus") }
                    .disabled(model.fontSizeOffset >= 6).accessibilityLabel("文字を大きく").accessibilityIdentifier("fontSizeIncrease")
            }.buttonStyle(LexiControlStyle())
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                TextField("検索", text: $query).textFieldStyle(.plain)
                    .lexiFont(LexiTypography.search).accessibilityIdentifier("fontSearch")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("検索をクリア")
                }
            }.padding(.horizontal, 9).frame(height: 34)
                .background(LexiTheme.searchBackground(colorScheme == .dark), in: RoundedRectangle(cornerRadius: 7))
            fontRow("標準", family: nil)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(families.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { family in
                        fontRow(family, family: family)
                    }
                }
            }.frame(height: 244)
                .contentMargins(.trailing, LexiLayout.listScrollerGutter, for: .scrollContent)
        }
        .padding(8).frame(width: 276)
        .environment(\.lexiFontFamily, model.fontFamily)
        .environment(\.lexiFontSizeOffset, model.fontSizeOffset)
        .background(LexiTheme.contentBackground)
        .tint(LexiTheme.accent)
    }
    private func fontRow(_ label: String, family: String?) -> some View {
        LexiRowSurface(selected: model.fontFamily == family, height: 34) {
            Button {
                model.fontFamily = family
            } label: {
                HStack(spacing: 8) {
                    Text(label).font(LexiFontSupport.font(family, size: LexiTypography.body + CGFloat(model.fontSizeOffset)))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LexiTheme.accent).opacity(model.fontFamily == family ? 1 : 0)
                }.padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("font-" + (family ?? "default"))
        }
    }
}
