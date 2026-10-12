#!/usr/bin/env python3
# Copyright (C) 2024 Checkmk GmbH - License: GNU General Public License v2
# This file is part of Checkmk (https://checkmk.com). It is subject to the terms and
# conditions defined in the file COPYING, which is part of this source code package.
"""Fill in the metadata placeholders of an `mkp template` manifest.

`mkp template <name>` (see scripts/build-mkp.sh) auto-discovers the package's
files and writes a manifest with placeholder values for the human-authored
metadata fields. This script overwrites those placeholders with real values
supplied on the command line while leaving the auto-discovered ``files``
mapping untouched, and writes the result back as the same Python-literal
format the `mkp package` command expects.
"""

from __future__ import annotations

import argparse
import ast
import pprint
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="Path to the manifest produced by 'mkp template'")
    parser.add_argument("--title", required=True, help="Human readable package title")
    parser.add_argument("--description", required=True, help="Package description")
    parser.add_argument("--author", required=True, help="Package author/maintainer")
    parser.add_argument("--download-url", required=True, help="Project/download URL")
    parser.add_argument("--version", required=True, help="Package version (semantic versioning)")
    parser.add_argument(
        "--version-min-required", required=True, help="Minimum required Checkmk version"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    manifest = ast.literal_eval(args.manifest.read_text())

    if not manifest.get("files"):
        sys.stderr.write(
            "ERROR: manifest has no files listed. Make sure the plugin files were copied "
            "into the site (and are readable by the site user) before running 'mkp template'.\n"
        )
        return 1

    manifest["title"] = args.title
    manifest["description"] = args.description
    manifest["author"] = args.author
    manifest["download_url"] = args.download_url
    manifest["version"] = args.version
    manifest["version.min_required"] = args.version_min_required

    args.manifest.write_text(f"{pprint.pformat(manifest)}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
