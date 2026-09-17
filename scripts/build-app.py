#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Build and sign a macOS application from this Swift package."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from signing import configuration, sign

ROOT = pathlib.Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)

def copy_notice(source, destination):
    destination.unlink(missing_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT.parent / "Cliprill.app")
    parser.add_argument("--bundle-id", default="org.cliprill.Cliprill")
    parser.add_argument("--build-number", default="16")
    parser.add_argument("--signing-config", type=pathlib.Path)
    opts = parser.parse_args()
    signing = configuration(opts.signing_config)
    run("swift", "build", "-c", opts.configuration, "--disable-automatic-resolution")
    binary_dir = pathlib.Path(subprocess.check_output(["swift", "build", "-c", opts.configuration, "--show-bin-path"], cwd=ROOT, text=True).strip())
    destination = opts.output.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cliprill-package-", dir=ROOT / ".build") as tmp:
        stage = pathlib.Path(tmp) / "Cliprill.app"
        macos = stage / "Contents/MacOS"
        resources = stage / "Contents/Resources"
        macos.mkdir(parents=True); resources.mkdir(parents=True)
        for name in ["Cliprill", "cliprill-mcp"]:
            shutil.copy2(binary_dir / name, macos / name)
        for bundle in binary_dir.glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
        info = {
            "CFBundleName": "Cliprill", "CFBundleDisplayName": "Cliprill",
            "CFBundleIdentifier": opts.bundle_id, "CFBundleExecutable": "Cliprill",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.6.0",
            "CFBundleVersion": opts.build_number, "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
            "NSHighResolutionCapable": True, "CFBundleIconFile": "Cliprill.icns",
            "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans"],
            "NSHumanReadableCopyright": "Cliprill contributors. AGPL-3.0-only."
        }
        with (stage / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        iconset = pathlib.Path(tmp) / "Cliprill.iconset"
        run("swift", str(ROOT / "scripts/make-icon.swift"), str(iconset))
        run("iconutil", "-c", "icns", str(iconset), "-o", str(resources / "Cliprill.icns"))
        for name in ["LICENSE", "README.md", "README.en.md", "CONTRIBUTING.md", "SECURITY.md", "BRAND.md"]:
            shutil.copy2(ROOT / name, resources / name)
        if (ROOT / "docs").exists():
            shutil.copytree(ROOT / "docs", resources / "docs")
        notices = ROOT / "ThirdPartyNotices"
        notices.mkdir(exist_ok=True)
        for checkout in sorted((ROOT / ".build/checkouts").iterdir()):
            for source in checkout.iterdir():
                if source.is_file() and source.name.lower().split(".")[0] in {"license", "notice", "copying"}:
                    copy_notice(source, notices / (checkout.name + "-" + source.name))
        copy_notice(ROOT / "Vendor/KeyboardShortcuts/license", notices / "KeyboardShortcuts-license")
        shutil.copytree(notices, resources / "ThirdPartyNotices")
        sign(stage, **signing)
        if destination.exists():
            if destination.suffix != ".app":
                raise RuntimeError("Output must be an .app directory")
            shutil.rmtree(destination)
        shutil.copytree(stage, destination, symlinks=True)
    print(destination)

if __name__ == "__main__":
    main()
