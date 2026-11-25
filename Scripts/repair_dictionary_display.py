#!/usr/bin/env python3
"""Audit and safely normalize display-only Monokakido markers in a Lexi database."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sqlite3
import sys
from typing import Any


DISPLAY_MARKERS = {
    "{hyoki-s}": "・",
    "{ZS:/}": "／",
}


def visible_text(value: str | None) -> str | None:
    if value is None:
        return None
    for marker, replacement in DISPLAY_MARKERS.items():
        value = value.replace(marker, replacement)
    return value


def _backup(source_path: pathlib.Path, backup_path: pathlib.Path) -> None:
    source = sqlite3.connect(
        f"{source_path.resolve().as_uri()}?mode=ro", uri=True, timeout=60
    )
    destination = sqlite3.connect(backup_path, timeout=60)
    try:
        source.backup(destination, pages=256, sleep=0.05)
        destination.commit()
        destination.execute("PRAGMA journal_mode=DELETE")
        integrity = destination.execute("PRAGMA integrity_check").fetchone()[0]
        foreign_keys = destination.execute("PRAGMA foreign_key_check").fetchall()
        if integrity != "ok" or foreign_keys:
            raise RuntimeError(
                f"Backup validation failed: integrity={integrity}, foreign_keys={len(foreign_keys)}"
            )
    finally:
        destination.close()
        source.close()


def inspect_database(database: pathlib.Path) -> dict[str, Any]:
    connection = sqlite3.connect(
        f"{database.resolve().as_uri()}?mode=ro", uri=True, timeout=60
    )
    connection.row_factory = sqlite3.Row
    try:
        columns = {
            row["name"] for row in connection.execute("PRAGMA table_info(entries)")
        }
        required = {"id", "title", "full_title"}
        if not required.issubset(columns):
            raise RuntimeError(f"entries is missing required columns: {sorted(required - columns)}")
        rows = connection.execute(
            "SELECT id,title,full_title FROM entries ORDER BY id"
        ).fetchall()
        updates = []
        field_counts = {"title": 0, "full_title": 0}
        marker_counts = {marker: 0 for marker in DISPLAY_MARKERS}
        for row in rows:
            title = row["title"] or ""
            full_title = row["full_title"] or ""
            clean_title = visible_text(title)
            clean_full_title = visible_text(full_title)
            if clean_title != title or clean_full_title != full_title:
                field_counts["title"] += clean_title != title
                field_counts["full_title"] += clean_full_title != full_title
                for marker in marker_counts:
                    marker_counts[marker] += title.count(marker) + full_title.count(marker)
                updates.append(
                    {
                        "id": row["id"],
                        "before_title": title,
                        "after_title": clean_title,
                        "before_full_title": full_title,
                        "after_full_title": clean_full_title,
                    }
                )
        return {
            "database": str(database.resolve()),
            "entries": len(rows),
            "affected_entries": len(updates),
            "affected_fields": field_counts,
            "marker_occurrences": marker_counts,
            "updates": updates,
        }
    finally:
        connection.close()


def repair_database(
    database: pathlib.Path,
    *,
    apply: bool = False,
    backup_path: pathlib.Path | None = None,
) -> dict[str, Any]:
    report = inspect_database(database)
    report["applied"] = False
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
        for item in report["updates"]:
            cursor = connection.execute(
                """
                UPDATE entries SET title=?,full_title=?
                WHERE id=? AND title=? AND full_title=?
                """,
                (
                    item["after_title"],
                    item["after_full_title"],
                    item["id"],
                    item["before_title"],
                    item["before_full_title"],
                ),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"Entry changed during repair: {item['id']}")
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    verification = inspect_database(database)
    if verification["affected_entries"]:
        raise RuntimeError(
            f"Display marker verification failed for {verification['affected_entries']} entries"
        )
    report["applied"] = True
    report["verified_remaining_affected_entries"] = verification["affected_entries"]
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=pathlib.Path, required=True)
    parser.add_argument("--apply", action="store_true", help="write the display-only corrections")
    parser.add_argument("--backup", type=pathlib.Path, help="required SQLite Backup API output for --apply")
    parser.add_argument("--report", type=pathlib.Path)
    args = parser.parse_args()
    try:
        report = repair_database(args.database, apply=args.apply, backup_path=args.backup)
        output = json.dumps(report, ensure_ascii=False, indent=2)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(output + "\n", encoding="utf-8")
        print(output)
        return 0
    except Exception as error:
        print(f"display repair failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
