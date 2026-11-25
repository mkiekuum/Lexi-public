import importlib.util
import pathlib
import sqlite3
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "Scripts" / "repair_dictionary_display.py"
SPEC = importlib.util.spec_from_file_location("repair_dictionary_display", SCRIPT)
REPAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPAIR)


class DictionaryDisplayRepairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.database = self.root / "Lexi.sqlite"
        connection = sqlite3.connect(self.database)
        connection.executescript(
            """
            CREATE TABLE entries (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, full_title TEXT NOT NULL,
                note TEXT NOT NULL, updated_at REAL NOT NULL
            );
            INSERT INTO entries VALUES
                ('one','相打ち','あいうち【相打ち{hyoki-s}相撃ち】','keep note',123.0),
                ('two','作品{ZS:/}副題','作品{ZS:/}副題','','456.0'),
                ('three','正常','正常','untouched',789.0);
            """
        )
        connection.commit()
        connection.close()

    def tearDown(self):
        self.temporary.cleanup()

    def test_dry_run_does_not_change_database(self):
        result = REPAIR.repair_database(self.database)
        self.assertFalse(result["applied"])
        self.assertEqual(result["affected_entries"], 2)
        connection = sqlite3.connect(self.database)
        self.assertEqual(
            connection.execute("SELECT full_title FROM entries WHERE id='one'").fetchone()[0],
            "あいうち【相打ち{hyoki-s}相撃ち】",
        )
        connection.close()

    def test_apply_backups_and_preserves_unrelated_fields(self):
        backup = self.root / "backup.sqlite"
        result = REPAIR.repair_database(self.database, apply=True, backup_path=backup)
        self.assertTrue(result["applied"])
        self.assertEqual(result["verified_remaining_affected_entries"], 0)
        connection = sqlite3.connect(self.database)
        self.assertEqual(
            connection.execute("SELECT title,full_title,note,updated_at FROM entries WHERE id='one'").fetchone(),
            ("相打ち", "あいうち【相打ち・相撃ち】", "keep note", 123.0),
        )
        self.assertEqual(
            connection.execute("SELECT title,full_title,note,updated_at FROM entries WHERE id='three'").fetchone(),
            ("正常", "正常", "untouched", 789.0),
        )
        connection.close()
        backup_connection = sqlite3.connect(backup)
        self.assertEqual(backup_connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(
            backup_connection.execute("SELECT full_title FROM entries WHERE id='one'").fetchone()[0],
            "あいうち【相打ち{hyoki-s}相撃ち】",
        )
        backup_connection.close()


if __name__ == "__main__":
    unittest.main()
