#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Sign bundles with an identity bound to both the certificate and bundle ID."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

OPENSSL = next((path for path in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl")
                if Path(path).is_file()), shutil.which("openssl") or "openssl")


def configuration(path=None):
    local = Path.home() / "Library/Application Support/CliprillSigning/keychain/environment.json"
    if path is None and not os.environ.get("CLIPRILL_SIGNING_IDENTITY") and local.is_file():
        path = local
    if path:
        path = Path(path)
        if (path.parent / "state.json").exists():
            run("python3", str(Path(__file__).with_name("signing-keychain.py")), "unlock", "--state-dir", str(path.parent))
        settings = json.loads(path.read_text())
    else:
        settings = os.environ
    return {"identity": settings.get("CLIPRILL_SIGNING_IDENTITY", "-"),
            "keychain": settings.get("CLIPRILL_SIGNING_KEYCHAIN"),
            "certificate": settings.get("CLIPRILL_SIGNING_CERTIFICATE")}


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"{args[0]} failed")
    return result


def certificate_der(certificate):
    return subprocess.check_output([OPENSSL, "x509", "-in", str(certificate), "-outform", "DER"])


def requirement(identifier, certificate):
    if not re.fullmatch(r"[A-Za-z0-9.-]+", identifier):
        raise ValueError("Invalid signing identifier")
    fingerprint = hashlib.sha1(certificate_der(certificate)).hexdigest()
    return f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'


def bundle_identifier(app):
    with (Path(app) / "Contents/Info.plist").open("rb") as handle:
        return plistlib.load(handle)["CFBundleIdentifier"]


def verify(app, certificate=None):
    app = Path(app)
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))
    if certificate:
        identifier = bundle_identifier(app)
        for path, signing_id in [(app, identifier), (app / "Contents/MacOS/cliprill-mcp", identifier + ".mcp")]:
            run("codesign", "--verify", "--strict", "--all-architectures", "-R", "=" + requirement(signing_id, certificate), str(path))


def sign(app, identity="-", keychain=None, certificate=None):
    app = Path(app)
    if identity != "-" and not certificate:
        raise ValueError("Certificate signing requires the expected public certificate")
    if identity == "-" and certificate:
        raise ValueError("A public certificate cannot be paired with ad-hoc signing")
    if certificate:
        expected = hashlib.sha1(certificate_der(certificate)).hexdigest()
        if identity.lower() != expected:
            raise ValueError("Signing identity does not match the pinned public certificate")
    options = ["codesign", "--force", "--timestamp=none", "--sign", identity]
    if keychain:
        options.extend(["--keychain", str(keychain)])
    identifier = bundle_identifier(app)
    # Sign inside out. Do not use --deep for signing, which can overwrite helper identities.
    for path, signing_id in [(app / "Contents/MacOS/cliprill-mcp", identifier + ".mcp"), (app, identifier)]:
        args = options + ["--identifier", signing_id]
        if certificate:
            args += ["--requirements", "=designated => " + requirement(signing_id, certificate)]
        run(*args, str(path))
    verify(app, certificate)
