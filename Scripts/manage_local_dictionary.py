#!/usr/bin/env python3
"""Verify and safely replace Lexi's local dictionary resource directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
from datetime import datetime, timezone

MANIFEST_NAME = "manifest.json"
INDEX_NAMES = {
    "headline.headlinestore.tsv",
    "short-headline.headlinestore.tsv",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def resource_files(root: Path, parser_override: Path | None = None) -> tuple[list[Path], Path]:
    dictionary = root / "DAIJISEN.J"
    contents = dictionary / "Contents"
    headlines = dictionary / "Headline"
    parser = root / "daijisen_parser.py"
    if not parser.is_file() and parser_override is not None:
        parser = parser_override
    if not contents.is_dir() or not headlines.is_dir() or not parser.is_file():
        raise ValueError("DAIJISEN.J/Contents、Headline、daijisen_parser.py が必要です")

    for path in (root, dictionary, contents, headlines):
        if path.is_symlink():
            raise ValueError(f"シンボリックリンクは受け付けません: {path}")
    if parser.is_symlink():
        raise ValueError(f"シンボリックリンクは受け付けません: {parser}")
    files = sorted(
        [path for path in contents.iterdir() if path.suffix.lower() == ".xml"]
        + [path for path in headlines.iterdir() if path.suffix.lower() == ".tsv"]
        + [parser]
    )
    if not files or not any(path.parent == contents for path in files):
        raise ValueError("辞典XMLがありません")
    if {path.name for path in files if path.parent == headlines} != INDEX_NAMES:
        raise ValueError("必要な見出し索引2件が揃っていません")
    if any(path.is_symlink() or not path.is_file() for path in files):
        raise ValueError("辞典リソースに通常ファイル以外が含まれています")
    return files, parser


def build_manifest(
    root: Path,
    source_version: str,
    parser_override: Path | None = None,
) -> tuple[dict, dict[str, str]]:
    root = root.resolve()
    files, parser_path = resource_files(root, parser_override)
    inventory: dict[str, str] = {}
    content_digest = hashlib.sha256()
    xml_count = 0
    total_bytes = 0
    index_hashes: dict[str, str] = {}
    for path in files:
        try:
            relative = path.relative_to(root).as_posix()
        except ValueError:
            relative = "daijisen_parser.py"
        file_hash = sha256(path)
        size = path.stat().st_size
        inventory[relative] = file_hash
        content_digest.update(f"{relative}\0{size}\0{file_hash}\n".encode("utf-8"))
        total_bytes += size
        if path.suffix.lower() == ".xml":
            xml_count += 1
        elif path.suffix.lower() == ".tsv":
            index_hashes[relative] = file_hash

    parser_source = parser_path.read_text(encoding="utf-8")
    parser_version_match = re.search(r'^PARSER_VERSION\s*=\s*"([^"]+)"', parser_source, re.MULTILINE)
    manifest = {
        "formatVersion": 1,
        "dictionaryName": "デジタル大辞泉",
        "sourceVersion": source_version or "not-provided",
        "sourceVersionNote": "元のローカル書き出しに版番号がなかった場合は not-provided とする",
        "parserVersion": parser_version_match.group(1) if parser_version_match else "unknown",
        "xmlFileCount": xml_count,
        "indexFiles": index_hashes,
        "parserSHA256": inventory["daijisen_parser.py"],
        "resourceFileCount": len(files),
        "resourceBytes": total_bytes,
        "contentSetSHA256": content_digest.hexdigest(),
    }
    return manifest, inventory


def load_manifest(root: Path) -> dict:
    path = root / MANIFEST_NAME
    if not path.is_file():
        raise ValueError(f"マニフェストがありません: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def create_manifest(root: Path, source_version: str) -> dict:
    manifest, _ = build_manifest(root, source_version)
    target = root / MANIFEST_NAME
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, target)
    return manifest


def compare_roots(current: Path, candidate: Path, source_version: str) -> dict:
    current_manifest, current_files = build_manifest(current, "current")
    candidate_parser = candidate / "daijisen_parser.py"
    if not candidate_parser.is_file():
        candidate_parser = current / "daijisen_parser.py"
    candidate_manifest, candidate_files = build_manifest(
        candidate, source_version, parser_override=candidate_parser
    )
    current_names = set(current_files)
    candidate_names = set(candidate_files)
    added = sorted(candidate_names - current_names)
    removed = sorted(current_names - candidate_names)
    changed = sorted(
        name for name in current_names & candidate_names
        if current_files[name] != candidate_files[name]
    )
    return {
        "current": current_manifest,
        "candidate": candidate_manifest,
        "addedCount": len(added),
        "removedCount": len(removed),
        "changedCount": len(changed),
        "addedSample": added[:20],
        "removedSample": removed[:20],
        "changedSample": changed[:20],
    }


def safe_install(current: Path, candidate: Path, source_version: str) -> Path:
    current = current.resolve()
    candidate = candidate.resolve()
    if current == candidate or current in candidate.parents or candidate in current.parents:
        raise ValueError("現行辞典と更新候補は別の場所に置いてください")
    parent = current.parent
    parent.mkdir(parents=True, exist_ok=True)
    backup_root = parent / "Backups"
    backup_root.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    backup = backup_root / f"Dictionary-before-update-{timestamp}"
    if backup.exists():
        raise FileExistsError(f"バックアップ先がすでに存在します: {backup}")

    stage = Path(tempfile.mkdtemp(prefix=".Dictionary-stage-", dir=parent))
    stage.rmdir()
    moved_current = False
    try:
        shutil.copytree(candidate / "DAIJISEN.J", stage / "DAIJISEN.J", copy_function=shutil.copy2)
        candidate_parser = candidate / "daijisen_parser.py"
        current_parser = current / "daijisen_parser.py"
        parser_source = candidate_parser if candidate_parser.is_file() else current_parser
        if not parser_source.is_file():
            raise ValueError("更新候補または現行辞典に解析ツールがありません")
        shutil.copy2(parser_source, stage / "daijisen_parser.py")
        manifest, _ = build_manifest(stage, source_version)
        (stage / MANIFEST_NAME).write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(current, backup)
        moved_current = True
        try:
            os.replace(stage, current)
        except Exception:
            os.replace(backup, current)
            moved_current = False
            raise
        return backup
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        if moved_current and not current.exists():
            os.replace(backup, current)


def main() -> int:
    parser = argparse.ArgumentParser(description="Lexiの独立辞典を検証・比較・安全に更新します")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for command in ("create", "verify"):
        sub = subparsers.add_parser(command)
        sub.add_argument("--root", type=Path, required=True)
        sub.add_argument("--source-version", default="not-provided")

    compare = subparsers.add_parser("compare")
    compare.add_argument("--current", type=Path, required=True)
    compare.add_argument("--candidate", type=Path, required=True)
    compare.add_argument("--source-version", default="not-provided")

    install = subparsers.add_parser("install")
    install.add_argument("--current", type=Path, required=True)
    install.add_argument("--candidate", type=Path, required=True)
    install.add_argument("--source-version", default="not-provided")

    args = parser.parse_args()
    try:
        if args.command == "create":
            result = create_manifest(args.root, args.source_version)
        elif args.command == "verify":
            actual, _ = build_manifest(args.root, load_manifest(args.root).get("sourceVersion", "not-provided"))
            stored = load_manifest(args.root)
            if actual != stored:
                raise ValueError("マニフェストと辞典ファイルの内容が一致しません")
            result = {"verified": True, **stored}
        elif args.command == "compare":
            result = compare_roots(args.current, args.candidate, args.source_version)
        else:
            comparison = compare_roots(args.current, args.candidate, args.source_version)
            backup = safe_install(args.current, args.candidate, args.source_version)
            result = {
                "backup": str(backup),
                "addedCount": comparison["addedCount"],
                "removedCount": comparison["removedCount"],
                "changedCount": comparison["changedCount"],
                "installedManifest": load_manifest(args.current),
            }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"エラー: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
