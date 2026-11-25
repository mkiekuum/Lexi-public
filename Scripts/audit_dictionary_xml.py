#!/usr/bin/env python3
"""Read-only aggregate inventory of tags and attributes in a local XML export."""
from __future__ import annotations

import argparse
import collections
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import daijisen_parser


def local_name(value: str) -> str:
    return value.rsplit("}", 1)[-1]


def audit(root: Path) -> dict[str, object]:
    if not root.is_dir():
        raise FileNotFoundError(f"XML directory not found: {root}")

    tags: collections.Counter[str] = collections.Counter()
    attributes: collections.Counter[str] = collections.Counter()
    entry_tags: collections.Counter[str] = collections.Counter()
    parent_child: collections.Counter[str] = collections.Counter()
    files = sorted(root.rglob("*.xml"))
    failures: list[str] = []
    for path in files:
        try:
            stack: list[str] = []
            in_entry_content = False
            for event, element in ET.iterparse(path, events=("start", "end")):
                if event == "start":
                    name = local_name(element.tag)
                    tags[name] += 1
                    attributes.update(local_name(attribute_name) for attribute_name in element.attrib)
                    if name == "entry-index":
                        in_entry_content = True
                    if stack and in_entry_content:
                        parent_child[f"{stack[-1]} > {name}"] += 1
                    if in_entry_content:
                        entry_tags[name] += 1
                    stack.append(name)
                else:
                    name = local_name(element.tag)
                    element.clear()
                    stack.pop()
                    if name == "Contents":
                        in_entry_content = False
        except (ET.ParseError, OSError) as error:
            failures.append(f"{path.name}: {type(error).__name__}")

    known = daijisen_parser.KNOWN_TAGS
    unknown = {name: count for name, count in tags.items() if name not in known}
    unknown_entry = {name: count for name, count in entry_tags.items() if name not in known}
    total_nodes = sum(entry_tags.values())
    known_nodes = total_nodes - sum(unknown_entry.values())
    return {
        "format": "lexi-dictionary-xml-audit",
        "version": 1,
        "rootName": root.name,
        "xmlFiles": len(files),
        "failedFiles": failures,
        "entryIndexNodes": total_nodes,
        "knownTagNodesInEntries": known_nodes,
        "knownTagNodeRatioInEntries": known_nodes / total_nodes if total_nodes else 1.0,
        "tags": dict(sorted(tags.items())),
        "tagsInEntries": dict(sorted(entry_tags.items())),
        "parentChildPairsInEntries": dict(sorted(parent_child.items())),
        "attributes": dict(sorted(attributes.items())),
        "unknownTags": dict(sorted(unknown.items())),
        "unknownTagsInEntries": dict(sorted(unknown_entry.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="辞典XMLのタグ・属性を読み取り専用で集計します")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    arguments = parser.parse_args()
    report = audit(arguments.root)
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if arguments.out:
        arguments.out.parent.mkdir(parents=True, exist_ok=True)
        arguments.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0 if not report["failedFiles"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
