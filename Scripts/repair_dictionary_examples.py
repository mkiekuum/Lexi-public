#!/usr/bin/env python3
"""Rebuild verified Lexi example entries with their exact parent dictionary context."""
from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import sqlite3
import sys
import time
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
PARSER_PATH = ROOT / "Scripts" / "daijisen_parser.py"
SPEC = importlib.util.spec_from_file_location("daijisen_parser", PARSER_PATH)
PARSER = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = PARSER
SPEC.loader.exec_module(PARSER)


DICTIONARY_FIELDS = (
    "dictionary_text",
    "dictionary_raw_xml",
    "dictionary_structured",
    "dictionary_search_text",
    "dictionary_content_hash",
    "dictionary_parser_version",
    "dictionary_parse_status",
    "dictionary_parse_error",
)


def _read_only_connection(database: pathlib.Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True, timeout=60)
    connection.row_factory = sqlite3.Row
    return connection


def _backup(database: pathlib.Path, backup_path: pathlib.Path) -> None:
    source = _read_only_connection(database)
    destination = sqlite3.connect(backup_path, timeout=60)
    try:
        source.backup(destination, pages=256, sleep=0.05)
        destination.commit()
        destination.execute("PRAGMA journal_mode=DELETE")
        if destination.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("SQLite backup integrity check failed")
        if destination.execute("PRAGMA foreign_key_check").fetchall():
            raise RuntimeError("SQLite backup has foreign key violations")
    finally:
        destination.close()
        source.close()


def _dictionary_source_key(entry: sqlite3.Row) -> str | None:
    entry_id = entry["source_entry_id"]
    subentry_id = entry["source_subentry_id"]
    if not entry_id or not subentry_id:
        return None
    if not entry_id.isdigit() or len(subentry_id) != 4:
        return None
    return f"{entry_id}-{subentry_id.upper()}"


def _verified_parent(
    entry: sqlite3.Row,
    contents_directory: pathlib.Path,
    xml_roots: dict[str, Any],
) -> tuple[dict[str, Any] | None, str | None]:
    source_key = _dictionary_source_key(entry)
    if source_key is None:
        return None, "Source ID fields are missing or invalid"
    source_id = entry["source_id"] or ""
    source_parts = source_id.split("-")
    if len(source_parts) < 2 or PARSER.canonical_source_key("-".join(source_parts[:2])) != \
            PARSER.canonical_source_key(source_key):
        return None, "Source ID disagrees with entry identity columns"

    entry_id = entry["source_entry_id"]
    xml_path = contents_directory / f"{entry_id}.xml"
    if not xml_path.is_file():
        return None, f"Dictionary XML is unavailable: {xml_path.name}"
    try:
        if entry_id not in xml_roots:
            xml_roots[entry_id] = PARSER.ET.parse(xml_path).getroot()
        parent = PARSER.extract_entry_from_root(xml_roots[entry_id], f"{entry_id}-0000")
    except (OSError, PARSER.ET.ParseError) as error:
        return None, f"Dictionary XML could not be parsed: {error}"

    if parent.get("parseStatus") != "parsed" or parent.get("sourceKind") != "headword":
        return None, f"Parent entry is not a parsed headword: {parent.get('parseStatus')}"
    structured = parent.get("structured", {})
    if PARSER.canonical_source_key(f"{structured.get('sourceEntryID', '')}-0000") != \
            PARSER.canonical_source_key(f"{entry_id}-0000"):
        return None, "Parent Source ID does not match the entry"
    wanted = PARSER.canonical_source_key(source_key)
    references = [
        segment
        for section in structured.get("sections", [])
        for segment in section.get("segments", [])
        if PARSER.canonical_source_key(segment.get("sourceID", "")) == wanted
    ]
    if len(references) != 1:
        return None, f"Expected exactly one matching example reference, found {len(references)}"
    parent["sourceKey"] = source_key
    parent["sourceKind"] = "example"
    return parent, None


def build_plan(
    database: pathlib.Path, contents_directory: pathlib.Path
) -> dict[str, Any]:
    connection = _read_only_connection(database)
    try:
        rows = connection.execute(
            """
            SELECT * FROM entries
            WHERE archive_version IS NULL AND type='example'
            ORDER BY id
            """
        ).fetchall()
        xml_roots: dict[str, Any] = {}
        repairs: list[dict[str, Any]] = []
        unchanged: list[dict[str, str]] = []
        unresolved: list[dict[str, str]] = []
        for entry in rows:
            source_key = _dictionary_source_key(entry) or ""
            parent, reason = _verified_parent(entry, contents_directory, xml_roots)
            if parent is None:
                unresolved.append(
                    {
                        "entryID": entry["id"],
                        "title": entry["title"],
                        "sourceKey": source_key,
                        "reason": reason or "No verified parent context",
                    }
                )
                continue
            structured = parent["structured"]
            values = {
                "dictionary_text": parent["searchText"],
                "dictionary_raw_xml": parent["rawXML"],
                "dictionary_structured": json.dumps(
                    structured, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                ),
                "dictionary_search_text": parent["searchText"],
                "dictionary_content_hash": parent["contentHash"],
                "dictionary_parser_version": parent["parserVersion"],
                "dictionary_parse_status": structured["parseStatus"],
                "dictionary_parse_error": None,
            }
            if all(entry[field] == value for field, value in values.items()):
                unchanged.append(
                    {"entryID": entry["id"], "title": entry["title"], "sourceKey": source_key}
                )
                continue
            repairs.append(
                {
                    "entryID": entry["id"],
                    "title": entry["title"],
                    "sourceKey": source_key,
                    "before": {field: entry[field] for field in DICTIONARY_FIELDS},
                    "after": values,
                    "contentHash": parent["contentHash"],
                }
            )
        return {
            "database": str(database.resolve()),
            "contentsDirectory": str(contents_directory.resolve()),
            "examplesExamined": len(rows),
            "plannedRepairs": repairs,
            "unchanged": unchanged,
            "unresolved": unresolved,
            "applied": False,
        }
    finally:
        connection.close()


def repair_database(
    database: pathlib.Path,
    contents_directory: pathlib.Path,
    *,
    apply: bool = False,
    backup_path: pathlib.Path | None = None,
) -> dict[str, Any]:
    plan = build_plan(database, contents_directory)
    report = {
        "database": plan["database"],
        "contentsDirectory": plan["contentsDirectory"],
        "examplesExamined": plan["examplesExamined"],
        "plannedRepairs": len(plan["plannedRepairs"]),
        "unchanged": len(plan["unchanged"]),
        "unresolved": plan["unresolved"],
        "repairs": [
            {key: item[key] for key in ("entryID", "title", "sourceKey", "contentHash")}
            for item in plan["plannedRepairs"]
        ],
        "applied": False,
    }
    if not apply:
        return report
    if backup_path is None:
        raise ValueError("A backup path is required when applying repairs")
    if backup_path.resolve() == database.resolve():
        raise ValueError("Backup path must differ from the database")
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    _backup(database, backup_path)
    report["backup"] = str(backup_path.resolve())

    connection = sqlite3.connect(database, timeout=60)
    try:
        connection.execute("BEGIN IMMEDIATE")
        for item in plan["plannedRepairs"]:
            assignments = ", ".join(f"{field}=?" for field in DICTIONARY_FIELDS)
            guards = " AND ".join(f"{field} IS ?" for field in DICTIONARY_FIELDS)
            cursor = connection.execute(
                f"""
                UPDATE entries SET {assignments},updated_at=?
                WHERE id=? AND {guards}
                """,
                [
                    *[item["after"][field] for field in DICTIONARY_FIELDS],
                    time.time(),
                    item["entryID"],
                    *[item["before"][field] for field in DICTIONARY_FIELDS],
                ],
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"Entry changed during repair: {item['entryID']}")
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    verification = build_plan(database, contents_directory)
    unresolved_by_id = {item["entryID"] for item in verification["unresolved"]}
    remaining_by_id = {item["entryID"] for item in verification["plannedRepairs"]}
    expected_unresolved = {item["entryID"] for item in plan["unresolved"]}
    if remaining_by_id or unresolved_by_id != expected_unresolved:
        raise RuntimeError(
            f"Verification failed: repairs remaining={len(remaining_by_id)}, "
            f"unresolved changed={unresolved_by_id != expected_unresolved}"
        )
    report["applied"] = True
    report["verifiedRemainingRepairs"] = len(remaining_by_id)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=pathlib.Path, required=True)
    parser.add_argument("--contents", type=pathlib.Path, required=True)
    parser.add_argument("--apply", action="store_true", help="write verified parent dictionary context")
    parser.add_argument("--backup", type=pathlib.Path, help="required SQLite Backup API output for --apply")
    parser.add_argument("--report", type=pathlib.Path)
    args = parser.parse_args()
    try:
        report = repair_database(
            args.database, args.contents, apply=args.apply, backup_path=args.backup
        )
        output = json.dumps(report, ensure_ascii=False, indent=2)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(output + "\n", encoding="utf-8")
        print(output)
        return 0
    except Exception as error:
        print(f"example repair failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
