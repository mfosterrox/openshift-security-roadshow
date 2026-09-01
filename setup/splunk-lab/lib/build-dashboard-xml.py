#!/usr/bin/env python3
"""Wrap a Dashboard Studio JSON export in Splunk data/ui/views XML."""

from __future__ import annotations

import argparse
import json
import sys
import xml.sax.saxutils as sax
from pathlib import Path


def cdata_safe(text: str) -> str:
    """Escape sequences that would terminate a CDATA section."""
    return text.replace("]]>", "]]]]><![CDATA[>")


def build_dashboard_xml(payload: dict, *, theme: str = "light") -> str:
    title = sax.escape(payload.get("title") or "RHACS Security Operations Dashboard")
    description = sax.escape(payload.get("description") or "")
    definition = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)

    hidden_meta = json.dumps(
        {
            "hideEdit": False,
            "hideOpenInSearch": False,
            "hideExport": False,
        },
        separators=(",", ":"),
    )

    return (
        f'<dashboard version="2" theme="{theme}">\n'
        f"  <label>{title}</label>\n"
        f"  <description>{description}</description>\n"
        f"  <definition><![CDATA[\n{definition}\n]]></definition>\n"
        f"  <meta type=\"hiddenElements\"><![CDATA[\n{hidden_meta}\n]]></meta>\n"
        "</dashboard>"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_file", type=Path, help="Dashboard Studio JSON export")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Write XML to this file (default: stdout)",
    )
    parser.add_argument(
        "--theme",
        default="light",
        choices=("light", "dark"),
        help="Dashboard Studio theme attribute",
    )
    args = parser.parse_args()

    payload = json.loads(args.json_file.read_text(encoding="utf-8"))
    xml = build_dashboard_xml(payload, theme=args.theme)

    if args.output:
        args.output.write_text(xml, encoding="utf-8")
    else:
        sys.stdout.write(xml)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
