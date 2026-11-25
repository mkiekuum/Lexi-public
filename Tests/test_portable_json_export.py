import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "export_lexi_portable_json", ROOT / "Scripts/export_lexi_portable_json.py"
)
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


class PortableJSONExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.directory.name)
        self.database = self.root / "Lexi.sqlite"
        with sqlite3.connect(self.database) as db:
            db.executescript(
                """
                CREATE TABLE folders(id TEXT PRIMARY KEY,name TEXT,parent_id TEXT,sort_order INTEGER);
                CREATE TABLE entries(
                  id TEXT PRIMARY KEY,title TEXT,full_title TEXT,type TEXT,note TEXT,
                  parent_id TEXT,needs_review INTEGER,created_at REAL,archive_version TEXT,
                  dictionary_text TEXT,dictionary_raw_xml TEXT,source_id TEXT,dictionary_id TEXT,
                  content_version TEXT,source_entry_id TEXT,source_subentry_id TEXT
                );
                CREATE TABLE entry_folders(entry_id TEXT,folder_id TEXT);
                INSERT INTO folders VALUES('root','表現',NULL,0);
                INSERT INTO folders VALUES('child','成句','root',1);
                INSERT INTO folders VALUES('other','別分類',NULL,2);
                INSERT INTO entries VALUES('a','元も子もない','もともこもない','idiom','ノート',NULL,0,1.0,NULL,'辞典本文','<private/>','376131-4002-0073','DAIJISEN2','12','376131','4002');
                INSERT INTO entries VALUES('b','共有語','','headword','共有ノート',NULL,0,2.0,NULL,'body','<xml/>',NULL,NULL,NULL,NULL,NULL);
                INSERT INTO entries VALUES('c','未整理項目','','headword','未整理',NULL,0,3.0,NULL,'body','<xml/>',NULL,NULL,NULL,NULL,NULL);
                INSERT INTO entry_folders VALUES('a','child');
                INSERT INTO entry_folders VALUES('b','root');
                INSERT INTO entry_folders VALUES('b','other');
                """
            )

    def tearDown(self):
        self.directory.cleanup()

    def test_all_export_includes_unorganized_entries_with_dictionary_data(self):
        output = self.root / "all.json"
        result = EXPORTER.export(self.database, output)
        self.assertEqual(len(result["entries"]), 3)
        self.assertEqual(len(result["folders"]), 3)
        self.assertEqual(len(result["folderLinks"]), 3)
        decoded = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(decoded["entries"][0]["id"], "a")
        entry = next(item for item in decoded["entries"] if item["id"] == "a")
        self.assertEqual(entry["sourceID"], "376131-4002-0073")
        self.assertEqual(entry["dictionaryID"], "DAIJISEN2")
        self.assertEqual(decoded["folderPaths"]["child"], "表現/成句")
        serialized = output.read_text(encoding="utf-8")
        self.assertNotIn("dictionary_text", serialized)
        self.assertEqual(entry["dictionaryText"], "辞典本文")
        self.assertEqual(entry["dictionaryRawXML"], "<private/>")

    def test_folder_export_includes_descendants_and_only_selected_memberships(self):
        result = EXPORTER.export(self.database, self.root / "subset.json", "root")
        self.assertEqual({folder["id"] for folder in result["folders"]}, {"root", "child"})
        self.assertEqual({entry["id"] for entry in result["entries"]}, {"a", "b"})
        self.assertEqual(
            {(link["entryID"], link["folderID"]) for link in result["folderLinks"]},
            {("a", "child"), ("b", "root")},
        )
        child = EXPORTER.export(self.database, self.root / "child.json", "child")
        self.assertEqual({folder["id"] for folder in child["folders"]}, {"root", "child"})
        self.assertEqual({entry["id"] for entry in child["entries"]}, {"a"})
        self.assertEqual(child["folderPaths"]["child"], "表現/成句")

    def test_missing_folder_fails_without_creating_export(self):
        destination = self.root / "missing.json"
        with self.assertRaises(ValueError):
            EXPORTER.export(self.database, destination, "not-found")
        self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
