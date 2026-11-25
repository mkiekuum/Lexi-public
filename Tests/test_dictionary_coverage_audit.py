import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts" / "audit_local_dictionary_coverage.py"
SPEC = importlib.util.spec_from_file_location("dictionary_coverage_audit", SCRIPT)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class DictionaryCoverageAuditTests(unittest.TestCase):
    def test_normalized_source_key_matches_numeric_padding_and_hex_case(self):
        self.assertEqual(AUDIT.normalized_key("001234-00af"), "1234-00AF")
        self.assertIsNone(AUDIT.normalized_key("1234-abc"))
        self.assertIsNone(AUDIT.normalized_key("not-an-id"))

    def test_audit_reports_exact_headword_and_example_without_writing_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contents = root / "Contents"
            contents.mkdir()
            database = root / "Lexi.sqlite"
            with sqlite3.connect(database) as connection:
                connection.execute(
                    """CREATE TABLE entries (
                        id TEXT, title TEXT, type TEXT, source_id TEXT,
                        source_entry_id TEXT, source_subentry_id TEXT,
                        dictionary_text TEXT, dictionary_structured TEXT,
                        dictionary_parse_status TEXT, archive_version TEXT
                    )"""
                )
                connection.executemany(
                    "INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        ("head", "わ", "headword", "123456-0000-0073",
                         "123456", "0000", "既存本文", None, None, None),
                        ("example", "非礼を詫びる", "example", "123456-5001-0073",
                         "123456", "5001", "", None, None, None),
                        ("missing", "孤立", "headword", None, None, None, "", None, None, None),
                    ],
                )
            (contents / "123456.xml").write_text(
                """<html><body><Contents>
                <見出G><headword class="見出">わ</headword></見出G>
                <解説G><MG><meaning>円形のもの。<ExG id="123456-5001">「非礼を詫びる」</ExG></meaning></MG></解説G>
                </Contents></body></html>""",
                encoding="utf-8",
            )

            report = AUDIT.audit(
                database,
                contents,
                ROOT / "Scripts" / "daijisen_parser.py",
            )

            outcomes = {item["id"]: item["audit_result"] for item in report["items"]}
            self.assertEqual(outcomes["head"], "exact_source_available")
            self.assertEqual(outcomes["example"], "exact_example_reference")
            self.assertEqual(outcomes["missing"], "source_id_missing_or_incomplete")
            self.assertEqual(report["entries_without_structured_dictionary"], 3)
            self.assertEqual(report["entries_without_structured_but_with_existing_text"], 1)
            with sqlite3.connect(database) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM entries").fetchone()[0], 3)
                self.assertIsNone(connection.execute(
                    "SELECT dictionary_structured FROM entries WHERE id='head'"
                ).fetchone()[0])


if __name__ == "__main__":
    unittest.main()
