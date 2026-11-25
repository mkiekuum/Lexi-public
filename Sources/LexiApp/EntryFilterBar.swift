import SwiftUI
import LexiCore

struct EntryFilterBar: View {
    @EnvironmentObject private var model: LexiViewModel
    var body: some View {
        HStack(spacing: 6) {
            LexiPopupButton(symbol: "square.grid.2x2", title: typeLabel, identifier: "typeFilterMenu", active: model.typeFilter != "all", fillsWidth: true) {
                choice("すべて", selected: model.typeFilter == "all") { model.typeFilter = "all" }
                ForEach(EntryType.allCases, id: \.rawValue) { type in
                    choice(type.japanese, selected: model.typeFilter == type.rawValue) { model.typeFilter = type.rawValue }
                }
                if model.typeFilter != "all" || model.noteFilter != nil || model.dictionaryFilter != nil {
                    Divider()
                    LexiPopupRow("絞り込みを解除", symbol: "xmark.circle") { model.clearEntryFilters() }
                }
            }
            LexiPopupButton(symbol: "square.and.pencil", title: model.noteFilter.map { $0 ? "ノートあり" : "ノートなし" } ?? "ノート", identifier: "noteFilterMenu", active: model.noteFilter != nil, fillsWidth: true) {
                choice("すべて", selected: model.noteFilter == nil) { model.noteFilter = nil }
                choice("あり", selected: model.noteFilter == true) { model.noteFilter = true }
                choice("なし", selected: model.noteFilter == false) { model.noteFilter = false }
            }
            LexiPopupButton(symbol: "book.closed", title: model.dictionaryFilter.map { $0 ? "辞典取得済み" : "辞典未取得" } ?? "辞典", identifier: "dictionaryFilterMenu", active: model.dictionaryFilter != nil, fillsWidth: true) {
                choice("すべて", selected: model.dictionaryFilter == nil) { model.dictionaryFilter = nil }
                choice("取得済み", selected: model.dictionaryFilter == true) { model.dictionaryFilter = true }
                choice("未取得", selected: model.dictionaryFilter == false) { model.dictionaryFilter = false }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("絞り込み")
    }
    private var typeLabel: String { EntryType(rawValue: model.typeFilter)?.japanese ?? "種類" }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        LexiPopupRow(title, symbol: selected ? "checkmark" : nil, action: action)
    }
}
