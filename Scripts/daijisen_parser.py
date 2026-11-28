#!/usr/bin/env python3
"""Conservative structured extraction for local DAIJISEN2 HTML/XML exports."""
from __future__ import annotations

import hashlib
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit
from pathlib import Path
from typing import Any

PARSER_VERSION = "8"
LINK_TARGET = re.compile(r"^[0-9]{1,6}(?:-[0-9A-Fa-f]{4})?$")
def valid_link_target(value: str) -> bool:
    if LINK_TARGET.fullmatch(value):
        return True
    if re.fullmatch(r"map:ll=-?[0-9]+(?:\.[0-9]+)?,-?[0-9]+(?:\.[0-9]+)?(?:&z=[0-9]+)?", value):
        return True
    if any(c.isspace() or ord(c) < 32 for c in value):
        return False
    try:
        url = urlsplit(value)
        return url.scheme.lower() in {"http", "https"} and bool(url.hostname) and not url.username and not url.password
    except ValueError:
        return False

DISPLAY_MARKERS = {
    "{hyoki-s}": "・",
    "{ZS:/}": "／",
}
KNOWN_TAGS = {
    "Contents", "entry-index", "見出G", "headword", "MAccentAudioG",
    "補足ロゴG", "補足ロゴ", "MAccentM", "解説G", "MG", "meaning",
    "rect", "hinshi", "HinshiSahen", "ExG", "SubItem", "SubItemH",
    "SubItemC", "wari", "a", "span", "Hhyphen", "HyokiS", "Hdot",
    "常外音訓M", "script", "Header", "HeaderTitle", "ruby", "rb", "rt",
    "strong", "em", "sup", "sub", "br", "p", "div", "ul", "li",
    "用例", "explanation", "img",
    "bold", "italic", "u", "Small", "MAccentSlash", "K-h", "K-v",
    "ExS", "SubMeaning", "MCaption", "MImage", "MImageG",
    "MLocation", "MLocationG", "MUrl", "MUrlG", "MUrlTitle", "MUrlUrl",
    "MeanT", "MeanTR", "MeanTD", "付表有M", "付表無M", "季語", "季語M",
    "季語ロゴS", "季語ロゴ中", "季語ロゴ前", "季語ロゴ後", "常外M",
    "歌枕M", "歴史", "lang",
    "BlackDiamond", "CampaignDesc", "CampaignEx", "CampaignExG", "CampaignName",
    "Gaiji", "L4", "Wdot", "WhiteDiamond", "circle",
    "body", "head", "html", "link", "meta",
}
STYLE_TAGS = {
    "bold": "strong",
    "strong": "strong",
    "italic": "emphasis",
    "em": "emphasis",
    "u": "underline",
    "Small": "small",
    "small": "small",
    "sup": "superscript",
    "sub": "subscript",
}
BLOCK_TAGS = {"p", "div", "ul", "li", "SubMeaning", "MeanTR", "MUrl", "MUrlTitle", "MUrlUrl", "MLocation", "MCaption"}


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def canonical_source_key(value: str) -> tuple[str, str] | None:
    parts = value.upper().split("-")
    if len(parts) != 2 or not parts[0].isdigit():
        return None
    return str(int(parts[0])), parts[1]


def visible_text(value: str) -> str:
    for marker, visible in DISPLAY_MARKERS.items():
        value = value.replace(marker, visible)
    return value


def clean_text(value: str) -> str:
    value = visible_text(value)
    return re.sub(r"\s+", " ", value).strip()


def _find_contents(root: ET.Element) -> ET.Element | None:
    return next((node for node in root.iter() if local_name(node.tag) == "Contents"), None)


def _exact_child(contents: ET.Element, key: str) -> tuple[ET.Element | None, str]:
    parts = key.split("-", 1)
    if len(parts) != 2:
        return None, "invalid_source_id"
    suffix = parts[1].upper()
    if suffix.startswith("0000"):
        return contents, "headword"
    if suffix.startswith("4"):
        expected_tag, kind = "SubItem", "idiom"
    elif suffix.startswith("5"):
        expected_tag, kind = "ExG", "example"
    else:
        return None, "unsupported_source_id"
    expected = canonical_source_key(f"{parts[0]}-{suffix}")
    matches = [
        node for node in contents.iter()
        if local_name(node.tag) == expected_tag
        and canonical_source_key(node.attrib.get("id", "")) == expected
    ]
    if len(matches) == 1:
        return matches[0], kind
    if len(matches) > 1:
        return None, "nested_entry_ambiguous"
    return None, "nested_entry_missing"


def _tokens(node: ET.Element, diagnostics: set[str]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []

    def append_segment(kind: str, text: str, styles: tuple[str, ...], **extra: str) -> None:
        segment: dict[str, Any] = {"kind": kind, "text": visible_text(text)}
        if styles:
            segment["styles"] = list(dict.fromkeys(styles))
        segment.update(extra)
        result.append(segment)

    def add_text(value: str | None, styles: tuple[str, ...], target: str | None) -> None:
        if value and value.strip():
            text = re.sub(r"\s+", " ", visible_text(value))
            append_segment("link" if target else "text", text, styles, **({"target": target} if target else {}))

    def add_break() -> None:
        if result and result[-1].get("kind") != "break":
            result.append({"kind": "break", "text": "\n"})

    def walk(
        current: ET.Element,
        styles: tuple[str, ...] = (),
        link_target: str | None = None,
    ) -> None:
        tag = local_name(current.tag)
        if tag not in KNOWN_TAGS:
            diagnostics.add(tag)
        style = STYLE_TAGS.get(tag)
        if style:
            styles = (*styles, style)
        if tag in BLOCK_TAGS:
            add_break()
        if tag == "br":
            add_break()
            return
        if tag == "wari":
            reading = clean_text("".join(current.itertext()))
            if reading:
                previous = result[-1] if result else None
                previous_text = previous.get("text", "") if previous else ""
                if previous and previous.get("kind") in {"text", "link"} and previous_text and previous_text[-1].isalpha():
                    # The source's wari annotates the preceding contiguous kanji group,
                    # not merely its final character (e.g. 薄氷/はくひょう).
                    group = re.search(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff々〆〇]+$", previous_text)
                    base = group.group() if group else previous_text[-1]
                    target = previous.get("target")
                    previous_styles = tuple(previous.get("styles", ()))
                    remaining = previous_text[:-len(base)]
                    if remaining:
                        previous["text"] = remaining
                    else:
                        result.pop()
                    ruby = {"kind": "ruby", "text": base, "reading": reading}
                    if previous_styles or styles:
                        ruby["styles"] = list(dict.fromkeys((*previous_styles, *styles)))
                    if target:
                        ruby["target"] = target
                    result.append(ruby)
                else:
                    append_segment("reading", reading, styles)
            return
        if tag in {"hinshi", "HinshiSahen"}:
            value = clean_text("".join(current.itertext()))
            if value:
                append_segment("grammar", value, styles)
            return
        if tag == "ruby":
            bases = []
            readings = []
            if current.text:
                bases.append(current.text)
            for child in current:
                if local_name(child.tag) == "rt":
                    readings.append("".join(child.itertext()))
                else:
                    bases.append("".join(child.itertext()))
                if child.tail:
                    bases.append(child.tail)
            base, reading = clean_text("".join(bases)), clean_text("".join(readings))
            if base and reading:
                append_segment("ruby", base, styles, reading=reading, **({"target": link_target} if link_target else {}))
            elif base:
                add_text(base, styles, link_target)
            return
        if tag == "MAccentM":
            value = clean_text("".join(current.itertext()))
            if value:
                append_segment("accent", value, styles)
            return
        if tag == "HyokiS":
            append_segment("text", "・", styles)
            return
        if tag == "常外音訓M":
            value = clean_text("".join(current.itertext()))
            if value:
                append_segment("annotation", value, styles)
            return
        if tag == "ExG":
            source_id = current.attrib.get("id", "")
            start = len(result)
            add_text(current.text, styles, link_target)
            for child in current:
                child_tag = local_name(child.tag)
                if child_tag == "a":
                    href = child.attrib.get("href", "")
                    target = href if href and valid_link_target(href) else link_target
                    walk(child, styles, target)
                else:
                    walk(child, styles, link_target)
                add_text(child.tail, styles, link_target)
            if start == len(result):
                value = re.sub(r"\s+", " ", visible_text("".join(current.itertext()))).strip()
                if value:
                    append_segment("example", value, styles, sourceID=source_id)
            for segment in result[start:]:
                if segment.get("kind") == "text":
                    segment["kind"] = "example"
                if source_id:
                    segment["sourceID"] = source_id
            return
        if tag == "img":
            alt = current.attrib.get("alt", "").strip()
            if alt:
                append_segment("image", alt, styles, target=current.attrib.get("src", ""))
            return
        if tag == "MeanTD" and result and result[-1].get("kind") != "break":
            append_segment("text", "　", styles)
        add_text(current.text, styles, link_target)
        for child in current:
            child_tag = local_name(child.tag)
            if child_tag == "a":
                href = child.attrib.get("href", "")
                internal_target = href if href and valid_link_target(href) else None
                walk(child, styles, internal_target or link_target)
            else:
                walk(child, styles, link_target)
            add_text(child.tail, styles, link_target)
        if tag in BLOCK_TAGS:
            add_break()

    walk(node)
    return result


def _plain(segments: list[dict[str, Any]]) -> str:
    value = "".join(
        "\n" if segment.get("kind") == "break" else
        segment.get("text", "") + (segment.get("reading", "") if segment.get("kind") == "ruby" else "")
        for segment in segments
    )
    return "\n".join(clean_text(line) for line in value.splitlines()).strip()


def _base_text(segments: list[dict[str, Any]]) -> str:
    return clean_text("".join(
        segment.get("text", "") for segment in segments
        if segment.get("kind") != "annotation"
    ))


SECTION_LABELS = {
    "類語": "related", "関連語": "related", "同義語": "related",
    "反対語": "related", "対義語": "related", "下接語": "related",
    "下接句": "related", "語源": "etymology", "由来": "etymology",
    "補説": "note", "注記": "note", "用法": "usage", "品詞": "metadata",
    "派生": "derivation", "可能": "potential", "URL": "url",
    "地図": "location", "アクセント": "metadata",
}


def _section_kind(text: str, class_name: str, node: ET.Element) -> tuple[str, str]:
    # Supplement labels are explicit markup. Preserve even newly encountered labels.
    source_label = next((clean_text("".join(child.itertext())) for child in node.iter()
                         if local_name(child.tag) == "補足ロゴ"), "")
    if source_label and clean_text(text).startswith(source_label):
        return SECTION_LABELS.get(source_label, "supplement"), source_label
    compact = clean_text(text)
    for label, kind in SECTION_LABELS.items():
        if compact.startswith(label):
            return kind, label
    if class_name == "C":
        return "supplement", "補足"
    return "meaning", ""


def _build_document(selected: ET.Element, key: str, kind: str) -> dict[str, Any]:
    diagnostics: set[str] = set()
    heading: list[str] = []
    heading_segments: list[dict[str, Any]] = []
    reading = ""
    written_forms: list[str] = []
    accent = ""
    sections: list[dict[str, Any]] = []

    if kind == "headword":
        heading_root = next(
            (node for node in selected if local_name(node.tag) == "見出G"),
            None,
        )
    elif kind == "idiom":
        heading_root = next(
            (node for node in selected if local_name(node.tag) == "SubItemH"),
            None,
        )
    else:
        heading_root = None

    for node in heading_root.iter() if heading_root is not None else ():
        tag = local_name(node.tag)
        if tag not in KNOWN_TAGS:
            diagnostics.add(tag)
        if tag == "headword":
            segments = _tokens(node, diagnostics)
            value = _base_text(segments)
            if value:
                heading_style = {
                    "見出": "heading-reading",
                    "表記": "heading-written",
                    "原綴": "heading-written",
                }.get(node.attrib.get("class", ""))
                if heading_style:
                    for segment in segments:
                        segment["styles"] = list(dict.fromkeys(
                            [*segment.get("styles", []), heading_style]
                        ))
                heading.append(value)
                heading_segments.extend(segments)
                if node.attrib.get("class") == "見出":
                    reading = value
                elif node.attrib.get("class") in {"表記", "原綴"}:
                    written_forms.append(value)
        elif tag == "MAccentAudioG" and not accent:
            accent_segments = _tokens(node, diagnostics)
            accent = _plain([
                segment for segment in accent_segments
                if segment.get("text") != "アクセント"
            ])

    explanation = next(
        (node for node in selected.iter() if local_name(node.tag) == "解説G"),
        None,
    )
    meaning_nodes: list[tuple[ET.Element, int]] = []

    def collect_meaning_nodes(container: ET.Element) -> None:
        def append_node(node: ET.Element, depth: int) -> None:
            tag = local_name(node.tag)
            if tag == "MG":
                meaning_nodes.append((node, depth))
                for child in node:
                    if local_name(child.tag) == "MG":
                        append_node(child, depth + 1)
                    elif local_name(child.tag) in {"MImageG", "MLocationG", "MUrlG"} and any(local_name(c.tag) == "meaning" for c in node):
                        append_node(child, depth)
            elif tag in {
                "meaning", "用例", "explanation", "SubItem",
                "MImageG", "MLocationG", "MUrlG",
            }:
                meaning_nodes.append((node, depth))

        for node in container:
            append_node(node, 0)

    if kind == "idiom":
        container = next(
            (node for node in selected if local_name(node.tag) == "SubItemC"),
            None,
        )
        if container is not None:
            collect_meaning_nodes(container)
    elif kind == "example":
        meaning_nodes = [(selected, 0)]
    elif explanation is not None:
        collect_meaning_nodes(explanation)

    for node, depth in meaning_nodes:
        tag = local_name(node.tag)
        content = node
        if tag == "MG":
            content = next(
                (child for child in node if local_name(child.tag) == "meaning"),
                node,
            )
        segments = _tokens(content, diagnostics)
        text = _plain(segments)
        if not text:
            continue
        if tag == "MUrlG":
            section_kind, label = "url", "URL"
        elif tag == "MLocationG":
            section_kind, label = "location", "地図"
        elif tag == "MImageG":
            section_kind, label = "illustration", "図版"
        else:
            section_kind, label = _section_kind(text, content.attrib.get("class", ""), content)
        number = ""
        if tag == "MG":
            rect = next(
                (child for child in content.iter() if local_name(child.tag) == "rect"),
                None,
            )
            if rect is not None:
                number = clean_text("".join(rect.itertext()))
            else:
                level = next(
                    (child for child in content.iter() if local_name(child.tag) == "L4"),
                    None,
                )
                if level is not None:
                    number = clean_text("".join(level.itertext()))
            if number:
                segments = _tokens(content, diagnostics)
                if segments and segments[0].get("text") == number:
                    segments = segments[1:]
                    text = _plain(segments)
        if label and text.startswith(label):
            text = text[len(label):].lstrip(" :：\n")
            remaining = label
            while segments and remaining:
                token = segments[0]
                if token.get("kind") == "break" or not token.get("text", "").strip():
                    segments = segments[1:]
                    continue
                value = token.get("text", "")
                trimmed = value.lstrip()
                if remaining.startswith(trimmed):
                    remaining = remaining[len(trimmed):]
                    segments = segments[1:]
                elif trimmed.startswith(remaining):
                    rest = trimmed[len(remaining):].lstrip(" :：")
                    segments[0] = dict(token, text=rest)
                    if not rest:
                        segments = segments[1:]
                    remaining = ""
                else:
                    break
            while segments and (segments[0].get("kind") == "break" or not segments[0].get("text", "").strip()):
                segments = segments[1:]
        sections.append({
            "kind": "example" if kind == "example" else section_kind,
            "label": label,
            "number": number,
            "depth": depth,
            "text": text,
            "segments": segments,
        })

    return {
        "parserVersion": PARSER_VERSION,
        "entryKind": kind,
        "sourceEntryID": key.split("-", 1)[0],
        "sourceSubentryID": key.split("-", 1)[1],
        "heading": heading,
        "headingSegments": heading_segments,
        "reading": reading,
        "writtenForms": written_forms,
        "accent": accent,
        "sections": sections,
        "plainText": "\n".join(section["text"] for section in sections),
        "unknownTags": sorted(diagnostics),
        "parseStatus": "parsed" if sections or kind == "headword" else "empty",
    }


def extract_entry_from_root(root: ET.Element, source_key: str) -> dict[str, Any]:
    contents = _find_contents(root)
    if contents is None:
        return {"parseStatus": "parser_unsupported", "sourceKey": source_key}
    selected, kind = _exact_child(contents, source_key)
    if selected is None:
        return {"parseStatus": kind, "sourceKey": source_key}
    raw_xml = ET.tostring(selected, encoding="unicode", short_empty_elements=True)
    structured = _build_document(selected, source_key, kind)
    return {
        "rawXML": raw_xml,
        "structured": structured,
        "searchText": structured["plainText"],
        "contentHash": hashlib.sha256(raw_xml.encode("utf-8")).hexdigest(),
        "parserVersion": PARSER_VERSION,
        "parseStatus": structured["parseStatus"],
        "sourceKey": source_key,
        "sourceKind": kind,
    }


def extract_entry(xml_path: Path, source_key: str) -> dict[str, Any]:
    return extract_entry_from_root(ET.parse(xml_path).getroot(), source_key)


def serialize_structured(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def main() -> int:
    parser = argparse.ArgumentParser(description="指定された辞典 Source ID の本文を読み取り専用で解析する")
    parser.add_argument("--entry", type=Path, required=True)
    parser.add_argument("--source-key", required=True)
    arguments = parser.parse_args()
    result = extract_entry(arguments.entry, arguments.source_key)
    sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
