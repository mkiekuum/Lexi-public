import XCTest
import LexiCore
@testable import LexiApp

final class DictionaryDisplayRepairTests: XCTestCase {
    func testLegacyGrammarAndRuby() throws {
        let json = """
        [{"kind":"text","text":"〘"},{"kind":"text","text":"名"},{"kind":"text","text":"〙"},{"kind":"text","text":"スル"},{"kind":"text","text":"大切にし、"},{"kind":"link","text":"薄","target":"100002"},{"kind":"ruby","text":"氷","reading":"はくひょう","target":"100002"}]
        """
        let source = try JSONDecoder().decode([DictionarySegment].self, from: Data(json.utf8))
        let repaired = DictionaryDisplayRepair.repair(source)
        XCTAssertEqual(repaired.filter { $0.kind == "grammar" }.map(\.text), ["〘","名","〙","スル"])
        XCTAssertEqual(repaired.last?.text, "薄氷")
        XCTAssertEqual(repaired.last?.reading, "はくひょう")
        XCTAssertEqual(repaired.map(\.text).joined(), source.map(\.text).joined())
    }
}
