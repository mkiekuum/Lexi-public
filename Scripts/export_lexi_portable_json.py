#!/usr/bin/env python3
"""Export Lexi identities, notes and folder membership with dictionary content and identity."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import tempfile
from pathlib import Path


def export(database: Path, destination: Path, folder_id: str | None = None) -> dict:
    source = sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True)
    source.row_factory = sqlite3.Row
    try:
        folders = [dict(row) for row in source.execute(
            "SELECT id,name,parent_id,sort_order FROM folders ORDER BY sort_order,name"
        )]
        selected_folder_ids = {row["id"] for row in folders}
        if folder_id is not None:
            if folder_id not in selected_folder_ids:
                raise ValueError(f"Folder not found: {folder_id}")
            selected_folder_ids = {folder_id}
            changed = True
            while changed:
                changed = False
                for row in folders:
                    if row["parent_id"] in selected_folder_ids and row["id"] not in selected_folder_ids:
                        selected_folder_ids.add(row["id"])
                        changed = True
        folder_scope_ids = set(selected_folder_ids)
        folders_by_id = {row["id"]: row for row in folders}
        if folder_id is not None:
            parent_id = folders_by_id[folder_id]["parent_id"]
            while parent_id in folders_by_id and parent_id not in selected_folder_ids:
                selected_folder_ids.add(parent_id)
                parent_id = folders_by_id[parent_id]["parent_id"]
        selected_folders = [
            {
                "id": row["id"],
                "name": row["name"],
                "parentID": row["parent_id"],
                "sortOrder": row["sort_order"],
            }
            for row in folders
            if row["id"] in selected_folder_ids
        ]
        folder_paths = {}
        for folder in selected_folders:
            path = [folder["name"]]
            parent_id = folder["parentID"]
            visited = {folder["id"]}
            while parent_id in folders_by_id and parent_id not in visited:
                parent = folders_by_id[parent_id]
                visited.add(parent_id)
                path.insert(0, parent["name"])
                parent_id = parent["parent_id"]
            folder_paths[folder["id"]] = "/".join(path)
        links = [
            {"entryID": row["entry_id"], "folderID": row["folder_id"]}
            for row in source.execute(
                "SELECT entry_id,folder_id FROM entry_folders ORDER BY entry_id,folder_id"
            )
            if row["folder_id"] in folder_scope_ids
        ]
        entry_folder_ids: dict[str, list[str]] = {}
        for link in links:
            entry_folder_ids.setdefault(link["entryID"], []).append(link["folderID"])
        entry_columns = {row["name"] for row in source.execute("PRAGMA table_info(entries)")}
        identity_columns = [
            ("source_id", "sourceID"),
            ("dictionary_id", "dictionaryID"),
            ("content_version", "contentVersion"),
            ("source_entry_id", "sourceEntryID"),
            ("source_subentry_id", "sourceSubentryID"),
            ("dictionary_text", "dictionaryText"),
            ("dictionary_raw_xml", "dictionaryRawXML"),
            ("dictionary_structured", "dictionaryStructured"),
            ("dictionary_search_text", "dictionarySearchText"),
            ("dictionary_parser_version", "dictionaryParserVersion"),
            ("dictionary_content_hash", "dictionaryContentHash"),
            ("dictionary_parse_status", "dictionaryParseStatus"),
            ("dictionary_parse_error", "dictionaryParseError"),
        ]
        selected_columns = [
            "id", "title", "full_title", "type", "note", "parent_id",
            "needs_review", "created_at", "archive_version",
            *(column for column, _ in identity_columns if column in entry_columns),
        ]
        column_sql = ",".join(f'"{column}"' for column in selected_columns)
        if folder_id is None:
            rows = source.execute(f"SELECT {column_sql} FROM entries ORDER BY id")
        elif entry_folder_ids:
            placeholders = ",".join("?" for _ in entry_folder_ids)
            rows = source.execute(
                f"SELECT {column_sql} FROM entries WHERE id IN ({placeholders}) ORDER BY id",
                tuple(entry_folder_ids),
            )
        else:
            rows = []
        entry_rows = list(rows)
        included_ids = {row["id"] for row in entry_rows}
        entries = []
        for row in entry_rows:
            item = {
                "id": row["id"],
                "title": row["title"],
                "fullTitle": row["full_title"],
                "type": row["type"],
                "note": row["note"],
                "parentID": row["parent_id"] if row["parent_id"] in included_ids else None,
                "needsReview": bool(row["needs_review"]),
                "createdAt": row["created_at"],
                "archiveVersion": row["archive_version"],
            }
            for column, key in identity_columns:
                if column in entry_columns:
                    item[key] = row[column]
            entries.append(item)
        result = {
            "format": "lexi-portable",
            "version": 1,
            "entries": entries,
            "folders": selected_folders,
            "folderLinks": [link for link in links if link["entryID"] in included_ids],
            "folderPaths": folder_paths,
        }
    finally:
        source.close()

    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=".lexi-export-", dir=destination.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            json.dump(result, file, ensure_ascii=False, indent=2, sort_keys=True)
            file.write("\n")
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--folder-id")
    args = parser.parse_args()
    result = export(args.db, args.out, args.folder_id)
    print(json.dumps({
        "entries": len(result["entries"]),
        "folders": len(result["folders"]),
        "folderLinks": len(result["folderLinks"]),
        "dictionaryContentIncluded": True,
        "output": str(args.out),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
