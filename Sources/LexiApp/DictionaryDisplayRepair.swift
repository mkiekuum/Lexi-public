import Foundation
import LexiCore

enum DictionaryDisplayRepair {
    /// Only repair token boundaries for legacy parser output; don't change the saved body.
    static func repair(_ input: [DictionarySegment]) -> [DictionarySegment] {
        var out: [DictionarySegment] = []
        for var segment in input {
            if segment.kind == "ruby", let last = out.last,
               ["text", "link", "example"].contains(last.kind),
               last.target == segment.target, last.sourceID == segment.sourceID,
               let range = last.text.range(of: "[㐀-䶿一-鿿豈-﫿々〆〇]+$", options: .regularExpression),
               segment.text.range(of: "^[㐀-䶿一-鿿豈-﫿々〆〇]$", options: .regularExpression) != nil {
                var previous = out.removeLast()
                segment.text = String(previous.text[range]) + segment.text
                previous.text.removeSubrange(range)
                if !previous.text.isEmpty { out.append(previous) }
            }
            out.append(segment)
        }
        // v6 emitted grammar tags as separate literal text tokens.
        var inGrammar = false
        var afterGrammar = false
        for i in out.indices {
            guard out[i].kind == "text" else { inGrammar = false; afterGrammar = false; continue }
            let t = out[i].text
            if t.hasPrefix("〘") || t.hasPrefix("【") && t.hasSuffix("】") && t.count <= 9 &&
                t.range(of: "名|動|形|副|接|連|助|感|代", options: .regularExpression) != nil {
                inGrammar = t.hasPrefix("〘") && !t.contains("〙")
                out[i].kind = "grammar"; afterGrammar = !inGrammar
            } else if inGrammar {
                out[i].kind = "grammar"
                if t.contains("〙") { inGrammar = false; afterGrammar = true }
            } else if afterGrammar && ["スル", "する", "タリ", "ナリ"].contains(t) {
                out[i].kind = "grammar"
            } else {
                afterGrammar = false
            }
        }
        return out
    }
}
