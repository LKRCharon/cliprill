#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise upgrade identity, helper verification and rejection of altered bundles."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from signing import configuration, run, sign, verify


def must_reject(*args):
    if subprocess.run(args, capture_output=True).returncode == 0:
        raise AssertionError("An invalid signature or identity was accepted")


def cdhash(app):
    result = run("codesign", "-d", "--verbose=4", str(app))
    return re.search(r"^CDHash=(\w+)$", result.stderr, re.MULTILINE).group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--signing-config", type=Path)
    opts = parser.parse_args()
    settings = configuration(opts.signing_config)
    if not settings["certificate"]:
        raise ValueError("These checks require a certificate-signed bundle")
    app = opts.app.resolve()
    verify(app, settings["certificate"])
    displayed = run("codesign", "-d", "-r-", str(app))
    original_requirement = next(line.split("designated => ", 1)[1] for line in
                                (displayed.stdout + displayed.stderr).splitlines() if "designated => " in line)
    with tempfile.TemporaryDirectory(prefix="cliprill-signature-check-") as temporary:
        changed = Path(temporary) / "Cliprill.app"
        shutil.copytree(app, changed, symlinks=True)
        info_path = changed / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleVersion"] = "9999.1"
        info_path.write_bytes(plistlib.dumps(info))
        sign(changed, **settings)
        assert cdhash(changed) != cdhash(app), "The upgrade must have a different code hash"
        run("codesign", "--verify", "--strict", "-R", "=" + original_requirement, str(changed))
        # A modified resource is rejected, even though it is in the same bundle path.
        with (changed / "Contents/Resources/LICENSE").open("a") as handle:
            handle.write("\nSignature tampering test\n")
        must_reject("codesign", "--verify", "--deep", "--strict", str(changed))
        # The same signer cannot inherit this identity under another bundle ID.
        info["CFBundleIdentifier"] += ".different"
        info_path.write_bytes(plistlib.dumps(info))
        sign(changed, **settings)
        must_reject("codesign", "--verify", "-R", "=" + original_requirement, str(changed))
        # Matching the bundle ID without the original certificate also fails.
        info["CFBundleIdentifier"] = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        info_path.write_bytes(plistlib.dumps(info))
        sign(changed)
        must_reject("codesign", "--verify", "-R", "=" + original_requirement, str(changed))
    print(json.dumps({"passed": True, "checks": 4, "changed_code_hash_matches_original_identity": True,
                      "rejects_tampering": True, "rejects_different_bundle_id": True, "rejects_missing_certificate": True}))


if __name__ == "__main__":
    main()
