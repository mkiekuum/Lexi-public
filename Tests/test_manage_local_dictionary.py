import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts" / "manage_local_dictionary.py"
SPEC = importlib.util.spec_from_file_location("manage_local_dictionary", SCRIPT)
manager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manager)


class LocalDictionaryManagerTests(unittest.TestCase):
    def make_dictionary(self, root: Path, body: str) -> Path:
        contents = root / "DAIJISEN.J" / "Contents"
        headlines = root / "DAIJISEN.J" / "Headline"
        contents.mkdir(parents=True)
        headlines.mkdir(parents=True)
        (contents / "000001.xml").write_text(body, encoding="utf-8")
        (headlines / "headline.headlinestore.tsv").write_text("id\ttitle\n", encoding="utf-8")
        (headlines / "short-headline.headlinestore.tsv").write_text("id\ttitle\n", encoding="utf-8")
        (root / "daijisen_parser.py").write_text('PARSER_VERSION = "5"\n', encoding="utf-8")
        return root

    def test_manifest_verifies_all_resources_and_detects_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_dictionary(Path(temporary) / "Dictionary", "<entry/>")
            manifest = manager.create_manifest(root, "fixture-1")
            self.assertEqual(manifest["xmlFileCount"], 1)
            self.assertEqual(manifest["resourceFileCount"], 4)
            self.assertEqual(manifest["sourceVersion"], "fixture-1")
            actual, _ = manager.build_manifest(root, "fixture-1")
            self.assertEqual(actual, manifest)

            candidate = self.make_dictionary(Path(temporary) / "Candidate", "<entry>new</entry>")
            compared = manager.compare_roots(root, candidate, "fixture-2")
            self.assertEqual(compared["addedCount"], 0)
            self.assertEqual(compared["removedCount"], 0)
            self.assertEqual(compared["changedCount"], 1)

            resource_only = Path(temporary) / "ResourceOnly"
            shutil.copytree(candidate / "DAIJISEN.J", resource_only / "DAIJISEN.J")
            compared_without_parser = manager.compare_roots(root, resource_only, "fixture-2")
            self.assertEqual(compared_without_parser["changedCount"], 1)

    def test_safe_install_keeps_a_complete_recovery_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            desktop = Path(temporary) / "Desktop"
            current = self.make_dictionary(desktop / "Lexi" / "Dictionary", "<old/>")
            manager.create_manifest(current, "fixture-1")
            candidate = self.make_dictionary(Path(temporary) / "Candidate", "<new/>")

            backup = manager.safe_install(current, candidate, "fixture-2")

            self.assertEqual((backup / "DAIJISEN.J" / "Contents" / "000001.xml").read_text(), "<old/>")
            self.assertEqual((current / "DAIJISEN.J" / "Contents" / "000001.xml").read_text(), "<new/>")
            self.assertEqual(manager.load_manifest(current)["sourceVersion"], "fixture-2")
            self.assertEqual(len(list((desktop / "Lexi" / "Backups").iterdir())), 1)


if __name__ == "__main__":
    unittest.main()
