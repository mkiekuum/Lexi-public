import SwiftUI
import LexiCore

struct DictionaryChoiceSheet: View {
    @EnvironmentObject private var model: LexiViewModel
    let choice: LexiViewModel.DictionaryChoice
    @State private var selected: Set<String> = []
    @State private var focused: DictionaryMatch?
    @State private var preview: DictionarySourceResult?
    @State private var failure: String?
    @State private var cache: [String: DictionarySourceResult] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(choice.entry.title).lexiFont(22, weight: .bold)
                Spacer()
                Text("\(selected.count) 件選択").foregroundStyle(.secondary)
            }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(choice.matches) { match in
                            HStack(spacing: 8) {
                                Button {
                                    if selected.contains(match.id) { selected.remove(match.id) }
                                    else { selected.insert(match.id) }
                                    focused = match
                                } label: {
                                    Image(systemName: selected.contains(match.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selected.contains(match.id) ? LexiTheme.accent : .secondary)
                                        .frame(width: 28, height: 36).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(match.heading + "を選択")
                                    .accessibilityIdentifier("candidateSelect-" + match.id)
                                Button { focused = match } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(match.heading).fontWeight(.medium)
                                        Text(match.dictionary).lexiFont(LexiTypography.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("candidatePreview-" + match.id)
                            }
                            .padding(.horizontal, 5)
                            .background(focused == match ? LexiTheme.accent.opacity(0.15) : LexiTheme.subtleFill,
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.padding(5)
                }.frame(minWidth: 215, idealWidth: 240, maxWidth: 280)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let focused {
                            Text(focused.heading).lexiFont(15, weight: .semibold)
                            if let preview, preview.sourceKey == focused.locator, preview.providerName == focused.dictionary {
                                DictionaryDocumentView(document: preview.structured, entryTitle: "", entryFullTitle: "", showsDocumentHeading: true,
                                    highlightSourceID: choice.entry.type == .example ? preview.sourceKey : nil, onReference: { model.openMonokakidoSearch($0) })
                            } else if let failure {
                                Text(failure).foregroundStyle(.secondary)
                            } else { ProgressView("辞典本文を読み込んでいます…") }
                        }
                        Divider()
                        Text("ノート").lexiFont(15, weight: .semibold)
                        Text(choice.entry.note.isEmpty ? "なし" : choice.entry.note).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 340)
            }.frame(minHeight: 330)
            Divider()
            HStack {
                Button("すべての曖昧な項目をスキップ") { model.chooseDictionary(.skipAll) }
                    .accessibilityIdentifier("skipAllAmbiguity")
                Button("スキップ") { model.chooseDictionary(.skip) }
                    .accessibilityIdentifier("skipCurrentAmbiguity")
                Spacer()
                Button("\(selected.count) 件を取り込む") {
                    model.chooseDictionary(.selected(choice.matches.filter { selected.contains($0.id) }))
                }.disabled(selected.isEmpty).accessibilityIdentifier("confirmDictionaryChoices")
            }.buttonStyle(LexiControlStyle())
        }
        .padding(20)
        .frame(width: 780, height: 550)
        .background(LexiTheme.contentBackground)
        .onAppear { focused = choice.matches.first }
        .task(id: focused?.id) {
            preview = nil; failure = nil
            guard let match = focused else { return }
            if let cached = cache[match.id] { preview = cached; return }
            do {
                let result = try await model.previewDictionary(entry: choice.entry, match: match)
                guard !Task.isCancelled, focused == match else { return }
                cache[match.id] = result; preview = result
            } catch {
                guard !Task.isCancelled, focused == match else { return }
                failure = error.localizedDescription
            }
        }
    }
}
