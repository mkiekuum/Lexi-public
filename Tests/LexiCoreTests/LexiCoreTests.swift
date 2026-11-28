import XCTest
@testable import LexiCore

final class LexiCoreTests: XCTestCase {
    private func testDictionaryRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LEXI_DICTIONARY_TEST_ROOT"] else {
            throw XCTSkip("Set LEXI_DICTIONARY_TEST_ROOT to test the optional real dictionary")
        }
        return try DictionarySourceConfiguration.resolve(URL(fileURLWithPath: path))
    }
    private func fresh() throws -> LexiStore {
        try LexiStore(url:FileManager.default.temporaryDirectory.appendingPathComponent("lexi-test-\(UUID().uuidString).sqlite"))
    }
    func testMultipleDictionaryChoicesKeepOriginalNoteAndMembershipAndRollback() async throws {
        let root = try testDictionaryRoot()
        let store = try fresh()
        let folder = try store.createFolder(name: "辞典候補")
        let entry = try store.createEntry(title: "端緒", note: "原ノート")
        try store.addFolder(folder.id, to: entry.id)
        let provider = LocalDictionaryProvider(contentsDirectory: root.appendingPathComponent("Contents"), parserURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Scripts/daijisen_parser.py"))
        let matches = try await provider.matches(for: entry)
        XCTAssertEqual(matches.count, 2)
        var pairs: [(DictionaryMatch, DictionarySourceResult)] = []
        for m in matches { pairs.append((m, try await provider.retrieve(for: entry, match: m))) }
        let invalid = (pairs[1].0, pairs[0].1)
        XCTAssertThrowsError(try store.applyDictionaryChoices(requested: entry, choices: [pairs[0], invalid]))
        XCTAssertEqual(try store.listEntrySummaries(EntrySummaryQuery()).count, 1)
        XCTAssertTrue(try store.getEntry(entry.id).dictionaryText.isEmpty)
        let report = try store.applyDictionaryChoices(requested: entry, choices: pairs)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.updated, 2)
        let saved = try store.listEntrySummaries(EntrySummaryQuery()).map { try store.getEntry($0.id) }
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.map(\.fullTitle)), Set(matches.map(\.heading)))
        XCTAssertEqual(Set(saved.compactMap(\.sourceEntryID)).count, 2)
        XCTAssertTrue(saved.allSatisfy { $0.note == "原ノート" && $0.folderIDs == [folder.id] && !$0.dictionaryText.isEmpty })
        XCTAssertTrue(saved.contains { $0.id == entry.id })
    }

    func testFontPreferenceBackwardCompatible() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: LexiPreferences.url(for: url)) }
        try Data("{\"appearance\":\"dark\"}".utf8).write(to: LexiPreferences.url(for: url))
        XCTAssertNil(try LexiPreferences.load(for: url).fontFamily)
        try LexiPreferences(appearance: .dark, fontFamily: "Hiragino Sans").save(for: url)
        XCTAssertEqual(try LexiPreferences.load(for: url).fontFamily, "Hiragino Sans")
    }

    func testDictionaryRefreshWithoutSourceID() async throws {
        let root = try testDictionaryRoot()
        let contents = root.appendingPathComponent("Contents")
        let parser = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Scripts/daijisen_parser.py")
        guard FileManager.default.fileExists(atPath: contents.path) else { throw XCTSkip("ローカル辞典がありません") }
        let provider = LocalDictionaryProvider(contentsDirectory: contents, parserURL: parser)
        let store = try fresh()
        let entry = try store.createEntry(title: "相通じる", note: "保持")
        let result = try await provider.retrieve(for: entry)
        XCTAssertEqual(result.sourceKey, "002222-0000")
        XCTAssertTrue(try store.refreshDictionaryContent(requested: entry, result: result))
        let saved = try store.getEntry(entry.id)
        XCTAssertNil(saved.sourceID)
        XCTAssertEqual(saved.note, "保持")
        XCTAssertFalse(saved.dictionaryText.isEmpty)
        XCTAssertFalse(try store.refreshDictionaryContent(requested: saved, result: result))
        var renamed = saved
        renamed.title = "存在しないテスト見出しABCXYZ"
        try store.updateEntry(renamed)
        do {
            _ = try await provider.retrieve(for: renamed)
            XCTFail("存在しない見出しを推測してはいけません")
        } catch DictionarySourceError.identityMissing {}
        XCTAssertEqual(try store.getEntry(entry.id).dictionaryText, saved.dictionaryText)
    }

    func testExactShortNameIgnoresLegacyIdentityAndFullTitle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let headlines = dir.appendingPathComponent("Headline")
        try FileManager.default.createDirectory(at: headlines, withIntermediateDirectories: true)
        try "000001-0000\tあい【愛】\n000002-0000\tあい【藍】\n".write(to: headlines.appendingPathComponent("headline.headlinestore.tsv"), atomically: true, encoding: .utf8)
        try "000001-0000\tあい\n000002-0000\tあい\n".write(to: headlines.appendingPathComponent("short-headline.headlinestore.tsv"), atomically: true, encoding: .utf8)
        let first = LocalDictionaryProvider(contentsDirectory: dir.appendingPathComponent("Contents"), dictionaryName: "A")
        let second = LocalDictionaryProvider(contentsDirectory: dir.appendingPathComponent("Contents"), dictionaryName: "B")
        let registry = DictionaryRegistry(providers: [first, second])
        let entry = Entry(title: "あい", fullTitle: "あい【愛】", sourceID: "000001-0000-0073", sourceEntryID: "000001", sourceSubentryID: "0000")
        let matches = try await registry.matches(for: entry)
        XCTAssertEqual(matches.count, 4)
        XCTAssertEqual(Set(matches.map(\.dictionary)), ["A", "B"])
        var wrong = entry
        wrong.title = "アイ"
        let none = try await registry.matches(for: wrong)
        XCTAssertTrue(none.isEmpty)
        wrong.title = "あい "
        let trailing = try await registry.matches(for: wrong)
        XCTAssertTrue(trailing.isEmpty)
        do {
            _ = try await registry.retrieve(for: entry)
            XCTFail("歧義がある場合は自動選択しない")
        } catch DictionarySourceError.ambiguousTitle(let candidates) {
            XCTAssertEqual(candidates.count, 4)
        }
    }

    func testMultiplicityIndependentOfCurrentSearchAndFolderScope() throws {
        let store = try fresh()
        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B")
        let first = try store.createEntry(title: "同名", note: "first")
        let second = try store.createEntry(title: "同名", note: "second")
        let third = try store.createEntry(title: "同名", note: "third")
        try store.addFolder(a.id, to: first.id)
        try store.addFolder(b.id, to: first.id)
        try store.addFolder(a.id, to: second.id)
        try store.addFolder(b.id, to: third.id)
        let all = try store.listEntrySummaries()
        XCTAssertEqual(all.count, 3)
        let filtered = try store.listEntrySummaries(EntrySummaryQuery(query: "first", folderID: a.id))
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.duplicateCount, 3)
        XCTAssertEqual(filtered.first?.folderCount, 2)
        XCTAssertEqual(filtered.first?.sameTitleInFolderCounts, [a.id: 2, b.id: 2])
        XCTAssertEqual(try store.getEntry(second.id).note, "second")
        XCTAssertEqual(try store.getEntry(third.id).note, "third")
    }

    func testRenameEntryConflictAndPreservesOtherFields() async throws {
        let store = try fresh()
        let entry = try store.createEntry(title: "変更前", fullTitle: "変更前", note: "保持")
        let other = try store.createEntry(title: "同名")
        let folder = try store.createFolder(name: "分類")
        try store.addFolder(folder.id, to: entry.id)
        let service = try LexiDataService(url: store.url)
        let renamed = try await service.renameEntry(entryID: entry.id, title: " 同名 ", baselineTitle: entry.title)
        XCTAssertEqual(renamed.title, other.title)
        XCTAssertEqual(renamed.note, "保持")
        XCTAssertEqual(renamed.folderIDs, [folder.id])
        do {
            _ = try await service.renameEntry(entryID: entry.id, title: "古い変更", baselineTitle: entry.title)
            XCTFail("競合")
        } catch LexiError.conflict {}
        XCTAssertEqual(try store.getEntry(entry.id).title, "同名")
    }

    func testDirectFolderScopeAndCounts() async throws {
        let store = try fresh()
        let p = try store.createFolder(name: "親")
        let c = try store.createFolder(name: "子", parentID: p.id)
        let g = try store.createFolder(name: "孫", parentID: c.id)
        let a = try store.createEntry(title: "親だけ")
        let b = try store.createEntry(title: "子だけ")
        let d = try store.createEntry(title: "孫だけ")
        try store.addFolder(p.id, to: a.id)
        try store.addFolder(c.id, to: b.id)
        try store.addFolder(g.id, to: d.id)
        let service = try LexiDataService(url: store.url)
        let result = try await service.loadWorkspace(EntrySummaryQuery(folderID: p.id, includeDescendantFolders: false))
        XCTAssertEqual(result.entries.map(\.id), [a.id])
        XCTAssertEqual(result.folderCounts[p.id], 3)
        XCTAssertEqual(result.folderCounts[c.id], 2)
        XCTAssertEqual(result.folderCounts[g.id], 1)
        XCTAssertEqual(result.folders.filter { $0.parentID == p.id }.map(\.id), [c.id])
        XCTAssertEqual(try store.listEntrySummaries(EntrySummaryQuery(folderID: p.id)).count, 3)
    }

    func testFolderBadgesSumMembershipsAndFollowMoves() async throws {
        let store = try fresh()
        let parent = try store.createFolder(name: "親")
        let child = try store.createFolder(name: "子", parentID: parent.id)
        let sibling = try store.createFolder(name: "兄弟", parentID: parent.id)
        let empty = try store.createFolder(name: "空")
        let a = try store.createEntry(title: "直属")
        let b = try store.createEntry(title: "共通")
        try store.addFolder(parent.id, to: a.id)
        try store.addFolder(child.id, to: b.id)
        try store.addFolder(sibling.id, to: b.id)
        let service = try LexiDataService(url: store.url)
        var workspace = try await service.loadWorkspace(EntrySummaryQuery(folderID: parent.id, includeDescendantFolders: false))
        XCTAssertEqual(workspace.entries.map(\.id), [a.id])
        XCTAssertEqual(workspace.folderCounts[parent.id], 3)
        XCTAssertEqual(workspace.folderCounts[child.id], 1)
        XCTAssertEqual(workspace.folderCounts[sibling.id], 1)
        XCTAssertEqual(workspace.folderCounts[empty.id], 0)
        try store.arrangeFolders([child.id], parentID: empty.id)
        workspace = try await service.loadWorkspace(EntrySummaryQuery(folderID: parent.id, includeDescendantFolders: false))
        XCTAssertEqual(workspace.folderCounts[parent.id], 2)
        XCTAssertEqual(workspace.folderCounts[empty.id], 1)
        XCTAssertEqual(workspace.entries.map(\.id), [a.id])
        try store.deleteEntry(b.id)
        workspace = try await service.loadWorkspace()
        XCTAssertEqual(workspace.folderCounts[parent.id], 1)
        XCTAssertEqual(workspace.folderCounts[empty.id], 0)
    }

    func testArrangeFoldersPreservesChildrenAndRejectsCycles() throws {
        let store = try fresh()
        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B")
        let c = try store.createFolder(name: "C", parentID: a.id)
        let d = try store.createFolder(name: "D")
        let entry = try store.createEntry(title: "テスト", note: "保持")
        try store.addFolder(c.id, to: entry.id)
        try store.arrangeFolders([d.id], parentID: nil, beforeID: a.id)
        XCTAssertEqual(try store.listFolders().filter { $0.parentID == nil }.map(\.id), [d.id,a.id,b.id])
        XCTAssertThrowsError(try store.arrangeFolders([a.id], parentID: c.id))
        try store.arrangeFolders([a.id,c.id], parentID: b.id)
        let folders = try store.listFolders()
        XCTAssertEqual(folders.first { $0.id == a.id }?.parentID, b.id)
        XCTAssertEqual(folders.first { $0.id == c.id }?.parentID, a.id)
        XCTAssertEqual(try store.getEntry(entry.id).folderIDs, [c.id])
        try store.deleteFolders([a.id,c.id])
        XCTAssertEqual(try store.getEntry(entry.id).note, "保持")
        XCTAssertTrue(try store.getEntry(entry.id).folderIDs.isEmpty)
    }

    func testSearchJapaneseAndNotes() throws {
        let store = try fresh()
        let item = try store.createEntry(title:"カタカナ",fullTitle:"かたかな【片仮名】",note:"例の説明")
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"かたかな")).count,1)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"カタカナ")).count,1)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"片仮名")).count,1)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"説明")).count,1)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"本当")).count,0)
        var value = try store.getEntry(item.id)
        value.note = "編集したノート"; try store.updateEntry(value)
        XCTAssertEqual(try store.getEntry(item.id).note,"編集したノート")
    }
    func testDictionaryDisplayTextNormalizesInternalMonokakidoMarkers() {
        XCTAssertEqual(
            DictionaryDisplayText.clean("あいうち【相打ち{hyoki-s}相撃ち】仮面{ZS:/}ロッド"),
            "あいうち【相打ち・相撃ち】仮面／ロッド"
        )
    }
    func testDictionarySourceIdentityMatchesZeroPaddedNumericEntryIDs() {
        XCTAssertTrue(DictionarySourceIdentity.matches("14208-5002", "014208-5002"))
        XCTAssertFalse(DictionarySourceIdentity.matches("14208-5002", "14208-5003"))
        XCTAssertFalse(DictionarySourceIdentity.matches("14208-5002", "014208-50ZZ"))
    }
    func testExampleReferenceCountTreatsStyledSegmentsAsOneExactCitation() throws {
        let json = """
        {"parserVersion":"5","entryKind":"headword","sourceEntryID":"410295","sourceSubentryID":"0000",
         "heading":[],"headingSegments":[],"reading":"","writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"定義。",
         "segments":[
           {"kind":"text","text":"定義。"},
           {"kind":"text","text":"非礼","sourceID":"410295-5001"},
           {"kind":"ruby","text":"詫","reading":"わ","sourceID":"410295-5001"},
           {"kind":"text","text":"びる","sourceID":"410295-5001"},
           {"kind":"text","text":"別の用例","sourceID":"410295-5002"}
         ]}],
         "plainText":"定義。非礼を詫びる","unknownTags":[],"parseStatus":"parsed"}
        """
        let document = try JSONDecoder().decode(
            DictionaryStructuredDocument.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(
            DictionarySourceIdentity.referenceCount(in: document, sourceKey: "410295-5001"),
            1
        )
        XCTAssertEqual(
            DictionarySourceIdentity.referenceCount(in: document, sourceKey: "410295-5002"),
            1
        )
    }
    func testDictionaryFolderConfigurationIsIndependentOfDesktop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("Notebook.sqlite")
        let settings = DictionarySourceConfiguration()
        try settings.save(for: database)
        XCTAssertNil(try DictionarySourceConfiguration.load(for: database).root)
        XCTAssertFalse(try DictionarySourceConfiguration.load(for: database).available)
        XCTAssertThrowsError(try DictionarySourceConfiguration.resolve(root))
    }
    func testManyToManyFoldersAndNestedFiltering() throws {
        let store = try fresh()
        let main = try store.createFolder(name:"表現")
        let child = try store.createFolder(name:"慣用句",parentID:main.id)
        let other = try store.createFolder(name:"読書")
        let item = try store.createEntry(title:"口がうまい",type:.idiom)
        try store.addFolder(child.id,to:item.id)
        try store.addFolder(other.id,to:item.id)
        XCTAssertEqual(try store.getEntry(item.id).folderIDs.count,2)
        let summary = try XCTUnwrap(store.listEntrySummaries().first { $0.id == item.id })
        XCTAssertEqual(summary.folderCount,2)
        XCTAssertTrue(summary.belongsToMultipleFolders)
        XCTAssertEqual(try store.listEntries(SearchOptions(folderID:main.id)).count,1)
        try store.deleteFolder(main.id)
        XCTAssertEqual(try store.getEntry(item.id).folderIDs,[other.id])
    }
    func testEntryTypeFiltersWorkWithoutKeywordsAndCombineWithSearchFolderAndArchive() throws {
        let store = try fresh()
        let idiomFolder = try store.createFolder(name:"メディア語彙（成句）")
        let anotherFolder = try store.createFolder(name:"別分類")
        let idiom = try store.createEntry(title:"元も子もない",type:.idiom)
        let example = try store.createEntry(title:"非礼を詫びる",type:.example)
        let headword = try store.createEntry(title:"詫びる",type:.headword)
        let archivedIdiom = try store.createEntry(title:"旧成句",type:.idiom)
        try store.setDictionaryText(entryID:idiom.id,text:"利益を失う")
        try store.setDictionaryText(entryID:example.id,text:"非礼をわびる")
        try store.setDictionaryText(entryID:headword.id,text:"謝罪する")
        try store.setDictionaryText(entryID:archivedIdiom.id,text:"旧本文")
        var archived = try store.getEntry(archivedIdiom.id)
        archived.archiveVersion = "9"
        try store.updateEntry(archived)
        try store.addFolder(idiomFolder.id,to:idiom.id)
        try store.addFolder(idiomFolder.id,to:headword.id)
        try store.addFolder(anotherFolder.id,to:example.id)
        let allEntries = try store.listEntries(SearchOptions(archiveMode:"all"))
        let folders = try store.listFolders()
        let tags = try store.listTags()

        func filter(_ type: String, _ query: String = "", _ navigation: String = "all") -> [Entry] {
            EntryFiltering.filter(
                entries: allEntries,
                folders: folders,
                tags: tags,
                navigation: navigation,
                typeFilter: type,
                query: query,
                dictionaryFilter: nil,
                noteFilter: nil,
                sortOrder: "title"
            )
        }

        XCTAssertEqual(filter("idiom").map(\.id),[idiom.id])
        XCTAssertEqual(filter("example").map(\.id),[example.id])
        XCTAssertEqual(filter("idiom","元も子もない").map(\.id),[idiom.id])
        XCTAssertEqual(filter("example","非礼を詫びる").map(\.id),[example.id])
        XCTAssertEqual(filter("idiom","元も子もない","folder:\(idiomFolder.id)").map(\.id),[idiom.id])
        XCTAssertEqual(filter("example","非礼を詫びる","folder:\(anotherFolder.id)").map(\.id),[example.id])
        XCTAssertEqual(filter("headword","","folder:\(idiomFolder.id)").map(\.id),[headword.id])
        XCTAssertEqual(filter("idiom","語のない一致").count,0)
        XCTAssertEqual(filter("idiom").map(\.id),[idiom.id],"Clearing a query must restore the whole type-filtered set")
        XCTAssertEqual(filter("idiom","","archive").map(\.id),[archivedIdiom.id])
        XCTAssertEqual(filter("example","","archive").count,0)
    }
    func testFolderCycleRejected() throws {
        let store = try fresh()
        let p = try store.createFolder(name:"親")
        let c = try store.createFolder(name:"子",parentID:p.id)
        var parent = p; parent.parentID = c.id
        XCTAssertThrowsError(try store.updateFolder(parent))
    }
    func testTransactionRollsBackAcrossNestedCalls() throws {
        let store = try fresh()
        XCTAssertThrowsError(try store.withImportTransaction {
            let e = try store.createEntry(title:"未保存")
            var updated = try store.getEntry(e.id); updated.note="nested"
            try store.updateEntry(updated)
            throw LexiError.input("abort")
        })
        XCTAssertEqual(try store.listEntries().count,0)
    }
    func testSeedOnlyOnceEvenWhenEntriesDeleted() throws {
        let store = try fresh()
        try store.seedExamplesIfNeeded()
        XCTAssertEqual(try store.listEntries().count,5)
        try store.seedExamplesIfNeeded()
        XCTAssertEqual(try store.listEntries().count,5)
        for entry in try store.listEntries() { try store.deleteEntry(entry.id) }
        try store.seedExamplesIfNeeded()
        XCTAssertEqual(try store.listEntries().count,0)
    }
    func testJSONImportCreateWithContentsAndFolders() throws {
        let store = try fresh()
        let json = """
        {"folders":[{"path":"日本語/慣用句"}],"tags":[{"name":"重要","color":"#AACCAA"}],
        "entries":[{"title":"口がうまい","fullTitle":"くちがうまい","type":"idiom","note":"自分のメモ", "dictionaryText":"辞書の内容", "sourceID":"106385-4001-0073", "folders":["日本語/慣用句","読書"],"tags":["重要","会話"]}]}
        """
        let doc = try JSONDecoder().decode(LexiImportDocument.self,from:Data(json.utf8))
        let result = try store.importRecords(doc)
        XCTAssertEqual(result.created,1)
        let entry = try store.getEntry("106385-4001-0073")
        XCTAssertEqual(entry.dictionaryText,"辞書の内容")
        XCTAssertEqual(entry.note,"自分のメモ")
        XCTAssertEqual(entry.folderIDs.count,2)
        XCTAssertEqual(entry.tagIDs.count,2)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"辞書の内容")).count,1)
        XCTAssertEqual(try store.importRecords(doc).updated,0)
        XCTAssertEqual(try store.listEntries().count,1)
    }
    func testJSONImportPartialUpdatePreservesExistingFields() throws {
        let store = try fresh()
        let original = try store.createEntry(title:"旧題",note:"保存",sourceID:"abc")
        try store.setDictionaryText(entryID:original.id,text:"原文")
        let doc = try JSONDecoder().decode(LexiImportDocument.self,from:Data(#"{"entries":[{"sourceID":"abc","title":"新題"}]}"#.utf8))
        XCTAssertEqual(try store.importRecords(doc).updated,1)
        let e = try store.getEntry(original.id)
        XCTAssertEqual(e.title,"新題")
        XCTAssertEqual(e.note,"保存")
        XCTAssertEqual(e.dictionaryText,"原文")
    }

    func testJSONImportStableIDAndFolderMergeAreIdempotent() throws {
        let store = try fresh()
        let existing = try store.createEntry(
            title: "既存項目",
            fullTitle: "きそんこうもく",
            note: "個人ノート",
            sourceID: "existing-source"
        )
        let oldFolder = try store.createFolder(name: "既存分類")
        try store.addFolder(oldFolder.id, to: existing.id)
        let original = try store.getEntry(existing.id)
        let stableID = "7D69AF18-689D-5B05-83D4-19C54F7479A7"
        let document = try JSONDecoder().decode(
            LexiImportDocument.self,
            from: Data("""
            {
              "source": "word-vocabulary-docx",
              "folderMode": "merge",
              "entries": [
                {"id":"\(existing.id)","folders":["できる大人の語彙力3553"]},
                {"id":"\(stableID)","title":"新規項目","type":"headword","folders":["できる大人の語彙力3553"]}
              ]
            }
            """.utf8)
        )

        let first = try store.importRecords(document)
        XCTAssertEqual(first.created, 1)
        XCTAssertEqual(first.folderLinksAdded, 2)
        let existingAfterFirst = try store.getEntry(existing.id)
        XCTAssertEqual(existingAfterFirst.title, original.title)
        XCTAssertEqual(existingAfterFirst.fullTitle, original.fullTitle)
        XCTAssertEqual(existingAfterFirst.type, original.type)
        XCTAssertEqual(existingAfterFirst.note, original.note)
        XCTAssertEqual(existingAfterFirst.sourceID, original.sourceID)
        XCTAssertEqual(existingAfterFirst.updatedAt, original.updatedAt)
        let importFolderIDs = try store.listFolders().filter { $0.name == "できる大人の語彙力3553" }.map(\.id)
        XCTAssertEqual(importFolderIDs.count, 1)
        XCTAssertEqual(Set(existingAfterFirst.folderIDs), Set([oldFolder.id] + importFolderIDs))
        XCTAssertEqual(try store.getEntry(stableID).title, "新規項目")

        let second = try store.importRecords(document)
        XCTAssertEqual(second.created, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.folderLinksAdded, 0)
        XCTAssertEqual(try store.listEntries().count, 2)
        XCTAssertEqual(try store.getEntry(stableID).id, stableID)
        XCTAssertEqual(try store.getEntry(existing.id).note, "個人ノート")
    }

    func testPortableJSONRoundTripPreservesFolderTreeLinksNotesAndDictionaryData() throws {
        let source = try fresh()
        let root = try source.createFolder(name: "語彙")
        let child = try source.createFolder(name: "成句", parentID: root.id)
        let other = try source.createFolder(name: "別分類")
        let first = try source.createEntry(title: "元も子もない", fullTitle: "もともこもない", type: .idiom, note: "個人ノート")
        let second = try source.createEntry(title: "共有語", type: .headword, note: "共有メモ")
        let unorganized = try source.createEntry(title: "未整理語", note: "未整理メモ")
        try source.setDictionaryText(entryID: first.id, text: "この本文は書き出さない")
        var identified = try source.getEntry(first.id)
        identified.sourceID = "376131-4002-0073"
        identified.dictionaryID = "DAIJISEN2"
        identified.contentVersion = "12"
        identified.sourceEntryID = "376131"
        identified.sourceSubentryID = "4002"
        try source.updateEntry(identified)
        try source.addFolder(child.id, to: first.id)
        try source.addFolder(root.id, to: second.id)
        try source.addFolder(other.id, to: second.id)

        let allArchive = try source.portableArchive()
        XCTAssertEqual(allArchive.entries.count, 3, "Full export must include unorganized entries.")
        XCTAssertTrue(allArchive.entries.allSatisfy { $0.note.isEmpty == false })
        let encoded = try JSONEncoder().encode(allArchive)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("この本文は書き出さない"))
        XCTAssertTrue(json.contains("dictionaryText"))
        XCTAssertFalse(json.contains("dictionaryRawXML"))
        XCTAssertTrue(json.contains("376131-4002-0073"))
        XCTAssertTrue(json.contains("DAIJISEN2"))
        XCTAssertEqual(allArchive.folderPaths[child.id], "語彙/成句")

        let selectedArchive = try source.portableArchive(folderID: root.id)
        XCTAssertEqual(Set(selectedArchive.folders.map(\.id)), Set([root.id, child.id]))
        XCTAssertEqual(Set(selectedArchive.entries.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(
            Set(selectedArchive.folderLinks.map { "\($0.entryID):\($0.folderID)" }),
            Set(["\(first.id):\(child.id)", "\(second.id):\(root.id)"])
        )
        let selectedChildArchive = try source.portableArchive(folderID: child.id)
        XCTAssertEqual(Set(selectedChildArchive.folders.map(\.id)), Set([root.id, child.id]))
        XCTAssertEqual(Set(selectedChildArchive.entries.map(\.id)), Set([first.id]))
        XCTAssertEqual(selectedChildArchive.folderPaths[child.id], "語彙/成句")

        let destination = try fresh()
        var existing = try destination.createEntry(title: "元も子もない", fullTitle: "既存見出し", type: .idiom, note: "保存済みノート", id: first.id)
        try destination.setDictionaryText(entryID: existing.id, text: "保存済み本文")
        let before = try destination.getEntry(existing.id)
        let preview = try destination.previewPortableImport(allArchive)
        XCTAssertEqual(preview.entriesToCreate, 2)
        XCTAssertEqual(preview.entriesToReuse, 1)
        XCTAssertEqual(preview.foldersToCreate, 3)
        XCTAssertTrue(preview.conflicts.isEmpty)

        let applied = try destination.importPortableArchive(allArchive)
        XCTAssertEqual(applied.entriesToCreate, 2)
        XCTAssertEqual(applied.folderLinksToAdd, 3)
        let restored = try destination.getEntry(first.id)
        XCTAssertEqual(restored.note, before.note)
        XCTAssertEqual(restored.dictionaryText, before.dictionaryText)
        XCTAssertEqual(restored.title, before.title)
        XCTAssertEqual(restored.fullTitle, before.fullTitle)
        XCTAssertEqual(restored.type, before.type)
        XCTAssertNil(restored.sourceID)
        XCTAssertNil(restored.dictionaryID)
        XCTAssertNil(restored.contentVersion)
        XCTAssertNil(restored.sourceEntryID)
        XCTAssertNil(restored.sourceSubentryID)
        XCTAssertEqual(restored.folderIDs.count, 1)
        XCTAssertEqual(try destination.getEntry(second.id).folderIDs.count, 2)
        XCTAssertEqual(try destination.getEntry(unorganized.id).note, "未整理メモ")

        let repeated = try destination.importPortableArchive(allArchive)
        XCTAssertEqual(repeated.entriesToCreate, 0)
        XCTAssertEqual(repeated.entriesToReuse, 3)
        XCTAssertEqual(repeated.folderLinksToAdd, 0)
        XCTAssertEqual(try destination.listEntries(SearchOptions(archiveMode: "all")).count, 3)
        existing = try destination.getEntry(first.id)
        XCTAssertEqual(existing.note, "保存済みノート")
        XCTAssertEqual(existing.dictionaryText, "保存済み本文")
    }

    func testPortableJSONMultipleFolderExportUnionsDescendantsAndPreservesPaths() throws {
        let source = try fresh()
        let root = try source.createFolder(name: "親")
        let child = try source.createFolder(name: "子", parentID: root.id)
        let sibling = try source.createFolder(name: "除外", parentID: root.id)
        let other = try source.createFolder(name: "別")
        let grandchild = try source.createFolder(name: "孫", parentID: child.id)
        let direct = try source.createEntry(title: "親のみ", note: "親ノート")
        let shared = try source.createEntry(title: "共有", note: "共有ノート")
        let nested = try source.createEntry(title: "孫のみ")
        let excluded = try source.createEntry(title: "対象外")
        _ = try source.createEntry(title: "未整理")
        try source.addFolder(root.id, to: direct.id)
        try source.addFolder(child.id, to: shared.id)
        try source.addFolder(other.id, to: shared.id)
        try source.addFolder(grandchild.id, to: nested.id)
        try source.addFolder(sibling.id, to: excluded.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lexi-multi-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.exportPortableJSON(to: url, folderIDs: [child.id, other.id, grandchild.id, child.id])
        let archive = try LexiPortableImportPlan.decode(Data(contentsOf: url)).archive
        XCTAssertEqual(Set(archive.entries.map(\.id)), [shared.id, nested.id])
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(Set(archive.folders.map(\.id)), [root.id, child.id, grandchild.id, other.id])
        XCTAssertEqual(archive.folderPaths[grandchild.id], "親/子/孫")
        XCTAssertEqual(archive.folderLinks.count, 3)
        XCTAssertEqual(archive.entries.first { $0.id == shared.id }?.note, "共有ノート")
        let overlap = try source.portableArchive(folderIDs: [root.id, child.id, other.id])
        XCTAssertEqual(Set(overlap.entries.map(\.id)), [direct.id, shared.id, nested.id, excluded.id])
        XCTAssertEqual(overlap.entries.count, 4)
        XCTAssertThrowsError(try source.portableArchive(folderIDs: []))
        XCTAssertThrowsError(try source.portableArchive(folderIDs: [child.id, "missing"]))
        let destination = try fresh()
        _ = try destination.importPortableArchive(archive)
        XCTAssertEqual(Set(try destination.listEntries().map(\.id)), [shared.id, nested.id])
    }

    func testPortableJSONExportClearAndReimportRestoresIsolatedDatabaseExactly() throws {
        let source = try fresh()
        let root = try source.createFolder(name: "学習")
        let child = try source.createFolder(name: "成句", parentID: root.id)
        let other = try source.createFolder(name: "読書")
        var parent = try source.createEntry(title: "興じる", fullTitle: "きょうじる", note: "親ノート")
        parent.sourceID = "098175-0000-0073"
        parent.dictionaryID = "DAIJISEN2"
        parent.contentVersion = "12"
        parent.sourceEntryID = "098175"
        parent.sourceSubentryID = "0000"
        try source.updateEntry(parent)
        let example = try source.createEntry(
            title: "遊びに興じる",
            type: .example,
            note: "用例ノート",
            sourceID: "098175-5001-0073"
        )
        try source.addFolder(child.id, to: example.id)
        try source.addFolder(other.id, to: example.id)
        try source.setDictionaryText(entryID: example.id, text: "この辞典本文は JSON に含めない")

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexi-portable-\(UUID().uuidString).json")
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexi-roundtrip-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: exportURL)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: copyURL.path + suffix)
            }
        }
        try source.exportPortableJSON(to: exportURL)
        let exportedText = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exportedText.contains("この辞典本文は JSON に含めない"))

        try source.backup(to: copyURL)
        let isolated = try LexiStore(url: copyURL)
        try isolated.withImportTransaction {
            for entry in try isolated.listEntries(SearchOptions(archiveMode: "all")) {
                try isolated.deleteEntry(entry.id)
            }
            for folder in try isolated.listFolders() where folder.parentID == nil {
                try isolated.deleteFolder(folder.id)
            }
        }
        XCTAssertTrue(try isolated.listEntries(SearchOptions(archiveMode: "all")).isEmpty)
        XCTAssertTrue(try isolated.listFolders().isEmpty)

        let plan = try LexiPortableImportPlan.decode(Data(contentsOf: exportURL))
        XCTAssertTrue(plan.invalidItems.isEmpty)
        let preview = try isolated.previewPortableImport(plan.archive)
        XCTAssertEqual(preview.entriesToCreate, 2)
        XCTAssertEqual(preview.foldersToCreate, 3)
        _ = try isolated.importPortableArchive(plan.archive)
        XCTAssertEqual(try isolated.integrityCheck(), "ok")
        XCTAssertTrue(try isolated.db.query("PRAGMA foreign_key_check").isEmpty)
        let expected = try source.portableArchive()
        let actual = try isolated.portableArchive()
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: actual.entries.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: expected.entries.map { ($0.id, $0) })
        )
        XCTAssertEqual(
            Set(actual.folderLinks.map { "\($0.entryID):\($0.folderID)" }),
            Set(expected.folderLinks.map { "\($0.entryID):\($0.folderID)" })
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: actual.folders.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: expected.folders.map { ($0.id, $0) })
        )
        XCTAssertEqual(actual.folderPaths, expected.folderPaths)

        let beforeRepeat = try isolated.portableArchive()
        let entriesBeforeRepeat = try isolated.listEntries(SearchOptions(archiveMode: "all"))
        let repeated = try isolated.importPortableArchive(plan.archive)
        XCTAssertEqual(repeated.entriesToCreate, 0)
        XCTAssertEqual(repeated.folderLinksToAdd, 0)
        XCTAssertEqual(try isolated.portableArchive(), beforeRepeat)
        XCTAssertEqual(
            try isolated.listEntries(SearchOptions(archiveMode: "all")),
            entriesBeforeRepeat
        )
    }

    func testPortableJSONPlanSeparatesInvalidRowsFromValidRecords() throws {
        let json = """
        {
          "format":"lexi-portable",
          "version":1,
          "entries":[
            {"id":"valid","title":"有効項目","fullTitle":"","type":"headword","note":"","parentID":null,"needsReview":false,"createdAt":1,"archiveVersion":null},
            {"id":"invalid","title":"","fullTitle":"","type":"headword","note":"","parentID":null,"needsReview":false,"createdAt":1,"archiveVersion":null}
          ],
          "folders":[
            {"id":"folder","name":"有効分類","parentID":null,"sortOrder":0},
            {"id":"broken","name":"不正分類","parentID":null}
          ],
          "folderLinks":[
            {"entryID":"valid","folderID":"folder"},
            {"entryID":"valid","folderID":"broken"}
          ],
          "folderPaths":{"folder":"有効分類","broken":"不正分類"}
        }
        """
        let plan = try LexiPortableImportPlan.decode(Data(json.utf8))
        XCTAssertEqual(plan.archive.entries.map(\.id), ["valid"])
        XCTAssertEqual(plan.archive.folders.map(\.id), ["folder"])
        XCTAssertEqual(plan.archive.folderLinks.count, 1)
        XCTAssertEqual(plan.invalidItems.count, 3)
        XCTAssertEqual(plan.invalidItems.first?.item, "項目 2")
    }

    func testPortableJSONMapsExistingFolderPathsAcrossDifferentParentIDs() throws {
        let source = try fresh()
        let sourceRoot = try source.createFolder(name:"既存カテゴリ")
        let sourceChild = try source.createFolder(name:"子分類",parentID:sourceRoot.id)
        let sourceEntry = try source.createEntry(title:"共有語",note:"元ノート")
        try source.addFolder(sourceChild.id,to:sourceEntry.id)
        let archive = try source.portableArchive()

        let destination = try fresh()
        let destinationRoot = try destination.createFolder(name:"既存カテゴリ")
        let destinationChild = try destination.createFolder(name:"子分類",parentID:destinationRoot.id)
        _ = try destination.createEntry(title:"共有語",note:"保持するノート",id:sourceEntry.id)
        let preview = try destination.previewPortableImport(archive)
        XCTAssertEqual(preview.foldersToCreate,0)
        XCTAssertTrue(preview.conflicts.isEmpty)
        _ = try destination.importPortableArchive(archive)

        XCTAssertEqual(try destination.listFolders().count,2)
        let restored = try destination.getEntry(sourceEntry.id)
        XCTAssertEqual(restored.note,"保持するノート")
        XCTAssertEqual(restored.folderIDs,[destinationChild.id])
    }

    func testPortableJSONKeepsSameNameEntriesAndApplyIsAtomic() throws {
        let source = try fresh()
        let folder = try source.createFolder(name: "分類")
        let first = try source.createEntry(title: "同名項目", type: .headword, note: "ノート")
        let second = try source.createEntry(title: "別項目", type: .idiom)
        try source.addFolder(folder.id, to: first.id)
        try source.addFolder(folder.id, to: second.id)
        var archive = try source.portableArchive()

        let destination = try fresh()
        let duplicate = try destination.createEntry(title: "同名項目", type: .headword)
        let preview = try destination.previewPortableImport(archive)
        XCTAssertTrue(preview.conflicts.isEmpty)
        XCTAssertEqual(preview.entriesToCreate, 2)
        _ = try destination.importPortableArchive(archive)
        XCTAssertEqual(try destination.listEntries(SearchOptions(archiveMode: "all")).count, 3)
        XCTAssertEqual(try destination.getEntry(duplicate.id).note, "")
        XCTAssertEqual(try destination.getEntry(first.id).note, "ノート")
        XCTAssertEqual(try destination.listEntries(SearchOptions(query: "同名項目")).count, 2)


        archive = LexiPortableArchive(
            format: archive.format,
            version: archive.version,
            entries: [
                LexiPortableEntry(id: first.id, title: first.title, fullTitle: "", type: .headword, note: "", parentID: second.id, needsReview: false, createdAt: first.createdAt, archiveVersion: nil),
                LexiPortableEntry(id: second.id, title: second.title, fullTitle: "", type: .idiom, note: "", parentID: first.id, needsReview: false, createdAt: second.createdAt, archiveVersion: nil)
            ],
            folders: archive.folders,
            folderLinks: archive.folderLinks
        )
        let cycleDestination = try fresh()
        XCTAssertThrowsError(try cycleDestination.importPortableArchive(archive))
        XCTAssertTrue(try cycleDestination.listEntries(SearchOptions(archiveMode: "all")).isEmpty)
        XCTAssertTrue(try cycleDestination.listFolders().isEmpty)
    }

    func testOnDemandDictionaryUpdateIsSourceBoundIdempotentAndPreservesUserData() throws {
        let store = try fresh()
        let folder = try store.createFolder(name:"手動分類")
        var entry = try store.createEntry(
            title:"元も子もない",
            type:.idiom,
            note:"利用者のノート",
            sourceID:"376131-4002-0073"
        )
        entry.sourceEntryID = "376131"
        entry.sourceSubentryID = "4002"
        try store.updateEntry(entry)
        try store.addFolder(folder.id,to:entry.id)

        let structuredJSON = """
        {"parserVersion":"3","entryKind":"idiom","sourceEntryID":"376131","sourceSubentryID":"4002",
         "heading":["元も子もない"],"headingSegments":[],"reading":"","writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"元金も利息もない。",
         "segments":[{"kind":"text","text":"元金も利息もない。"}]}],
         "plainText":"元金も利息もない。","unknownTags":[],"parseStatus":"parsed"}
        """
        let structured = try JSONDecoder().decode(
            DictionaryStructuredDocument.self,
            from:Data(structuredJSON.utf8)
        )
        let result = DictionarySourceResult(
            sourceKey:"376131-4002",
            sourceKind:.idiom,
            rawXML:"<SubItem id=\"376131-4002\"/>",
            structured:structured,
            contentHash:"exact-source-hash",
            parserVersion:"3"
        )

        XCTAssertTrue(try store.updateDictionaryContent(entryID:entry.id,result:result))
        let saved = try store.getEntry(entry.id)
        XCTAssertEqual(saved.dictionaryText,"元金も利息もない。")
        XCTAssertEqual(saved.note,"利用者のノート")
        XCTAssertEqual(saved.folderIDs,[folder.id])
        XCTAssertEqual(saved.structuredDocument, structured)
        XCTAssertEqual(saved.dictionaryContentHash,"exact-source-hash")
        XCTAssertEqual(saved.dictionaryParserVersion,"3")
        XCTAssertEqual(saved.dictionaryRawXML,result.rawXML)
        let unchangedTimestamp = saved.updatedAt
        XCTAssertFalse(try store.updateDictionaryContent(entryID:entry.id,result:result))
        XCTAssertEqual(try store.getEntry(entry.id).updatedAt,unchangedTimestamp)

        let wrongSource = DictionarySourceResult(
            sourceKey:"376131-4003",
            sourceKind:.idiom,
            rawXML:"<SubItem id=\"376131-4003\"/>",
            structured:structured,
            contentHash:"wrong-source-hash",
            parserVersion:"3"
        )
        XCTAssertThrowsError(try store.updateDictionaryContent(entryID:entry.id,result:wrongSource))
        XCTAssertEqual(try store.getEntry(entry.id).dictionaryText,"元金も利息もない。")

        var example = try store.createEntry(
            title:"非礼を詫びる",
            type:.example,
            note:"用例の個人メモ",
            sourceID:"410295-5001-0073"
        )
        example.sourceEntryID = "410295"
        example.sourceSubentryID = "5001"
        try store.updateEntry(example)
        let parentJSON = """
        {"parserVersion":"3","entryKind":"headword","sourceEntryID":"410295","sourceSubentryID":"0000",
         "heading":["わ・びる【詫びる】"],"headingSegments":[],"reading":"わびる",
         "writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"謝る。非礼を詫びる。",
         "segments":[{"kind":"text","text":"謝る。"},{"kind":"example","text":"非礼を詫びる","sourceID":"410295-5001"}]}],
         "plainText":"謝る。非礼を詫びる。","unknownTags":[],"parseStatus":"parsed"}
        """
        let parent = try JSONDecoder().decode(
            DictionaryStructuredDocument.self,
            from:Data(parentJSON.utf8)
        )
        let context = DictionarySourceResult(
            sourceKey:"410295-5001",
            sourceKind:.example,
            rawXML:"<Contents><ExG id=\"410295-5001\"/></Contents>",
            structured:parent,
            contentHash:"parent-context-hash",
            parserVersion:"3"
        )
        XCTAssertTrue(try store.updateDictionaryContent(entryID:example.id,result:context))
        let savedExample = try store.getEntry(example.id)
        XCTAssertEqual(savedExample.type,.example)
        XCTAssertEqual(savedExample.note,"用例の個人メモ")
        XCTAssertTrue(savedExample.dictionaryText.contains("非礼を詫びる"))
        XCTAssertEqual(savedExample.structuredDocument?.entryKind,"headword")

        var paddedExample = try store.createEntry(
            title:"呼吸が荒い",
            type:.example,
            sourceID:"014208-5002-0073"
        )
        paddedExample.sourceEntryID = "014208"
        paddedExample.sourceSubentryID = "5002"
        try store.updateEntry(paddedExample)
        let paddedParentJSON = """
        {"parserVersion":"4","entryKind":"headword","sourceEntryID":"14208","sourceSubentryID":"0000",
         "heading":["あらい【荒い】"],"headingSegments":[],"reading":"あらい",
         "writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"呼吸が荒い。",
         "segments":[{"kind":"example","text":"「呼吸が―・い」","sourceID":"14208-5002"}]}],
         "plainText":"呼吸が荒い。","unknownTags":[],"parseStatus":"parsed"}
        """
        let paddedParent = try JSONDecoder().decode(
            DictionaryStructuredDocument.self,
            from:Data(paddedParentJSON.utf8)
        )
        let paddedContext = DictionarySourceResult(
            sourceKey:"014208-5002",
            sourceKind:.example,
            rawXML:"<Contents><ExG id=\"14208-5002\"/></Contents>",
            structured:paddedParent,
            contentHash:"padded-parent-context",
            parserVersion:"4"
        )
        XCTAssertTrue(try store.updateDictionaryContent(entryID:paddedExample.id,result:paddedContext))
        XCTAssertEqual(try store.getEntry(paddedExample.id).structuredDocument?.entryKind,"headword")
    }

    func testReadOnlyProviderParsesExactInstalledIdiomAndExampleWhenAvailable() async throws {
        let root = try testDictionaryRoot()
        let contents = root.appendingPathComponent("Contents",isDirectory:true)
        let parser = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Scripts/daijisen_parser.py")
        guard FileManager.default.fileExists(atPath:contents.path),
              FileManager.default.fileExists(atPath:parser.path) else {
            throw XCTSkip("ローカル辞典エクスポートがないため、実データ読み取りを省略しました")
        }
        let provider = LocalDictionaryProvider(contentsDirectory:contents,parserURL:parser)
        let samples: [(String,String,String,EntryType)] = [
            ("元も子もない","376131","4002",.idiom),
            ("非礼を詫びる","410295","5001",.example),
            ("呼吸が荒い","014208","5002",.example)
        ]
        for (title,sourceEntryID,subentryID,type) in samples {
            let entry = Entry(
                title:title,
                type:type,
                sourceID:"\(sourceEntryID)-\(subentryID)-0073",
                sourceEntryID:sourceEntryID,
                sourceSubentryID:subentryID
            )
            let result = try await provider.retrieve(for:entry)
            XCTAssertEqual(result.sourceKind,type)
            if type == .example {
                XCTAssertEqual(result.structured.entryKind, "headword")
                XCTAssertGreaterThan(result.structured.sections.count, 1)
                let expectedExampleKey = "\(sourceEntryID)-\(subentryID)"
                XCTAssertEqual(DictionarySourceIdentity.referenceCount(
                    in: result.structured,
                    sourceKey: expectedExampleKey
                ), 1)
            }
            XCTAssertEqual(result.sourceKey,"\(sourceEntryID)-\(subentryID)")
            XCTAssertFalse(result.structured.plainText.isEmpty)
            if type == .example {
                XCTAssertEqual(result.structured.entryKind,"headword")
                XCTAssertEqual(
                    DictionarySourceIdentity.referenceCount(
                        in: result.structured,
                        sourceKey: result.sourceKey
                    ),
                    1
                )
            }
        }
    }

    func testLightweightSummariesCombineTypeFolderDictionaryNoteAndBodySearch() throws {
        let store = try fresh()
        let folder = try store.createFolder(name:"辞典読書")
        let nested = try store.createFolder(name:"成句",parentID:folder.id)
        let idiom = try store.createEntry(title:"元も子もない",fullTitle:"もともこもない",type:.idiom,note:"記録")
        let example = try store.createEntry(title:"非礼を詫びる",fullTitle:"ひれいをわびる",type:.example)
        let headword = try store.createEntry(title:"詫びる",fullTitle:"わびる",type:.headword)
        try store.setDictionaryText(entryID:idiom.id,text:"利益を失う")
        try store.addFolder(nested.id,to:idiom.id)
        try store.addFolder(folder.id,to:headword.id)

        let all = try store.listEntrySummaries()
        XCTAssertEqual(Set(all.map(\.id)),Set([idiom.id,example.id,headword.id]))
        XCTAssertTrue(all.first(where:{$0.id == idiom.id})?.hasDictionary == true)
        XCTAssertTrue(all.first(where:{$0.id == idiom.id})?.hasNote == true)
        XCTAssertEqual(
            try store.listEntrySummaries(EntrySummaryQuery(type:.idiom,folderID:folder.id)).map(\.id),
            [idiom.id]
        )
        XCTAssertEqual(
            try store.listEntrySummaries(EntrySummaryQuery(query:"利益",type:.idiom)).map(\.id),
            [idiom.id]
        )
        XCTAssertEqual(
            try store.listEntrySummaries(EntrySummaryQuery(query:"ひれい",type:.example)).map(\.id),
            [example.id]
        )
        XCTAssertEqual(
            try store.listEntrySummaries(EntrySummaryQuery(hasDictionary:false,hasNote:false)).map(\.id).sorted(),
            [example.id,headword.id].sorted()
        )
        XCTAssertEqual(
            try store.listEntrySummaries(EntrySummaryQuery(unorganizedOnly:true)).map(\.id),
            [example.id]
        )
    }

    func testDictionaryStatusUsesVisibleBodyRatherThanSearchIndex() throws {
        let store = try fresh()
        var bodyOnly = try store.createEntry(title: "本文あり")
        bodyOnly.dictionaryText = "実際に表示される辞典本文"
        bodyOnly.dictionarySearchText = "\n"
        try store.updateEntry(bodyOnly)

        XCTAssertTrue(try store.getEntry(bodyOnly.id).hasUsableDictionary)
        XCTAssertTrue(try XCTUnwrap(store.listEntrySummaries().first).hasDictionary)
        XCTAssertTrue(try store.listEntrySummaries(EntrySummaryQuery(hasDictionary: true)).contains {
            $0.id == bodyOnly.id
        })

        var indexOnly = try store.createEntry(title: "索引のみ")
        indexOnly.dictionarySearchText = "検索用テキストだけ"
        try store.updateEntry(indexOnly)
        XCTAssertFalse(try store.getEntry(indexOnly.id).hasUsableDictionary)
        XCTAssertFalse(try store.listEntrySummaries().first(where: { $0.id == indexOnly.id })!.hasDictionary)

        var structuredOnly = try store.createEntry(title: "構造化本文")
        structuredOnly.dictionaryStructured = """
        {"parserVersion":"3","entryKind":"headword","sourceEntryID":"123456","sourceSubentryID":"0000",
         "heading":["構造化本文"],"headingSegments":[],"reading":"こうぞうかほんぶん","writtenForms":[],"accent":"",
         "sections":[],"plainText":"構造化された辞典本文","unknownTags":[],"parseStatus":"parsed"}
        """
        try store.updateEntry(structuredOnly)
        XCTAssertTrue(try store.getEntry(structuredOnly.id).hasUsableDictionary)
        XCTAssertTrue(try store.listEntrySummaries().first(where: { $0.id == structuredOnly.id })!.hasDictionary)

        var invalidStructure = try store.createEntry(title: "不正な構造")
        invalidStructure.dictionaryStructured = "{invalid"
        invalidStructure.dictionarySearchText = "索引のみ"
        try store.updateEntry(invalidStructure)
        XCTAssertFalse(try store.getEntry(invalidStructure.id).hasUsableDictionary)
        XCTAssertFalse(try store.listEntrySummaries().first(where: { $0.id == invalidStructure.id })!.hasDictionary)
    }

    func testExampleDictionaryCountsOnlyVerifiedParentContextAsRetrieved() throws {
        let store = try fresh()
        var example = try store.createEntry(title:"非礼を詫びる",type:.example)
        example.sourceEntryID = "410295"
        example.sourceSubentryID = "5001"
        example.sourceID = "410295-5001-0073"
        example.dictionaryText = "例：非礼を詫びる。"
        example.dictionarySearchText = example.dictionaryText
        try store.updateEntry(example)

        XCTAssertFalse(try store.getEntry(example.id).hasUsableDictionary)
        XCTAssertFalse(try XCTUnwrap(store.listEntrySummaries().first).hasDictionary)
        XCTAssertTrue(try store.listEntrySummaries(EntrySummaryQuery(hasDictionary:false)).contains {
            $0.id == example.id
        })

        let parentJSON = """
        {"parserVersion":"3","entryKind":"headword","sourceEntryID":"410295","sourceSubentryID":"0000",
         "heading":["詫びる"],"headingSegments":[],"reading":"わびる","writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"相手の無礼を謝る。",
         "segments":[{"kind":"example","text":"非礼を詫びる。","sourceID":"410295-5001"}]}],
         "plainText":"相手の無礼を謝る。非礼を詫びる。","unknownTags":[],"parseStatus":"parsed"}
        """
        example.dictionaryStructured = parentJSON
        example.dictionaryText = "相手の無礼を謝る。非礼を詫びる。"
        example.dictionarySearchText = example.dictionaryText
        try store.updateEntry(example)

        XCTAssertTrue(try store.getEntry(example.id).hasUsableDictionary)
        XCTAssertTrue(try XCTUnwrap(store.listEntrySummaries().first).hasDictionary)
        XCTAssertFalse(try store.listEntrySummaries(EntrySummaryQuery(hasDictionary:false)).contains {
            $0.id == example.id
        })
    }

    func testExampleDictionarySourceIDMatchingAllowsNumericZeroPaddingOnly() throws {
        let store = try fresh()
        var example = try store.createEntry(title: "遊びに興じる", type: .example)
        example.sourceEntryID = "098175"
        example.sourceSubentryID = "5001"
        example.sourceID = "098175-5001-0073"
        example.dictionaryText = "遊びに―・じる"
        example.dictionaryStructured = """
        {"parserVersion":"5","entryKind":"headword","sourceEntryID":"098175","sourceSubentryID":"0000",
         "heading":["興ずる"],"headingSegments":[],"reading":"きょうずる","writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"遊びに興じる。",
         "segments":[{"kind":"example","text":"遊びに―・じる","sourceID":"98175-5001"}]}],
         "plainText":"遊びに興じる。遊びに―・じる","unknownTags":[],"parseStatus":"parsed"}
        """
        try store.updateEntry(example)

        XCTAssertTrue(try store.getEntry(example.id).hasUsableDictionary)
        XCTAssertTrue(try XCTUnwrap(store.listEntrySummaries().first).hasDictionary)
        XCTAssertFalse(try store.listEntrySummaries(EntrySummaryQuery(hasDictionary: false)).contains {
            $0.id == example.id
        })
    }

    func testExampleHexadecimalSubentryIDsAgreeWithDetailAndFilters() throws {
        let store = try fresh()
        var e = try store.createEntry(title: "血路を開く", type: .example)
        e.sourceEntryID = "018370"
        e.sourceSubentryID = "500F"
        e.dictionaryText = "用例"
        e.dictionaryStructured = """
        {"parserVersion":"7","entryKind":"headword","sourceEntryID":"18370","sourceSubentryID":"0000",
         "heading":["血路"],"headingSegments":[],"reading":"けつろ","writtenForms":[],"accent":"",
         "sections":[{"kind":"meaning","label":"","number":"1","text":"用例",
         "segments":[{"kind":"example","text":"用例","sourceID":"18370-500f"}]}],
         "plainText":"用例","unknownTags":[],"parseStatus":"parsed"}
        """
        try store.updateEntry(e)
        XCTAssertTrue(try store.getEntry(e.id).hasUsableDictionary)
        XCTAssertTrue(try XCTUnwrap(store.listEntrySummaries().first).hasDictionary)
        XCTAssertEqual(try store.listEntrySummaries(EntrySummaryQuery(hasDictionary: true)).map(\.id), [e.id])
        XCTAssertTrue(try store.listEntrySummaries(EntrySummaryQuery(hasDictionary: false)).isEmpty)
        e.dictionaryStructured = e.dictionaryStructured?.replacingOccurrences(of: "18370-500f", with: "18370A-500f")
        try store.updateEntry(e)
        XCTAssertFalse(try XCTUnwrap(store.listEntrySummaries().first).hasDictionary)
    }

    func testRealDatabaseSummaryAndSelectionPerformanceWhenFixtureProvided() async throws {
        guard let source = ProcessInfo.processInfo.environment["LEXI_PERFORMANCE_DB"] else {
            throw XCTSkip("LEXI_PERFORMANCE_DB が指定されていません")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexi-performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("Lexi.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: sourceURL, to: databaseURL)
        let service = try await Task.detached(priority: .utility) {
            try LexiDataService(url: databaseURL)
        }.value

        let listStart = Date()
        let all = try await service.loadWorkspace()
        let listSeconds = Date().timeIntervalSince(listStart)
        XCTAssertGreaterThan(all.entries.count, 5_000)
        XCTAssertLessThan(listSeconds, 2.0)

        let searchStart = Date()
        let search = try await service.loadWorkspace(EntrySummaryQuery(query: all.entries[0].title))
        let searchSeconds = Date().timeIntervalSince(searchStart)
        XCTAssertFalse(search.entries.isEmpty)
        XCTAssertLessThan(searchSeconds, 2.0)

        let detailStart = Date()
        for item in all.entries.prefix(100) {
            _ = try await service.getEntry(item.id)
        }
        let detailSeconds = Date().timeIntervalSince(detailStart)
        XCTAssertLessThan(detailSeconds, 3.0)

        let example = try XCTUnwrap(all.entries.first(where: { $0.title == "非礼を詫びる" }))
        let original = try await service.getEntry(example.id)
        let provider = LocalDictionaryProvider(
            contentsDirectory: try testDictionaryRoot().appendingPathComponent("Contents"),
            parserURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Scripts/daijisen_parser.py")
        )
        let result = try await provider.retrieve(for: original)
        XCTAssertEqual(result.structured.entryKind, "headword")
        let changed = try await service.refreshDictionaryContent(requested: original, result: result)
        let expectedChange = original.dictionaryText != result.structured.plainText
            || original.dictionaryRawXML != result.rawXML
            || original.structuredDocument != result.structured
            || original.dictionaryContentHash != result.contentHash
            || original.dictionaryParserVersion != result.parserVersion
        XCTAssertEqual(changed, expectedChange)
        let refreshed = try await service.getEntry(original.id)
        XCTAssertEqual(refreshed.type, .example)
        XCTAssertEqual(refreshed.note, original.note)
        XCTAssertEqual(refreshed.folderIDs, original.folderIDs)
        XCTAssertEqual(
            refreshed.structuredDocument.map {
                DictionarySourceIdentity.referenceCount(in: $0, sourceKey: result.sourceKey)
            },
            1
        )
        let fetchSeconds = Date().timeIntervalSince(detailStart) - detailSeconds
        print("Lexi performance: list=\(listSeconds)s bodySearch=\(searchSeconds)s 100Selections=\(detailSeconds)s exampleFetch=\(fetchSeconds)s")
    }

    func testInvalidDataRollsBackEntireImport() throws {
        let store = try fresh()
        let doc = try JSONDecoder().decode(LexiImportDocument.self,from:Data(#"{"entries":[{"title":"正常"},{"note":"タイトルなし"}]}"#.utf8))
        XCTAssertThrowsError(try store.importRecords(doc))
        XCTAssertEqual(try store.listEntries().count,0)
    }
    func testParentRequiresEvidenceAndNoCycles() throws {
        let store = try fresh()
        let parent = try store.createEntry(title:"口")
        let child = try store.createEntry(title:"口がうまい")
        let json = "{\"entries\":[{\"id\":\"\(child.id)\",\"parentID\":\"\(parent.id)\"}]}"
        XCTAssertThrowsError(try store.importRecords(JSONDecoder().decode(LexiImportDocument.self,from:Data(json.utf8))))
        var copy = try store.getEntry(child.id); copy.parentID = parent.id
        try store.updateEntry(copy)
        copy = try store.getEntry(parent.id); copy.parentID = child.id
        XCTAssertThrowsError(try store.updateEntry(copy))
    }
    func testTagsAndStatusFilters() throws {
        let store = try fresh()
        let tag = try store.createTag(name:"重要",color:"#AA9988")
        let item = try store.createEntry(title:"光")
        try store.addTag(tag.id,to:item.id)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"重要")).count,1)
        XCTAssertEqual(try store.listEntries(SearchOptions(hasDictionary:false)).count,1)
        try store.setDictionaryText(entryID:item.id,text:"説明")
        XCTAssertEqual(try store.listEntries(SearchOptions(hasDictionary:true)).count,1)
        XCTAssertEqual(try store.getEntry(item.id).dictionaryText,"説明")
    }
    func testJSONArchiveAndSQLiteBackup() throws {
        let store = try fresh()
        let tag = try store.createTag(name:"読書")
        let folder = try store.createFolder(name:"文")
        let entry = try store.createEntry(title:"文字",note:"memo")
        try store.addTag(tag.id,to:entry.id)
        try store.addFolder(folder.id,to:entry.id)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lexi-\(UUID().uuidString).json")
        try store.exportJSON(to:output)
        let second = try fresh()
        try second.restoreArchive(from:output)
        XCTAssertEqual(try second.getEntry(entry.id).tagIDs,[tag.id])
        XCTAssertEqual(try second.getEntry(entry.id).folderIDs,[folder.id])
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("lexi-\(UUID().uuidString).sqlite")
        try second.backup(to:backup)
        XCTAssertEqual(try LexiStore(url:backup).integrityCheck(),"ok")
        XCTAssertThrowsError(try second.backup(to:backup))
    }
    func testMergePreservesNotesCategoriesAndSourceAliases() throws {
        let store = try fresh()
        let source = try store.createEntry(title:"言葉",note:"ソース",sourceID:"source-A")
        let target = try store.createEntry(title:"言葉",note:"ターゲット",sourceID:"source-B")
        let folder = try store.createFolder(name:"学習")
        try store.addFolder(folder.id,to:source.id)
        let combined = try store.mergeEntries(sourceID:source.id,targetID:target.id)
        XCTAssertEqual(try store.listEntries().count,1)
        XCTAssertTrue(combined.note.contains("ソース"))
        XCTAssertTrue(combined.note.contains("ターゲット"))
        XCTAssertTrue(combined.folderIDs.contains(folder.id))
        XCTAssertEqual(try store.getEntry("source-A").id,target.id)
        XCTAssertEqual(try store.getEntry("source-B").id,target.id)
        let doc = try JSONDecoder().decode(LexiImportDocument.self,from:Data(#"{"entries":[{"sourceID":"source-A","note":"後から更新"}]}"#.utf8))
        _ = try store.importRecords(doc)
        XCTAssertEqual(try store.getEntry("source-B").note,"後から更新")
        XCTAssertEqual(try store.getEntry("source-A").sourceID,"source-B")
    }
    func testMergeConflictingDictionaryRejectsAndRollsBack() throws {
        let store = try fresh()
        let source = try store.createEntry(title:"同じ")
        let target = try store.createEntry(title:"同じ")
        try store.setDictionaryText(entryID:source.id,text:"本文A")
        try store.setDictionaryText(entryID:target.id,text:"本文B")
        XCTAssertThrowsError(try store.mergeEntries(sourceID:source.id,targetID:target.id))
        XCTAssertEqual(try store.listEntries().count,2)
        XCTAssertEqual(try store.mergeEntries(sourceID:source.id,targetID:target.id,dictionaryPreference:"source").dictionaryText,"本文A")
    }
    func testMonokakidoSearchURL() {
        let url = MonokakidoURL.searchURL(title:"口がうまい",type:.idiom)?.absoluteString ?? ""
        XCTAssertTrue(url.contains("scope=idiom"))
        XCTAssertTrue(url.contains("category=ja"))
        XCTAssertTrue(url.contains("mkdictionaries:"))
    }
    func testDuplicateTitlesDoNotMergeAutomatically() throws {
        let store = try fresh()
        let first = try store.createEntry(title:"行く",type:.headword,note:"最初")
        let second = try store.createEntry(title:"行く",type:.example,note:"別の文")
        XCTAssertNotEqual(first.id,second.id)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"行く")).count,2)
    }
    func testRemovingTagKeepsEntryAndItsNote() throws {
        let store = try fresh()
        let tag = try store.createTag(name:"復習",color:"#77A98B")
        let entry = try store.createEntry(title:"見る",note:"自由記述")
        try store.addTag(tag.id,to:entry.id)
        try store.deleteTag(tag.id)
        let after = try store.getEntry(entry.id)
        XCTAssertTrue(after.tagIDs.isEmpty)
        XCTAssertEqual(after.note,"自由記述")
    }
    func testDictionaryWritePreservesUserMetadata() throws {
        let store = try fresh()
        let folder = try store.createFolder(name:"表現")
        let tag = try store.createTag(name:"重要")
        let entry = try store.createEntry(title:"目を通す",note:"自分のノート",sourceID:"test-source")
        try store.addFolder(folder.id,to:entry.id)
        try store.addTag(tag.id,to:entry.id)
        try store.setDictionaryText(entryID:"test-source",text:"辞典テキスト")
        let after = try store.getEntry(entry.id)
        XCTAssertEqual(after.note,"自分のノート")
        XCTAssertEqual(after.dictionaryText,"辞典テキスト")
        XCTAssertEqual(after.folderIDs,[folder.id])
        XCTAssertEqual(after.tagIDs,[tag.id])
    }
    func testSearchIncludesNestedFolderPath() throws {
        let store = try fresh()
        let parent = try store.createFolder(name:"語彙ノート")
        let child = try store.createFolder(name:"慣用表現",parentID:parent.id)
        let entry = try store.createEntry(title:"静か",fullTitle:"しずか")
        try store.addFolder(child.id,to:entry.id)
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"語彙ノート")).map(\.id),[entry.id])
        XCTAssertEqual(try store.listEntries(SearchOptions(query:"慣用表現")).map(\.id),[entry.id])
    }
    func testSourceIDConflictIsRejected() throws {
        let store = try fresh()
        _ = try store.createEntry(title:"あ",sourceID:"duplicate-id")
        XCTAssertThrowsError(try store.createEntry(title:"い",sourceID:"duplicate-id"))
        XCTAssertEqual(try store.listEntries().count,1)
    }
    func testVersionedSourceIdentityKeepsSameNumericIDAsSeparateEntries() throws {
        let store = try fresh()
        func input(_ version:String,_ title:String) -> LexiEntryInput {
            var value = LexiEntryInput(title:title,sourceID:"123456-0000-0073")
            value.dictionaryID = "DAIJISEN2"
            value.contentVersion = version
            value.sourceEntryID = "123456"
            value.sourceSubentryID = "0000"
            value.dictionaryStructured = "{\"plainText\":\"\(title)\"}"
            value.dictionarySearchText = title
            value.dictionaryRawXML = "<Contents>\(title)</Contents>"
            value.dictionaryParseStatus = "parsed"
            return value
        }
        XCTAssertEqual(try store.importRecords(LexiImportDocument(entries:[input("9","旧語")])).created,1)
        XCTAssertEqual(try store.importRecords(LexiImportDocument(entries:[input("12","新語")])).created,1)
        let versions = try store.sourceEntries("123456-0000-0073")
        XCTAssertEqual(versions.count,2)
        XCTAssertEqual(Set(versions.compactMap(\.contentVersion)),["9","12"])
        XCTAssertEqual(Set(versions.map(\.id)).count,2)
        XCTAssertThrowsError(try store.getEntry("123456-0000-0073"))
        XCTAssertTrue(versions.allSatisfy{$0.dictionaryRawXML != nil && $0.dictionaryStructured != nil})
    }

    func testLegacyUniqueSourceIDMigrationPreservesRowsAndRelationships() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexi-legacy-migration-\(UUID().uuidString).sqlite")
        let old = try SQLiteConnection(path:url.path)
        try old.execute("""
            CREATE TABLE entries (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, full_title TEXT NOT NULL DEFAULT '',
                type TEXT NOT NULL CHECK(type IN ('headword','idiom','example')),
                note TEXT NOT NULL DEFAULT '', dictionary_text TEXT NOT NULL DEFAULT '',
                source_id TEXT UNIQUE, parent_id TEXT REFERENCES entries(id) ON DELETE SET NULL,
                needs_review INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            )
            """)
        try old.execute("CREATE TABLE folders(id TEXT PRIMARY KEY,name TEXT NOT NULL,parent_id TEXT,sort_order INTEGER NOT NULL DEFAULT 0)")
        try old.execute("CREATE TABLE entry_folders(entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,PRIMARY KEY(entry_id,folder_id))")
        try old.execute("""
            INSERT INTO entries(id,title,type,note,source_id,created_at,updated_at)
            VALUES('parent','親','headword','保護するノート','same-source',1,1)
            """)
        try old.execute("""
            INSERT INTO entries(id,title,type,note,source_id,parent_id,created_at,updated_at)
            VALUES('child','子','idiom','子のノート','child-source','parent',2,2)
            """)
        try old.execute("INSERT INTO folders(id,name) VALUES('folder','ユーザー分類')")
        try old.execute("INSERT INTO entry_folders(entry_id,folder_id) VALUES('child','folder')")
        let store = try LexiStore(url:url)

        XCTAssertEqual(try store.integrityCheck(),"ok")
        XCTAssertTrue(try store.db.query("PRAGMA foreign_key_check").isEmpty)
        XCTAssertEqual(try store.getEntry("parent").note,"保護するノート")
        XCTAssertEqual(try store.getEntry("child").parentID,"parent")
        XCTAssertEqual(try store.getEntry("child").note,"子のノート")
        XCTAssertEqual(try store.getEntry("child").folderIDs,["folder"])
        XCTAssertTrue(try store.db.query("SELECT name FROM sqlite_master WHERE name='entries_pre_composite_identity'").isEmpty)
        let uniqueSourceIndexes = try store.db.query("PRAGMA index_list(entries)").compactMap { row -> String? in
            guard (row["unique"]?.double ?? 0) == 1, let name = row["name"]?.string else { return nil }
            let columns = try store.db.query("PRAGMA index_info('\(name)')").compactMap { $0["name"]?.string }
            return columns == ["source_id"] ? name : nil
        }
        XCTAssertTrue(uniqueSourceIndexes.isEmpty)
    }

    func testSQLiteBackupFromReadOnlyWALConnection() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexi-readonly-backup-\(UUID().uuidString).sqlite")
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexi-readonly-backup-copy-\(UUID().uuidString).sqlite")
        defer {
            for url in [sourceURL,backupURL] {
                for suffix in ["","-wal","-shm"] {
                    try? FileManager.default.removeItem(atPath:url.path+suffix)
                }
            }
        }
        do {
            let writer = try SQLiteConnection(path:sourceURL.path)
            try writer.execute("CREATE TABLE sample(value TEXT NOT NULL)")
            try writer.execute("INSERT INTO sample(value) VALUES('preserved')")
        }
        do {
            let reader = try SQLiteConnection(path:sourceURL.path,readOnly:true)
            try reader.backup(to:backupURL)
        }
        do {
            let copy = try SQLiteConnection(path:backupURL.path,readOnly:true)
            XCTAssertEqual(try copy.scalar("SELECT value FROM sample").string,"preserved")
        }
    }

    func testHistoricalClassificationArchivesOnlyExplicitVersionedSourceIDs() throws {
        let store = try fresh()
        func add(_ id:String,_ version:String) throws {
            var entry = try store.createEntry(title:id,sourceID:id)
            entry.dictionaryID = "DAIJISEN2"
            entry.contentVersion = version
            entry.sourceEntryID = "123456"
            entry.sourceSubentryID = version == "9" ? "4001" : "0000"
            try store.updateEntry(entry)
        }
        try add("111111-4001-0073","9")
        try add("222222-0000-0073","12")
        _ = try store.createEntry(title:"手作業")
        let result = try store.classifySourceVersions(
            currentSourceIDs:["222222-0000-0073"],
            historicalSourceIDs:["111111-4001-0073"],
            currentVersion:"12",historicalVersion:"9"
        )
        XCTAssertEqual(result["archived"],1)
        XCTAssertEqual(try store.listEntries().count,2)
        XCTAssertEqual(try store.listEntries(SearchOptions(archiveMode:"archive")).count,1)
        XCTAssertEqual(try store.listEntries(SearchOptions(archiveMode:"all")).count,3)
    }

    func testHistoricalClassificationLeavesOverlappingUnversionedIDsUnclassified() throws {
        let store = try fresh()
        let entry = try store.createEntry(title:"版不明",sourceID:"111111-0000-0073")
        let result = try store.classifySourceVersions(
            currentSourceIDs:["111111-0000-0073"],
            historicalSourceIDs:["111111-0000-0073"],
            currentVersion:"12",historicalVersion:"9"
        )
        XCTAssertEqual(result["unclassified"],1)
        let unchanged = try store.getEntry(entry.id)
        XCTAssertNil(unchanged.contentVersion)
        XCTAssertNil(unchanged.archiveVersion)
    }

    func testHistoricalClassificationUsesExplicitlyVerifiedCurrentIDsForOverlap() throws {
        let store = try fresh()
        let entry = try store.createEntry(title:"現行確認済み",sourceID:"111111-0000-0073")
        let result = try store.classifySourceVersions(
            currentSourceIDs:["111111-0000-0073"],
            historicalSourceIDs:["111111-0000-0073"],
            currentVersion:"12",historicalVersion:"9",
            verifiedCurrentSourceIDs:["111111-0000-0073"]
        )
        XCTAssertEqual(result["current"],1)
        XCTAssertEqual(result["unclassified"],0)
        let classified = try store.getEntry(entry.id)
        XCTAssertEqual(classified.contentVersion,"12")
        XCTAssertNil(classified.archiveVersion)
    }

    func testFolderDeletePreservesUnassignedEntry() throws {
        let store = try fresh()
        let folder = try store.createFolder(name:"削除する分類")
        let entry = try store.createEntry(title:"残る項目",note:"消さない")
        try store.addFolder(folder.id,to:entry.id)
        try store.deleteFolder(folder.id)
        XCTAssertEqual(try store.getEntry(entry.id).note,"消さない")
        XCTAssertTrue(try store.getEntry(entry.id).folderIDs.isEmpty)
    }

    func testDictionaryIDRelinksWithoutChangingInternalIdentity() throws {
        let store = try fresh()
        let original = try store.createEntry(title:"メモの名前",note:"人が書いたノート")
        let document = try JSONDecoder().decode(LexiImportDocument.self, from: Data("""
        {"entries":[{"id":"\(original.id)","sourceID":"000004-0000-0073","fullTitle":"あ【堊】","dictionaryText":"辞典の本文"}]}
        """.utf8))
        XCTAssertEqual(try store.importRecords(document).updated,1)
        let value = try store.getEntry("000004-0000-0073")
        XCTAssertEqual(value.id,original.id)
        XCTAssertEqual(value.title,"メモの名前")
        XCTAssertEqual(value.fullTitle,"あ【堊】")
        XCTAssertEqual(value.note,"人が書いたノート")
        XCTAssertEqual(value.dictionaryText,"辞典の本文")
    }
    func testOriginalBookmarkCreationDateSurvivesImport() throws {
        let store = try fresh()
        let doc = try JSONDecoder().decode(LexiImportDocument.self, from: Data("""
        {"entries":[{"sourceID":"000001-0000-0073","title":"亜","createdAt":1752649190.0,"folders":["本/ことば","小説"]}]}
        """.utf8))
        XCTAssertEqual(try store.importRecords(doc).created,1)
        let e = try store.getEntry("000001-0000-0073")
        XCTAssertEqual(e.createdAt,1752649190.0,accuracy:0.1)
        XCTAssertEqual(e.folderIDs.count,2)
        let update = try JSONDecoder().decode(LexiImportDocument.self,from: Data("""
        {"entries":[{"sourceID":"000001-0000-0073","dictionaryText":"辞書内容"}]}
        """.utf8))
        XCTAssertEqual(try store.importRecords(update).updated,1)
        let after = try store.getEntry(e.id)
        XCTAssertEqual(after.createdAt,e.createdAt,accuracy:0.1)
        XCTAssertEqual(after.folderIDs.count,2)
    }

    func testMonokakidoReconcileMovesDeletesAndPreservesManualData() throws {
        let store = try fresh()
        let manualFolder = try store.createFolder(name:"自分の分類")
        let first = LexiEntryInput(title:"朝活", fullTitle:"あさかつ【朝活】", type:.headword,
                                   note:"外部ノート", dictionaryText:"辞典本文 A", sourceID:"source-A",
                                   folders:["早起き"])
        let second = LexiEntryInput(title:"余す", sourceID:"source-B", folders:["早起き","テスト"])
        let firstImport = LexiImportDocument(entries:[first,second], source:"monokakido", folderMode:"merge")
        XCTAssertEqual(try store.importRecords(firstImport).created,2)
        try store.addFolder(manualFolder.id, to:try store.getEntry("source-A").id)
        var saved = try store.getEntry("source-A")
        saved.note = "自分のノート"
        try store.updateEntry(saved)

        let moved = LexiEntryInput(title:"朝活・改", fullTitle:"あさかつ【朝活・改】", type:.headword,
                                   note:"同期で上書きしない", dictionaryText:"辞典本文 A2", sourceID:"source-A",
                                   folders:["ブック"])
        let retained = LexiEntryInput(title:"余す", sourceID:"source-B", folders:["テスト"])
        let added = LexiEntryInput(title:"いざこざ", sourceID:"source-C", folders:["アナザー"])
        let snapshot = LexiImportDocument(entries:[moved,retained,added], source:"monokakido",
                                          folderMode:"reconcile", completeSnapshot:true)
        let report = try store.importRecords(snapshot)
        XCTAssertEqual(report.created,1)
        XCTAssertEqual(report.folderLinksRemoved,2)
        XCTAssertEqual(try store.getEntry("source-A").note,"自分のノート")
        XCTAssertEqual(try store.getEntry("source-A").dictionaryText,"辞典本文 A2")
        let folderNames = Dictionary(uniqueKeysWithValues:try store.listFolders().map{($0.id,$0.name)})
        XCTAssertEqual(Set(try store.getEntry("source-A").folderIDs.compactMap{folderNames[$0]}),["ブック","自分の分類"])
        XCTAssertEqual(Set(try store.getEntry("source-B").folderIDs.compactMap{folderNames[$0]}),["テスト"])
        XCTAssertEqual(Set(try store.getEntry("source-C").folderIDs.compactMap{folderNames[$0]}),["アナザー"])

        let beforeRepeat = try store.listEntries().sorted{$0.id < $1.id}
        let repeated = try store.importRecords(snapshot)
        let afterRepeat = try store.listEntries().sorted{$0.id < $1.id}
        XCTAssertEqual(repeated.created,0)
        XCTAssertEqual(repeated.folderLinksAdded,0)
        XCTAssertEqual(repeated.folderLinksRemoved,0)
        XCTAssertEqual(afterRepeat,beforeRepeat)

        let deletedSnapshot = LexiImportDocument(entries:[moved,added], source:"monokakido",
                                                 folderMode:"reconcile", completeSnapshot:true)
        _ = try store.importRecords(deletedSnapshot)
        XCTAssertEqual(try store.getEntry("source-B").title,"余す")
        XCTAssertTrue(try store.getEntry("source-B").folderIDs.isEmpty)
    }

    func testImportRejectsSourceIDCollisionWithoutChangingEntry() throws {
        let store = try fresh()
        let original = try store.createEntry(title:"本来の項目", note:"保存", sourceID:"source-A")
        var collision = LexiEntryInput(title:"誤った項目", dictionaryText:"誤った本文",
                                       sourceID:"source-B", folders:["別の分類"])
        collision.id = original.id
        XCTAssertThrowsError(try store.importRecords(LexiImportDocument(entries:[
            collision
        ], source:"monokakido", folderMode:"merge")))
        XCTAssertEqual(try store.getEntry("source-A").title,"本来の項目")
        XCTAssertEqual(try store.getEntry("source-A").note,"保存")
        XCTAssertEqual(try store.listFolders().count,0)
        XCTAssertThrowsError(try store.importRecords(LexiImportDocument(entries:[collision],
                                                                          source:"monokakido",
                                                                          folderMode:"reconcile")))
    }

    func testSourceFolderOwnershipSurvivesReopeningBeforeReconcile() throws {
        let store = try fresh()
        let entry = LexiEntryInput(title:"朝活", sourceID:"source-reopen", folders:["早起き"])
        _ = try store.importRecords(LexiImportDocument(entries:[entry], source:"monokakido", folderMode:"merge"))

        let reopened = try LexiStore(url:store.url)
        let emptySnapshot = LexiImportDocument(entries:[], source:"monokakido",
                                               folderMode:"reconcile", completeSnapshot:true)
        let report = try reopened.importRecords(emptySnapshot)
        XCTAssertEqual(report.folderLinksRemoved,1)
        XCTAssertTrue(try reopened.getEntry("source-reopen").folderIDs.isEmpty)
    }

    func testLegacyAdoptionIsLimitedToExactSourceFolderPairs() throws {
        let store = try fresh()
        let first = LexiEntryInput(title:"対象", sourceID:"source-target", folders:["旧分類"])
        let manualOnly = LexiEntryInput(title:"手作業", sourceID:"source-manual", folders:["旧分類"])
        _ = try store.importRecords(LexiImportDocument(entries:[first,manualOnly]))
        let snapshotEntry = LexiEntryInput(title:"対象", sourceID:"source-target", folders:["新分類"])
        let document = LexiImportDocument(
            entries:[snapshotEntry], source:"monokakido", folderMode:"reconcile",
            completeSnapshot:true,
            adoptLegacyFolderLinks:[LexiLegacyFolderLink(sourceID:"source-target",folderPath:"旧分類")]
        )
        let report = try store.importRecords(document)
        let folderNames = Dictionary(uniqueKeysWithValues:try store.listFolders().map{($0.id,$0.name)})
        XCTAssertEqual(report.legacyFolderLinksAdopted,1)
        XCTAssertEqual(report.folderLinksRemoved,1)
        XCTAssertEqual(Set(try store.getEntry("source-target").folderIDs.compactMap{folderNames[$0]}),["新分類"])
        XCTAssertEqual(Set(try store.getEntry("source-manual").folderIDs.compactMap{folderNames[$0]}),["旧分類"])
    }
}
