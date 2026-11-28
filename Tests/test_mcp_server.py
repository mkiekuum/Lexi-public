import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
MCP_BINARY = pathlib.Path(
    os.environ.get("LEXI_MCP_BINARY", ROOT / ".build/debug/LexiMCP")
)


@unittest.skipUnless(MCP_BINARY.is_file(), "Build LexiMCP before MCP integration tests.")
class MCPServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="lexi-mcp-test-")
        self.environment = os.environ.copy()
        self.environment["LEXI_MCP_LOG_PATH"] = str(
            pathlib.Path(self.directory.name) / "mcp-operations.jsonl"
        )
        self.process = subprocess.Popen(
            [str(MCP_BINARY), "--db", str(pathlib.Path(self.directory.name) / "Lexi.sqlite")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.environment,
        )
        response = self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "Lexi MCP tests", "version": "1"},
            },
        )
        self.assertEqual(response["result"]["serverInfo"]["name"], "lexi-local")

    def tearDown(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        self.process.stdout.close()
        self.process.stderr.close()
        self.directory.cleanup()

    def request(self, method, params=None):
        request_id = str(uuid.uuid4())
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            self.fail(self.process.stderr.read())
        response = json.loads(line)
        self.assertEqual(response.get("id"), request_id)
        return response

    def call(self, name, arguments=None):
        response = self.request(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
        )
        result = response["result"]
        text = result["content"][0]["text"]
        if result["isError"]:
            return None, text
        return json.loads(text), None

    def test_tools_are_declared_and_local_crud_search_works(self):
        response = self.request("tools/list")
        tools = {item["name"]: item for item in response["result"]["tools"]}
        self.assertIn("lexi_json_import_preview", tools)
        self.assertIn("lexi_batch_rollback", tools)
        self.assertIn("lexi_delete_folder", tools)
        self.assertEqual(
            tools["lexi_create_entry"]["inputSchema"]["properties"]["type"]["enum"],
            ["headword", "idiom", "example"],
        )
        entry, error = self.call(
            "lexi_create_entry",
            {"title": "MCP検索語", "type": "idiom", "note": "保存ノート"},
        )
        self.assertIsNone(error)
        results, error = self.call("lexi_search", {"query": "MCP検索語"})
        self.assertIsNone(error)
        self.assertEqual([row["id"] for row in results], [entry["id"]])
        loaded, error = self.call("lexi_get_entry", {"id": entry["id"]})
        self.assertIsNone(error)
        self.assertEqual(loaded["note"], "保存ノート")

    def test_direct_folder_browse_arrange_and_note_conflict(self):
        parent, err = self.call("lexi_create_folder", {"name": "親"})
        self.assertIsNone(err)
        child, err = self.call("lexi_create_folder", {"name": "子", "parent_id": parent["id"]})
        self.assertIsNone(err)
        a, err = self.call("lexi_create_entry", {"title": "同名", "folder_id": parent["id"], "note": "A"})
        self.assertIsNone(err)
        b, err = self.call("lexi_create_entry", {"title": "同名", "folder_id": child["id"], "note": "B"})
        self.assertIsNone(err)
        direct, err = self.call("lexi_browse_folder", {"folder_id": parent["id"]})
        self.assertIsNone(err)
        self.assertEqual([e["id"] for e in direct["entries"]], [a["id"]])
        self.assertEqual([f["id"] for f in direct["folders"]], [child["id"]])
        results, err = self.call("lexi_search", {"folder_id": parent["id"], "include_descendants": True})
        self.assertIsNone(err)
        self.assertEqual({e["id"] for e in results}, {a["id"], b["id"]})
        _, err = self.call("lexi_arrange_folders", {"ids": [parent["id"]], "parent_id": child["id"]})
        self.assertIsNotNone(err)
        _, err = self.call("lexi_arrange_folders", {"ids": [child["id"]], "parent_id": None, "before_id": parent["id"]})
        self.assertIsNone(err)
        _, err = self.call("lexi_update_note", {"id": a["id"], "note": "new", "baseline_note": "stale"})
        self.assertIsNotNone(err)
        _, err = self.call("lexi_update_note", {"id": a["id"], "note": "new", "baseline_note": "A"})
        self.assertIsNone(err)
        result, err = self.call("lexi_dictionary_refresh", {"ids": ["missing"]})
        self.assertIsNone(err)
        self.assertEqual(result["failed"], 1)

    def test_status_and_two_mode_preferences_are_database_scoped(self):
        status, error = self.call("lexi_status")
        self.assertIsNone(error)
        self.assertEqual(status["version"], "3.6.0")
        self.assertEqual(status["transport"], "stdio")
        self.assertEqual(status["tool_count"], 23)
        configuration = json.loads(status["configuration"])["mcpServers"]["lexi"]
        self.assertEqual(configuration["args"], ["--db", str(pathlib.Path(self.directory.name) / "Lexi.sqlite")])
        preferences, error = self.call("lexi_preferences")
        self.assertIsNone(error)
        self.assertEqual(preferences, {"appearance": "light"})
        preferences, error = self.call("lexi_preferences", {"appearance": "dark"})
        self.assertIsNone(error)
        self.assertEqual(preferences, {"appearance": "dark"})
        _, error = self.call("lexi_preferences", {"appearance": "system"})
        self.assertIsNotNone(error)
        saved = json.loads(pathlib.Path(status["database"] + ".preferences.json").read_text())
        self.assertEqual(saved, {"appearance": "dark"})

    def test_dictionary_source_connect_disconnect_and_validation(self):
        root = pathlib.Path(self.directory.name) / "external dictionary"
        (root / "Contents").mkdir(parents=True)
        (root / "Headline").mkdir()
        for name in ["headline.headlinestore.tsv", "short-headline.headlinestore.tsv"]:
            (root / "Headline" / name).write_text("100001-0000\t検証\n", encoding="utf-8")
        (root / "Contents" / "100001.xml").write_text(
            "<html><body><Contents><見出G><headword class='見出'>検証</headword></見出G><解説G><MG><meaning>synthetic body</meaning></MG></解説G></Contents></body></html>", encoding="utf-8")
        result, err = self.call("lexi_dictionary_source", {"action": "disconnect"})
        self.assertIsNone(err)
        self.assertFalse(result["available"])
        self.assertEqual(result["state"], "disconnected")
        _, err = self.call("lexi_dictionary_source", {"action": "get", "path": str(root)})
        self.assertIsNotNone(err)
        result, err = self.call("lexi_dictionary_source", {"action": "connect", "path": str(root)})
        self.assertIsNone(err)
        self.assertTrue(result["available"])
        self.assertEqual(result["state"], "connected")
        self.assertEqual(pathlib.Path(result["directory"]).resolve(), root.resolve())
        entry, err = self.call("lexi_create_entry", {"title": "検証", "note": "preserved"})
        self.assertIsNone(err)
        result, err = self.call("lexi_dictionary_refresh", {"id": entry["id"]})
        self.assertIsNone(err)
        self.assertTrue(result["updated"])
        before, _ = self.call("lexi_get_entry", {"id": entry["id"]})
        self.assertIn("synthetic body", before["dictionaryText"])
        _, err = self.call("lexi_dictionary_source", {"action": "connect", "path": str(root / "missing")})
        self.assertIsNotNone(err)
        status, err = self.call("lexi_status")
        self.assertIsNone(err)
        self.assertTrue(status["dictionary_available"])
        moved = root.with_name("moved dictionary")
        root.rename(moved)
        missing, err = self.call("lexi_dictionary_source")
        self.assertIsNone(err)
        self.assertEqual(missing["state"], "missing")
        _, err = self.call("lexi_dictionary_refresh", {"id": entry["id"]})
        self.assertIsNotNone(err)
        reconnected, err = self.call("lexi_dictionary_source", {"action": "connect", "path": str(moved)})
        self.assertIsNone(err)
        self.assertEqual(reconnected["state"], "connected")
        _, err = self.call("lexi_dictionary_source", {"action": "disconnect"})
        self.assertIsNone(err)
        after, err = self.call("lexi_get_entry", {"id": entry["id"]})
        self.assertIsNone(err)
        self.assertEqual(before, after)

    def test_folder_move_root_and_cycles(self):
        parent, _ = self.call("lexi_create_folder", {"name": "親"})
        child, _ = self.call("lexi_create_folder", {"name": "子"})
        moved, error = self.call("lexi_update_folder", {"id": child["id"], "parent_id": parent["id"]})
        self.assertIsNone(error)
        self.assertEqual(moved["parentID"], parent["id"])
        _, error = self.call("lexi_update_folder", {"id": parent["id"], "parent_id": child["id"]})
        self.assertIsNotNone(error)
        moved, error = self.call("lexi_update_folder", {"id": child["id"], "parent_id": None})
        self.assertIsNone(error)
        self.assertIsNone(moved.get("parentID"))

    def test_search_pagination_unorganized_and_validation(self):
        folder, _ = self.call("lexi_create_folder", {"name": "分類"})
        for title in ["あ", "い", "う"]:
            self.call("lexi_create_entry", {"title": title})
        self.call("lexi_create_entry", {"title": "え", "folder_id": folder["id"]})
        first, error = self.call("lexi_search", {"limit": 2, "offset": 0, "unorganized_only": True})
        self.assertIsNone(error)
        second, error = self.call("lexi_search", {"limit": 2, "offset": 2, "unorganized_only": True})
        self.assertIsNone(error)
        self.assertEqual(len(first), 2)
        self.assertEqual(len(second), 1)
        self.assertEqual({item["title"] for item in first + second}, {"あ", "い", "う"})
        for args in [{"limit": 0}, {"limit": 1.5}, {"limit": True}, {"offset": -1}, {"unknown": True}]:
            _, error = self.call("lexi_search", args)
            self.assertIsNotNone(error, args)

    def test_file_import_export_and_consistent_backup_without_overwrite(self):
        entry, _ = self.call("lexi_create_entry", {"title": "ファイル往復", "note": "保護ノート"})
        archive = pathlib.Path(self.directory.name) / "exports" / "lexi.json"
        exported, error = self.call("lexi_json_export", {"path": str(archive)})
        self.assertIsNone(error)
        self.assertEqual(exported["path"], str(archive))
        saved = json.loads(archive.read_text())
        self.assertEqual(saved["entries"][0]["id"], entry["id"])
        self.assertNotIn("dictionaryText", json.dumps(saved))
        preview, error = self.call("lexi_json_import_preview", {"path": str(archive)})
        self.assertIsNone(error)
        self.assertEqual(preview["preview"]["entriesToReuse"], 1)
        imported, error = self.call("lexi_json_import", {"preview_token": preview["preview_token"]})
        self.assertIsNone(error)
        self.assertIn("undo_token", imported)
        _, error = self.call("lexi_json_export", {"path": str(archive)})
        self.assertIsNotNone(error)
        snapshot = pathlib.Path(self.directory.name) / "snapshot.sqlite"
        _, error = self.call("lexi_backup", {"path": str(snapshot)})
        self.assertIsNone(error)
        with sqlite3.connect(snapshot) as connection:
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            self.assertEqual(connection.execute("SELECT note FROM entries WHERE id=?", (entry["id"],)).fetchone()[0], "保護ノート")
        _, error = self.call("lexi_backup", {"path": str(snapshot)})
        self.assertIsNotNone(error)
        _, error = self.call("lexi_json_import_preview", {"path": str(archive), "json": "{}"})
        self.assertIsNotNone(error)

    def test_batch_delete_preview_rollback_restores_entry_and_folders(self):
        folder, error = self.call("lexi_create_folder", {"name": "復元分類"})
        self.assertIsNone(error)
        entry, error = self.call(
            "lexi_create_entry",
            {"title": "復元項目", "type": "headword", "note": "残すノート", "folder_id": folder["id"]},
        )
        self.assertIsNone(error)
        preview, error = self.call(
            "lexi_batch_preview",
            {"operations": [{"op": "delete_entry", "id": entry["id"]}]},
        )
        self.assertIsNone(error)
        applied, error = self.call(
            "lexi_batch_apply", {"preview_token": preview["preview_token"]}
        )
        self.assertIsNone(error)
        _, error = self.call(
            "lexi_get_entry", {"id": entry["id"]}
        )
        self.assertIsNotNone(error)
        result, error = self.call(
            "lexi_batch_rollback", {"undo_token": applied["undo_token"]}
        )
        self.assertIsNone(error)
        restored, error = self.call("lexi_get_entry", {"id": entry["id"]})
        self.assertIsNone(error)
        self.assertEqual(restored["note"], "残すノート")
        self.assertEqual(restored["folderIDs"], [folder["id"]])
        self.assertEqual(result["rolled_back"], 1)

    def test_batch_undo_survives_server_restart_and_created_ids_are_stable(self):
        preview, error = self.call(
            "lexi_batch_preview",
            {
                "operations": [
                    {"op": "create_folder", "name": "再起動後に戻す"},
                    {"op": "create_entry", "title": "一時作成項目"},
                ]
            },
        )
        self.assertIsNone(error)
        applied, error = self.call(
            "lexi_batch_apply", {"preview_token": preview["preview_token"]}
        )
        self.assertIsNone(error)
        result, error = self.call("lexi_search", {"query": "一時作成項目"})
        self.assertIsNone(error)
        created_entry_id = result[0]["id"]

        database = pathlib.Path(self.directory.name) / "Lexi.sqlite"
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()
        self.process.stderr.close()
        self.process = subprocess.Popen(
            [str(MCP_BINARY), "--db", str(database)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.environment,
        )
        self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "Lexi MCP restart test", "version": "1"},
            },
        )
        rolled_back, error = self.call(
            "lexi_batch_rollback", {"undo_token": applied["undo_token"]}
        )
        self.assertIsNone(error)
        self.assertEqual(rolled_back["rolled_back"], 2)
        result, error = self.call("lexi_search", {"query": "一時作成項目"})
        self.assertIsNone(error)
        self.assertEqual(result, [])
        folders, error = self.call("lexi_list_folders")
        self.assertIsNone(error)
        self.assertEqual(folders, [])
        _, error = self.call("lexi_get_entry", {"id": created_entry_id})
        self.assertIsNotNone(error)

    def test_folder_delete_can_be_previewed_and_rolled_back(self):
        root, _ = self.call("lexi_create_folder", {"name": "親"})
        child, _ = self.call(
            "lexi_create_folder", {"name": "子", "parent_id": root["id"]}
        )
        entry, _ = self.call(
            "lexi_create_entry",
            {"title": "所属項目", "folder_id": child["id"], "note": "保護"},
        )
        preview, error = self.call(
            "lexi_batch_preview",
            {"operations": [{"op": "delete_folder", "id": root["id"]}]},
        )
        self.assertIsNone(error)
        applied, error = self.call(
            "lexi_batch_apply", {"preview_token": preview["preview_token"]}
        )
        self.assertIsNone(error)
        folders, error = self.call("lexi_list_folders")
        self.assertIsNone(error)
        self.assertEqual(folders, [])
        restored, error = self.call(
            "lexi_batch_rollback", {"undo_token": applied["undo_token"]}
        )
        self.assertIsNone(error)
        folders, _ = self.call("lexi_list_folders")
        self.assertEqual({folder["id"] for folder in folders}, {root["id"], child["id"]})
        entry_after, _ = self.call("lexi_get_entry", {"id": entry["id"]})
        self.assertEqual(entry_after["folderIDs"], [child["id"]])
        self.assertEqual(entry_after["note"], "保護")
        self.assertEqual(restored["rolled_back"], 1)

    def test_portable_json_preview_export_and_import(self):
        folder, _ = self.call("lexi_create_folder", {"name": "持出分類"})
        source, _ = self.call(
            "lexi_create_entry",
            {"title": "JSON項目", "type": "example", "note": "JSONノート", "folder_id": folder["id"]},
        )
        archive, error = self.call("lexi_json_export")
        self.assertIsNone(error)
        self.assertNotIn("dictionaryText", json.dumps(archive))
        self.assertNotIn("dictionaryRawXML", json.dumps(archive))
        self.assertEqual(archive["entries"][0]["id"], source["id"])
        self.assertEqual(archive["entries"][0]["note"], "JSONノート")
        encoded = json.dumps(archive, ensure_ascii=False)
        preview, error = self.call("lexi_json_import_preview", {"json": encoded})
        self.assertIsNone(error)
        self.assertEqual(preview["preview"]["entriesToReuse"], 1)
        self.assertEqual(preview["preview"]["folderLinksToAdd"], 0)
        imported, error = self.call(
            "lexi_json_import", {"preview_token": preview["preview_token"]}
        )
        self.assertIsNone(error)
        self.assertIsNotNone(imported["undo_token"])
        self.assertEqual(imported["preview"]["entriesToReuse"], 1)
        _, error = self.call(
            "lexi_batch_rollback", {"undo_token": imported["undo_token"]}
        )
        self.assertIsNone(error)

    def test_portable_json_round_trip_between_empty_databases_is_idempotent(self):
        root, _ = self.call("lexi_create_folder", {"name": "移行ルート"})
        child, _ = self.call(
            "lexi_create_folder",
            {"name": "子フォルダ", "parent_id": root["id"]},
        )
        shared, _ = self.call(
            "lexi_create_entry",
            {"title": "共有項目", "type": "idiom", "note": "保護するノート", "folder_id": root["id"]},
        )
        self.call(
            "lexi_update_entry",
            {"id": shared["id"], "folder_ids": [root["id"], child["id"]]},
        )
        self.call(
            "lexi_create_entry",
            {"title": "子だけの項目", "type": "example", "folder_id": child["id"]},
        )
        archive, error = self.call("lexi_json_export")
        self.assertIsNone(error)
        encoded = json.dumps(archive, ensure_ascii=False)
        self.assertNotIn("dictionaryText", encoded)
        self.assertNotIn("dictionaryRawXML", encoded)

        destination_dir = tempfile.TemporaryDirectory(prefix="lexi-json-roundtrip-")
        process = subprocess.Popen(
            [
                str(MCP_BINARY),
                "--db",
                str(pathlib.Path(destination_dir.name) / "Lexi.sqlite"),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.environment,
        )

        def request(method, params=None):
            request_id = str(uuid.uuid4())
            payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
            if params is not None:
                payload["params"] = params
            process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            if not line:
                self.fail(process.stderr.read())
            response = json.loads(line)
            self.assertEqual(response.get("id"), request_id)
            return response

        def call(name, arguments=None):
            result = request(
                "tools/call",
                {"name": name, "arguments": arguments or {}},
            )["result"]
            if result["isError"]:
                return None, result["content"][0]["text"]
            return json.loads(result["content"][0]["text"]), None

        def canonical(archive_value):
            return {
                **archive_value,
                "entries": sorted(archive_value["entries"], key=lambda item: item["id"]),
                "folders": sorted(archive_value["folders"], key=lambda item: item["id"]),
                "folderLinks": sorted(
                    archive_value["folderLinks"],
                    key=lambda item: (item["entryID"], item["folderID"]),
                ),
            }

        try:
            initialized = request(
                "initialize",
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "Lexi JSON round-trip test", "version": "1"},
                },
            )
            self.assertEqual(initialized["result"]["serverInfo"]["name"], "lexi-local")
            preview, error = call("lexi_json_import_preview", {"json": encoded})
            self.assertIsNone(error)
            self.assertEqual(preview["preview"]["entriesToCreate"], 2)
            self.assertEqual(preview["preview"]["foldersToCreate"], 2)
            self.assertEqual(preview["preview"]["folderLinksToAdd"], 3)
            imported, error = call(
                "lexi_json_import",
                {"preview_token": preview["preview_token"]},
            )
            self.assertIsNone(error)
            restored, error = call("lexi_json_export")
            self.assertIsNone(error)
            self.assertEqual(
                json.dumps(canonical(restored), ensure_ascii=False, sort_keys=True),
                json.dumps(canonical(archive), ensure_ascii=False, sort_keys=True),
            )

            repeated_preview, error = call("lexi_json_import_preview", {"json": encoded})
            self.assertIsNone(error)
            self.assertEqual(repeated_preview["preview"]["entriesToCreate"], 0)
            self.assertEqual(repeated_preview["preview"]["foldersToCreate"], 0)
            self.assertEqual(repeated_preview["preview"]["folderLinksToAdd"], 0)
            repeated, error = call(
                "lexi_json_import",
                {"preview_token": repeated_preview["preview_token"]},
            )
            self.assertIsNone(error)
            restored_again, error = call("lexi_json_export")
            self.assertIsNone(error)
            self.assertEqual(
                json.dumps(canonical(restored_again), ensure_ascii=False, sort_keys=True),
                json.dumps(canonical(archive), ensure_ascii=False, sort_keys=True),
            )
            self.assertEqual(imported["preview"]["entriesToCreate"], 2)
            self.assertEqual(repeated["preview"]["entriesToReuse"], 2)
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=10)
            process.stdout.close()
            process.stderr.close()
            destination_dir.cleanup()


if __name__ == "__main__":
    unittest.main()
