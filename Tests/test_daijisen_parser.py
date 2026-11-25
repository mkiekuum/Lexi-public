import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PARSER_PATH = Path(__file__).resolve().parents[1] / "Scripts" / "daijisen_parser.py"
SPEC = importlib.util.spec_from_file_location("daijisen_parser", PARSER_PATH)
PARSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARSER)


def write_xml(directory: Path, stem: str, contents: str) -> Path:
    path = directory / f"{stem}.xml"
    path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        f'<Contents>{contents}</Contents></body></html>',
        encoding="utf-8",
    )
    return path


class DaijisenParserTests(unittest.TestCase):
    def test_grammar_and_compound_ruby_preserve_source_boundaries(self):
        xml = """<見出G><headword class="見出">あいがん</headword></見出G>
          <解説G><MG><meaning><hinshi>〘<a href="$hi">名</a>〙</hinshi><HinshiSahen>スル</HinshiSahen>大切にし、<a href="100002">薄氷<wari>はくひょう</wari></a>を履<wari>ふ</wari>む。</meaning></MG></解説G>"""
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        segs = result["structured"]["sections"][0]["segments"]
        self.assertEqual([s["text"] for s in segs if s["kind"] == "grammar"], ["〘名〙", "スル"])
        self.assertEqual([(s["text"], s["reading"]) for s in segs if s["kind"] == "ruby"], [("薄氷", "はくひょう"), ("履", "ふ")])

    def test_headword_extracts_metadata_numbered_meanings_ruby_examples_and_links(self):
        xml = """
        <見出G><headword class="見出">わ</headword><headword class="表記">【輪・環】</headword>
          <MAccentAudioG>わ<MAccentM>↓</MAccentM></MAccentAudioG></見出G>
        <解説G>
          <MG><meaning><a href="$g"><rect>1</rect></a>円形のもの。環<wari>かん</wari>。
            <ExG id="100001-5001">「指―」</ExG></meaning></MG>
          <MG><meaning><a href="$g"><rect>2</rect></a>関連項目 <a href="100002">輪郭</a>。</meaning></MG>
          <MG><meaning class="C"><a href="$c-ruigo">類語</a> 円・環</meaning></MG>
        </解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")

        document = result["structured"]
        self.assertEqual(document["reading"], "わ")
        self.assertEqual(document["writtenForms"], ["【輪・環】"])
        self.assertEqual(document["accent"], "わ↓")
        self.assertIn("heading-reading", document["headingSegments"][0]["styles"])
        self.assertTrue(any(
            "heading-written" in segment.get("styles", [])
            for segment in document["headingSegments"]
        ))
        self.assertEqual([x["number"] for x in document["sections"][:2]], ["1", "2"])
        self.assertFalse(document["sections"][0]["text"].startswith("1"))
        self.assertIn("円形のもの。環かん。", result["searchText"])
        ruby = next(x for x in document["sections"][0]["segments"] if x["kind"] == "ruby")
        self.assertEqual((ruby["text"], ruby["reading"]), ("環", "かん"))
        self.assertEqual(document["sections"][0]["segments"][-1]["kind"], "example")
        self.assertTrue(any(x["target"] == "100002" for x in document["sections"][1]["segments"] if x["kind"] == "link"))
        self.assertTrue(result["rawXML"])
        self.assertEqual(len(result["contentHash"]), 64)

    def test_headword_recursively_extracts_nested_meanings_and_exact_example_source_ids(self):
        xml = """
        <見出G><headword class="見出">さる</headword>
          <headword class="表記">【去る】</headword></見出G>
        <解説G>
          <MG class="L3"><meaning><a href="$g"><rect>1</rect></a>本来の意味。</meaning>
            <MG class="L4"><meaning><a href="$g"><L4>㋐</L4></a>ある場所から離れる。
              <ExG id="100001-5001">「この世を―・る」</ExG>
            </meaning></MG>
          </MG>
        </解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")

        sections = result["structured"]["sections"]
        self.assertEqual([section["number"] for section in sections], ["1", "㋐"])
        self.assertEqual([section["depth"] for section in sections], [0, 1])
        self.assertIn("ある場所から離れる", sections[1]["text"])
        cited = [
            segment for section in sections for segment in section["segments"]
            if segment.get("sourceID") == "100001-5001"
        ]
        self.assertTrue(cited)
        self.assertEqual("".join(segment["text"] for segment in cited), "「この世を―・る」")

    def test_idiom_extracts_only_exact_nested_subitem_not_parent_article(self):
        xml = """
        <見出G><headword class="見出">もと</headword></見出G>
        <解説G><MG><meaning>親見出しの別の説明。</meaning></MG>
          <SubItem id="100001-4001"><SubItemH><headword class="見出">元<wari>もと</wari>も子<wari>こ</wari>もない</headword></SubItemH>
            <SubItemC><MG><meaning>元金も利息もない。<ExG id="100001-5001">「失敗しては―・い」</ExG></meaning></MG></SubItemC>
          </SubItem>
          <SubItem id="100001-4002"><SubItemH><headword class="見出">別の成句</headword></SubItemH>
            <SubItemC><MG><meaning>別の定義。</meaning></MG></SubItemC>
          </SubItem>
        </解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-4001")

        self.assertEqual(result["sourceKind"], "idiom")
        self.assertIn("元金も利息もない", result["searchText"])
        self.assertNotIn("親見出し", result["searchText"])
        self.assertNotIn("別の定義", result["searchText"])
        self.assertEqual(result["structured"]["reading"], "元も子もない")
        rubies = [segment for segment in result["structured"]["headingSegments"] if segment["kind"] == "ruby"]
        self.assertEqual([(x["text"], x["reading"]) for x in rubies], [("元", "もと"), ("子", "こ")])

    def test_example_extracts_only_exact_exg_citation(self):
        xml = """
        <見出G><headword class="見出">わびる</headword></見出G>
        <解説G><MG><meaning>自分の非を認めて謝る。
          <ExG id="100001-5001">「非礼を―・びる」</ExG>
          <ExG id="100001-5002">「別の例文」</ExG>
        </meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-5001")

        self.assertEqual(result["sourceKind"], "example")
        self.assertEqual(result["searchText"], "「非礼を―・びる」")
        self.assertNotIn("別の例文", result["searchText"])
        self.assertNotIn("自分の非", result["searchText"])

    def test_example_ruby_and_emphasis_keep_the_exact_source_id(self):
        xml = """
        <見出G><headword class="見出">わびる</headword></見出G>
        <解説G><MG><meaning>語義。
          <ExG id="100001-5001">「<ExS><bold>非礼</bold>を詫<wari>わ</wari>びる</ExS>」</ExG>
        </meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        segments = result["structured"]["sections"][0]["segments"]
        ruby = next(segment for segment in segments if segment["kind"] == "ruby")
        self.assertEqual((ruby["text"], ruby["reading"]), ("詫", "わ"))
        self.assertEqual(ruby["sourceID"], "100001-5001")
        emphasized = next(segment for segment in segments if segment["text"] == "非礼")
        self.assertIn("strong", emphasized["styles"])
        self.assertEqual(emphasized["sourceID"], "100001-5001")

    def test_command_line_returns_one_exact_source_record_as_json(self):
        xml = """
        <見出G><headword class="見出">元も子もない</headword></見出G>
        <解説G><SubItem id="100001-4001"><SubItemH><headword>元も子もない</headword></SubItemH>
          <SubItemC><MG><meaning>元金も利息もない。</meaning></MG></SubItemC></SubItem>
          <SubItem id="100001-4002"><SubItemH><headword>別の成句</headword></SubItemH>
            <SubItemC><MG><meaning>別の定義。</meaning></MG></SubItemC></SubItem></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = subprocess.run(
                [sys.executable, str(PARSER_PATH), "--entry", str(path), "--source-key", "100001-4001"],
                check=True,
                capture_output=True,
                text=True,
            )
        document = json.loads(result.stdout)
        self.assertEqual(document["sourceKey"], "100001-4001")
        self.assertEqual(document["sourceKind"], "idiom")
        self.assertIn("元金も利息もない", document["searchText"])
        self.assertNotIn("別の定義", document["searchText"])

    def test_source_id_padding_is_normalized_and_ambiguous_nodes_are_rejected(self):
        xml = """
        <SubItem id="002008-4001"><SubItemH><headword>一</headword></SubItemH>
          <SubItemC><MG><meaning>定義。</meaning></MG></SubItemC></SubItem>
        <SubItem id="02008-4001"><SubItemH><headword>二</headword></SubItemH>
          <SubItemC><MG><meaning>別定義。</meaning></MG></SubItemC></SubItem>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "002008", xml)
            result = PARSER.extract_entry(path, "002008-4001")
        self.assertEqual(result["parseStatus"], "nested_entry_ambiguous")

    def test_unknown_tags_fallback_to_text_and_report_diagnostic(self):
        xml = """
        <見出G><headword class="見出">特殊</headword></見出G>
        <解説G><MG><meaning>長い説明。<mystery>特殊記号＆文字</mystery></meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        self.assertIn("特殊記号＆文字", result["searchText"])
        self.assertIn("mystery", result["structured"]["unknownTags"])

    def test_external_links_are_rendered_as_plain_text(self):
        xml = """
        <見出G><headword class="見出">参照</headword></見出G>
        <解説G><MG><meaning><a href="https://example.invalid/">外部</a>。</meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        segment = result["structured"]["sections"][0]["segments"][0]
        self.assertEqual(segment["kind"], "text")
        self.assertEqual(segment["text"], "外部")
        self.assertFalse(segment.get("target"))

    def test_inline_styles_and_explicit_breaks_survive_structured_parsing(self):
        xml = """
        <見出G><headword class="見出">整形</headword></見出G>
        <解説G><MG><meaning>通常<bold>強調</bold><italic>傾斜</italic>
          <Small>小字</Small><sup>上</sup><sub>下</sub><br/>次の行。<p>別段落。</p>
        </meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        section = result["structured"]["sections"][0]
        self.assertIn("次の行。", section["text"])
        self.assertIn("\n", section["text"])
        styles = {segment["text"]: segment.get("styles", []) for segment in section["segments"]}
        self.assertIn("strong", styles["強調"])
        self.assertIn("emphasis", styles["傾斜"])
        self.assertIn("small", styles["小字"])
        self.assertIn("superscript", styles["上"])
        self.assertIn("subscript", styles["下"])
        self.assertTrue(any(segment["kind"] == "break" for segment in section["segments"]))

    def test_related_links_and_image_captions_are_included_as_separate_sections(self):
        xml = """
        <見出G><headword class="見出">図版語</headword></見出G>
        <解説G>
          <MG><meaning>本義。</meaning></MG>
          <MUrlG><MUrl><MUrlTitle><a href="100002">類語項目</a></MUrlTitle>
            <MUrlUrl><a href="100002">参照</a></MUrlUrl></MUrl></MUrlG>
          <MLocationG><MLocation><a href="100003">地名参照</a></MLocation></MLocationG>
          <MImageG><MImage><img src="local.png" alt="図の代替文字"/></MImage>
            <MCaption>図の説明。</MCaption></MImageG>
        </解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        document = result["structured"]
        related = [section for section in document["sections"] if section["kind"] == "related"]
        illustrations = [section for section in document["sections"] if section["kind"] == "illustration"]
        self.assertEqual(len(related), 2)
        self.assertTrue(any(
            segment.get("target") == "100002"
            for section in related
            for segment in section["segments"]
        ))
        self.assertEqual(len(illustrations), 1)
        self.assertIn("図の代替文字", illustrations[0]["text"])
        self.assertIn("図の説明。", illustrations[0]["text"])

    def test_dictionary_display_markers_and_accent_label_are_structured(self):
        xml = """
        <見出G><headword class="見出">わ</headword>
          <headword class="表記">【輪<HyokiS>┊</HyokiS><a href="$jo"><常外音訓M>▽</常外音訓M></a>環】</headword>
          <MAccentAudioG><a href="$c-accent"><補足ロゴ>アクセント</補足ロゴ></a> わ<MAccentM>↓</MAccentM></MAccentAudioG>
        </見出G>
        <解説G><MG><meaning>環<wari>かん</wari>。</meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "407560", xml)
            result = PARSER.extract_entry(path, "407560-0000")
        document = result["structured"]
        self.assertEqual(document["writtenForms"], ["【輪・環】"])
        self.assertEqual(document["accent"], "わ↓")
        self.assertTrue(any(x["kind"] == "annotation" and x["text"] == "▽" for x in document["headingSegments"]))

    def test_internal_display_markers_are_normalized_in_plain_text_and_tsv_titles(self):
        xml = """
        <見出G><headword class="見出">あい</headword>
          <headword class="表記">相打ち{hyoki-s}相撃ち{ZS:/}表記</headword>
        </見出G>
        <解説G><MG><meaning>正しく表示する{hyoki-s}記号。</meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "001011", xml)
            result = PARSER.extract_entry(path, "001011-0000")
        document = result["structured"]
        self.assertEqual(document["writtenForms"], ["相打ち・相撃ち／表記"])
        self.assertEqual(result["searchText"], "正しく表示する・記号。")
        self.assertNotIn("{hyoki-s}", json.dumps(document, ensure_ascii=False))
        self.assertNotIn("{ZS:/}", json.dumps(document, ensure_ascii=False))

    def test_xml_entities_are_decoded_once_and_remain_visible_text(self):
        xml = """
        <見出G><headword class="見出">A&amp;B</headword></見出G>
        <解説G><MG><meaning>記号 &amp; 文字。&lt;引用&gt;</meaning></MG></解説G>
        """
        with tempfile.TemporaryDirectory() as directory:
            path = write_xml(Path(directory), "100001", xml)
            result = PARSER.extract_entry(path, "100001-0000")
        self.assertEqual(result["structured"]["reading"], "A&B")
        self.assertEqual(result["searchText"], "記号 & 文字。<引用>")

    def test_real_local_dictionaries_entries_are_extracted_by_exact_id(self):
        contents = Path.home() / "Desktop/Lexi/Dictionary/DAIJISEN.J/Contents"
        if not contents.is_dir():
            contents = Path.home() / "Desktop/LexiData/Dictionary/DAIJISEN.J/Contents"
        if not contents.is_dir():
            self.skipTest("local DAIJISEN2 export is unavailable")
        checks = [
            ("407606-0000", "ワークショップ", "headword"),
            ("274877-0000", "納得", "headword"),
            ("407560-0000", "輪・環", "headword"),
            ("376131-4002", "元も子もない", "idiom"),
            ("410295-5001", "非礼を詫びる", "example"),
        ]
        for source_key, expected, kind in checks:
            with self.subTest(source_key=source_key):
                result = PARSER.extract_entry(contents / f"{source_key.split('-')[0]}.xml", source_key)
                self.assertEqual(result["sourceKind"], kind)
                self.assertTrue(result["searchText"])
                if kind == "headword":
                    heading = "".join(result["structured"]["heading"] + result["structured"]["writtenForms"])
                    compact_heading = "".join(char for char in heading if char.isalnum())
                    compact_expected = "".join(char for char in expected if char.isalnum())
                    self.assertIn(compact_expected, compact_heading)
                    if expected == "輪・環":
                        self.assertEqual(result["structured"]["writtenForms"], ["【輪・環】"])
                        self.assertNotIn("アクセント", result["structured"]["accent"])
                elif kind == "idiom":
                    self.assertTrue(result["structured"]["headingSegments"])
                    self.assertTrue(any(
                        segment["kind"] == "ruby"
                        for segment in result["structured"]["headingSegments"]
                    ))
        parent = PARSER.extract_entry(contents / "151954.xml", "151954-0000")
        matching_sections = [
            section for section in parent["structured"]["sections"]
            if any(segment.get("sourceID") == "151954-5002" for segment in section["segments"])
        ]
        self.assertEqual(len(matching_sections), 1)
        self.assertIn("この世を", matching_sections[0]["text"])
        self.assertEqual(matching_sections[0]["number"], "㋐")


if __name__ == "__main__":
    unittest.main()
