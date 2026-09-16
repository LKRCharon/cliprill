#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Prepare the pinned public Lucide SVGs. No runtime or build dependencies required."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
vendor = root / "Vendor/Lucide"
resources = root / "Sources/CliprillApp/Resources/Icons"
resources.mkdir(parents=True, exist_ok=True)
manifest = json.loads((vendor / "manifest.json").read_text())
for record in manifest["icons"]:
    data = (vendor / record["file"]).read_bytes()
    assert hashlib.sha256(data).hexdigest() == record["sha256"], record["file"]
    svg = data.decode().replace('stroke="currentColor"', 'stroke="#000000"').replace('stroke-width="2"', 'stroke-width="1.75"')
    (resources / ("lucide-" + record["file"])).write_text(svg)
print(f"Prepared {len(manifest['icons'])} Lucide {manifest['version']} icons")
