import importlib.util
import pathlib
import sqlite3
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts" / "repair_dictionary_examples.py"
SPEC = importlib.util.spec_from_file_location("repair_dictionary_examples", SCRIPT)
REPAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPAIR)


class DictionaryExampleRepairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.database = self.root / "Lexi.sqlite"
        self.contents = self.root / "Contents"
        self.contents.mkdir()
        (self.contents / "001011.xml").write_text(
            """<?xml version="1.0" encoding="utf-8"?>
            <html><body><Contents>
              <見出G><headword class="見出">テスト親</headword></見出G>
              <解説G><MG><meaning>親見出しの全体定義。
                <ExG id="1011-5001">「テスト用例」</ExG>
              </meaning></MG></解説G>
            </Contents></body></html>""",
            encoding="utf-8",
        )
        connection = sqlite3.connect(self.database)
        connection.executescript(
            """
            CREATE TABLE entries (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, type TEXT NOT NULL,
                source_id TEXT, source_entry_id TEXT, source_subentry_id TEXT,
                archive_version TEXT, note TEXT NOT NULL, updated_at REAL NOT NULL,
                dictionary_text TEXT, dictionary_raw_xml TEXT, dictionary_structured TEXT,
                dictionary_search_text TEXT, dictionary_content_hash TEXT,
                dictionary_parser_version TEXT, dictionary_parse_status TEXT,
                dictionary_parse_error TEXT
            );
            INSERT INTO entries VALUES (
                'sample','テスト用例','example','001011-5001-0073','001011','5001',
                NULL,'個人ノート',123.0,'「テスト用例」','<ExG/>','{}','「テスト用例」',
                'old-hash','3','parsed',NULL
            );
            """
        )
        connection.commit()
        connection.close()

    def tearDown(self):
        self.temporary.cleanup()

    def test_plan_requires_exact_parent_and_retains_example_reference(self):
        plan = REPAIR.build_plan(self.database, self.contents)
        self.assertEqual(plan["examplesExamined"], 1)
        self.assertEqual(len(plan["plannedRepairs"]), 1)
        self.assertEqual(plan["unresolved"], [])
        repair = plan["plannedRepairs"][0]
        self.assertIn("親見出しの全体定義", repair["after"]["dictionary_text"])
        self.assertIn(
            "「テスト用例」",
            repair["after"]["dictionary_structured"],
        )
        self.assertNotEqual(repair["before"]["dictionary_text"], repair["after"]["dictionary_text"])

    def test_apply_is_backed_up_and_preserves_note_and_type(self):
        backup = self.root / "before.sqlite"
        result = REPAIR.repair_database(
            self.database, self.contents, apply=True, backup_path=backup
        )
        self.assertTrue(result["applied"])
        self.assertEqual(result["plannedRepairs"], 1)
        self.assertEqual(len(REPAIR.build_plan(self.database, self.contents)["plannedRepairs"]), 0)
        connection = sqlite3.connect(self.database)
        self.assertEqual(
            connection.execute(
                "SELECT type,note,dictionary_text FROM entries WHERE id='sample'"
            ).fetchone(),
            ("example", "個人ノート", "親見出しの全体定義。 「テスト用例」"),
        )
        connection.close()
        backup_connection = sqlite3.connect(backup)
        self.assertEqual(backup_connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(
            backup_connection.execute(
                "SELECT dictionary_text FROM entries WHERE id='sample'"
            ).fetchone()[0],
            "「テスト用例」",
        )
        backup_connection.close()


if __name__ == "__main__":
    unittest.main()
