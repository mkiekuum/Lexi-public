#!/usr/bin/env python3
"""Read-only, exact-Source-ID coverage audit for the local Lexi dictionary."""
from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import sqlite3
import sys
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


def load_parser(path: Path) -> Any:
    spec = importlib.util.spec_from_file_location("daijisen_parser", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"辞典解析器を読み込めません: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def normalized_key(value: str) -> str | None:
    parts = value.split("-")
    if len(parts) != 2 or not parts[0].isdigit() or len(parts[1]) != 4:
        return None
    try:
        int(parts[0])
    except ValueError:
        return None
    if not all(char in "0123456789abcdefABCDEF" for char in parts[1]):
        return None
    return f"{int(parts[0])}-{parts[1].upper()}"


def normalized_title(value: str) -> str:
    canonical = unicodedata.normalize("NFKC", value).casefold()
    return "".join(
        character for character in canonical
        if not character.isspace()
        and not unicodedata.category(character).startswith(("P", "Z"))
    )


def source_id_key(value: str) -> str | None:
    parts = value.split("-")
    if len(parts) != 3:
        return None
    return normalized_key(f"{parts[0]}-{parts[1]}")


def audit(database: Path, contents: Path, parser_path: Path) -> dict[str, Any]:
    parser = load_parser(parser_path)
    connection = sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        all_rows = connection.execute(
            """SELECT id, title, type, source_id, source_entry_id, source_subentry_id,
                      dictionary_text, dictionary_structured, dictionary_parse_status,
                      archive_version
               FROM entries ORDER BY title, id"""
        ).fetchall()
    finally:
        connection.close()

    pending = [
        row for row in all_rows
        if not (row["dictionary_structured"] or "").strip()
    ]
    grouped: dict[str, list[sqlite3.Row]] = collections.defaultdict(list)
    for row in pending:
        if row["source_entry_id"]:
            grouped[row["source_entry_id"]].append(row)

    item_results: list[dict[str, Any]] = []
    roots: dict[str, ET.Element | Exception] = {}
    for entry_id, rows in grouped.items():
        xml_path = contents / f"{entry_id}.xml"
        if not xml_path.is_file():
            roots[entry_id] = FileNotFoundError(xml_path.name)
            continue
        try:
            roots[entry_id] = ET.parse(xml_path).getroot()
        except (ET.ParseError, OSError) as error:
            roots[entry_id] = error

    for row in pending:
        entry_id = row["source_entry_id"]
        subentry_id = row["source_subentry_id"]
        expected_key = f"{entry_id}-{subentry_id}" if entry_id and subentry_id else ""
        xml_path = contents / f"{entry_id}.xml" if entry_id else None
        result: dict[str, Any] = {
            "id": row["id"],
            "title": row["title"],
            "type": row["type"],
            "source_id": row["source_id"],
            "source_key": expected_key,
            "has_existing_text": bool((row["dictionary_text"] or "").strip()),
            "parse_status": row["dictionary_parse_status"],
            "historical_archive": row["archive_version"] is not None,
            "xml_available": bool(xml_path and xml_path.is_file()),
            "source_id_matches_columns": (
                normalized_key(expected_key) is not None
                and source_id_key(row["source_id"] or "") == normalized_key(expected_key)
            ),
        }
        if not expected_key:
            result["audit_result"] = "source_id_missing_or_incomplete"
            item_results.append(result)
            continue
        root = roots.get(entry_id)
        if isinstance(root, FileNotFoundError) or root is None:
            result["audit_result"] = "xml_resource_missing"
        elif isinstance(root, Exception):
            result["audit_result"] = f"xml_parse_failed:{type(root).__name__}"
        elif row["type"] == "example":
            parent = parser.extract_entry_from_root(root, f"{entry_id}-0000")
            if parent.get("sourceKind") != "headword":
                result["audit_result"] = f"parent_{parent.get('parseStatus', 'not_found')}"
            else:
                target_key = normalized_key(expected_key)
                matches = [
                    segment
                    for section in parent.get("structured", {}).get("sections", [])
                    for segment in section.get("segments", [])
                    if normalized_key(segment.get("sourceID", "")) == target_key
                ]
                result["audit_result"] = (
                    "exact_example_reference" if len(matches) == 1
                    else f"example_reference_count:{len(matches)}"
                )
                result["matching_source_references"] = len(matches)
        else:
            parsed = parser.extract_entry_from_root(root, expected_key)
            status = parsed.get("parseStatus", "unknown")
            kind = parsed.get("sourceKind")
            result["parser_kind"] = kind
            result["parser_status"] = status
            structured = parsed.get("structured")
            if structured is None:
                result["audit_result"] = status
            elif structured.get("sourceEntryID") != entry_id:
                result["audit_result"] = "source_entry_id_mismatch"
            elif kind != row["type"]:
                result["audit_result"] = f"type_mismatch:{kind or status}"
            elif structured.get("plainText", "").strip():
                if row["type"] == "headword":
                    title = normalized_title(row["title"] or "")
                    candidates = [
                        *(structured.get("heading") or []),
                        structured.get("reading") or "",
                        *(structured.get("writtenForms") or []),
                    ]
                    title_matches = any(normalized_title(candidate) == title for candidate in candidates)
                    result["title_matches_source"] = title_matches
                    result["dictionary_heading"] = "".join(structured.get("heading") or [])
                    result["audit_result"] = (
                        "exact_source_available"
                        if title_matches else "exact_source_title_mismatch"
                    )
                else:
                    result["audit_result"] = "exact_source_available"
            else:
                result["audit_result"] = status
        item_results.append(result)

    result_counts = collections.Counter(item["audit_result"] for item in item_results)
    return {
        "format": "lexi-local-dictionary-coverage-audit",
        "version": 1,
        "read_only": True,
        "database": str(database),
        "dictionary_contents": str(contents),
        "entries_total": len(all_rows),
        "entries_with_structured_dictionary": len(all_rows) - len(pending),
        "entries_without_structured_dictionary": len(pending),
        "active_entries_total": sum(row["archive_version"] is None for row in all_rows),
        "active_entries_without_structured_dictionary": sum(
            row["archive_version"] is None and not (row["dictionary_structured"] or "").strip()
            for row in all_rows
        ),
        "historical_entries_total": sum(row["archive_version"] is not None for row in all_rows),
        "historical_entries_without_structured_dictionary": sum(
            row["archive_version"] is not None and not (row["dictionary_structured"] or "").strip()
            for row in all_rows
        ),
        "entries_without_structured_but_with_existing_text": sum(
            item["has_existing_text"] for item in item_results
        ),
        "entries_without_structured_and_without_text": sum(
            not item["has_existing_text"] for item in item_results
        ),
        "result_counts": dict(sorted(result_counts.items())),
        "items": item_results,
    }


def main() -> int:
    argument_parser = argparse.ArgumentParser(
        description="Lexiデータベースを変更せず、ローカル辞典をSource IDで照合します"
    )
    argument_parser.add_argument("--db", type=Path, required=True)
    managed_contents = Path.home() / "Desktop/Lexi/Dictionary/DAIJISEN.J/Contents"
    legacy_contents = Path.home() / "Desktop/LexiData/Dictionary/DAIJISEN.J/Contents"
    argument_parser.add_argument(
        "--contents",
        type=Path,
        default=managed_contents if managed_contents.exists() else legacy_contents,
    )
    argument_parser.add_argument("--parser", type=Path, default=Path(__file__).with_name("daijisen_parser.py"))
    argument_parser.add_argument("--out", type=Path)
    args = argument_parser.parse_args()
    report = audit(args.db, args.contents, args.parser)
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
