#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Prepare an isolated signing keychain; never print private keys or passwords."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import uuid

from signing import OPENSSL, certificate_der


def command(*args, **kwargs):
    if args[0] == "openssl":
        args = (OPENSSL, *args[1:])
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        # Security/OpenSSL diagnostics can echo arguments; keep them out of CI logs.
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode})")
    return result.stdout


def security(*args):
    # security -i keeps passwords out of process arguments and shell tracing.
    line = " ".join(shlex.quote(str(arg)) for arg in args) + "\n"
    result = subprocess.run(["security", "-i"], input=line, text=True, capture_output=True)
    if result.returncode or "SecKeychain" in result.stderr or "SecItem" in result.stderr:
        raise RuntimeError(f"security {args[0]} failed")


def make_searchable(keychain):
    current = shlex.split(command("security", "list-keychains", "-d", "user").decode())
    if str(keychain) not in current:
        command("security", "list-keychains", "-d", "user", "-s", *current, str(keychain))


def prepare(opts):
    directory = opts.state_dir.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    keychain = directory / "signing.keychain-db"
    certificate = directory / "certificate.pem"
    p12 = directory / "identity.p12"
    state = {"keychain": str(keychain), "certificate": str(certificate), "trust_added": False,
             "password_service": opts.password_service}
    state_file = directory / "state.json"
    state_file.write_text(json.dumps(state))
    keychain_password = secrets.token_hex(32)
    try:
        if opts.ephemeral:
            password = secrets.token_hex(32)
            key = directory / "private.key"
            command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2",
                    "-subj", "/CN=Cliprill CI " + uuid.uuid4().hex,
                    "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "keyUsage=critical,digitalSignature",
                    "-addext", "extendedKeyUsage=critical,codeSigning", "-keyout", str(key), "-out", str(certificate))
            command("openssl", "pkcs12", "-export", "-legacy", "-inkey", str(key), "-in", str(certificate),
                    "-out", str(p12), "-passout", "stdin", input=(password + "\n").encode())
            key.unlink()
        else:
            if opts.p12_file:
                if not opts.password_service:
                    raise ValueError("--p12-file requires --password-service")
                password = command("security", "find-generic-password", "-s", opts.password_service, "-w").decode().strip()
                keychain_password = password
                p12.write_bytes(opts.p12_file.read_bytes())
            else:
                password = os.environ.get("CLIPRILL_SIGNING_PASSWORD", "")
                encoded = os.environ.get("CLIPRILL_SIGNING_P12", "")
                if not encoded or not password:
                    raise ValueError("Release signing credentials are missing")
                p12.write_bytes(base64.b64decode(encoded, validate=True))
            if not opts.certificate:
                raise ValueError("Release signing requires a pinned public certificate")
            command("openssl", "pkcs12", "-legacy", "-in", str(p12), "-clcerts", "-nokeys", "-out", str(certificate),
                    "-passin", "stdin", input=(password + "\n").encode())
            if certificate_der(certificate) != certificate_der(opts.certificate):
                raise ValueError("Imported certificate differs from the pinned public certificate")
        p12.chmod(0o600)
        security("create-keychain", "-p", keychain_password, str(keychain))
        security("set-keychain-settings", "-lut", "21600", str(keychain))
        security("unlock-keychain", "-p", keychain_password, str(keychain))
        security("import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign")
        security("set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychain_password, str(keychain))
        # codesign needs the identity in the search list even with an explicit --keychain.
        make_searchable(keychain)
        # Trust this certificate only for code signing, in this user's domain.
        # Never change system trust, Gatekeeper, or the default keychain.
        command("security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", str(certificate))
        state["trust_added"] = True
        state_file.write_text(json.dumps(state))
        identity = hashlib.sha1(certificate_der(certificate)).hexdigest().upper()
        identities = command("security", "find-identity", "-v", "-p", "codesigning", str(keychain)).decode()
        if identity not in identities:
            raise RuntimeError("Imported signing identity is unavailable")
        environment = {"CLIPRILL_SIGNING_IDENTITY": identity, "CLIPRILL_SIGNING_KEYCHAIN": str(keychain),
                       "CLIPRILL_SIGNING_CERTIFICATE": str(certificate)}
        (directory / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
        if os.environ.get("GITHUB_ENV"):
            with Path(os.environ["GITHUB_ENV"]).open("a") as handle:
                for name, value in environment.items():
                    if "\n" in value or "\r" in value:
                        raise ValueError("Invalid environment value")
                    handle.write(f"{name}={value}\n")
        print(json.dumps({"identity": identity, "configuration": str(directory / "environment.json")}))
    finally:
        # The encrypted archive and any generation intermediate are not needed after import.
        p12.unlink(missing_ok=True)
        (directory / "private.key").unlink(missing_ok=True)


def cleanup(opts):
    directory = opts.state_dir.resolve()
    state_file = directory / "state.json"
    if not state_file.exists():
        return
    state = json.loads(state_file.read_text())
    keychain = Path(state["keychain"])
    certificate = Path(state["certificate"])
    if keychain.parent != directory or certificate.parent != directory:
        raise ValueError("Signing state does not belong to this directory")
    if state["trust_added"]:
        command("security", "remove-trusted-cert", str(certificate))
        state["trust_added"] = False
        state_file.write_text(json.dumps(state))
    if keychain.exists():
        current = shlex.split(command("security", "list-keychains", "-d", "user").decode())
        if str(keychain) in current:
            command("security", "list-keychains", "-d", "user", "-s", *[p for p in current if p != str(keychain)])
        command("security", "delete-keychain", str(keychain))
    (directory / "environment.json").unlink(missing_ok=True)
    state_file.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "cleanup", "unlock"])
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--ephemeral", action="store_true")
    parser.add_argument("--certificate", type=Path)
    parser.add_argument("--p12-file", type=Path)
    parser.add_argument("--password-service")
    opts = parser.parse_args()
    if opts.action == "prepare":
        prepare(opts)
    elif opts.action == "cleanup":
        cleanup(opts)
    else:
        state = json.loads((opts.state_dir / "state.json").read_text())
        if state.get("password_service"):
            password = command("security", "find-generic-password", "-s", state["password_service"], "-w").decode().strip()
            security("unlock-keychain", "-p", password, state["keychain"])
        make_searchable(state["keychain"])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
