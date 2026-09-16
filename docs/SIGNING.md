# Signing and upgrades

Starting with 0.2.2, official Cliprill releases share the self-signed certificate
in [`Signing/Cliprill.pem`](../Signing/Cliprill.pem). No Apple Developer Program
subscription is used. This is not Developer ID signing or Apple notarization;
downloaded apps may still require **Privacy & Security → Open Anyway**.

The application identity includes both `org.cliprill.Cliprill` and the exact
signing certificate. The MCP helper uses `org.cliprill.Cliprill.mcp` with the same
certificate. An update can change its code hash while satisfying the previous
designated requirement. The requirement never matches a bundle ID alone.

The public certificate has SHA-256 fingerprint:

```text
c84a4ff4ddc74234490a15422ad91838b4b51648a1fce51e4f5883f70f04f0c0
```

## First migration

0.2.0 and earlier used ad-hoc signatures whose identities were code hashes. That
grant cannot carry over to the new certificate. In System Settings, remove the
old Accessibility entry, add the current `/Applications/Cliprill.app`, and enable
it again. A switch can display enabled even when its saved identity no longer
matches the installed app. The permission guide now describes this recovery.

The app continues to use `AXIsProcessTrusted()` to check actual access. It does
not edit the permissions database, reset other apps' grants, or enable access
itself. A stable code identity does not replace the initial user authorization.
Certificate rotation also requires new authorization.

## Maintainer setup

The encrypted release identity is kept outside the repository under
`~/Library/Application Support/CliprillSigning/identity.p12`. Its password is in
the login keychain as generic-password service `org.cliprill.signing.release`.
Keep a protected backup of both; regenerating a certificate changes its identity.
Only the public PEM is committed or attached to releases.

Prepare a local signing keychain once (requires OpenSSL 3, available through
Homebrew's `openssl@3`):

```sh
python3 scripts/signing-keychain.py prepare \
  --state-dir "$HOME/Library/Application Support/CliprillSigning/keychain" \
  --p12-file "$HOME/Library/Application Support/CliprillSigning/identity.p12" \
  --password-service org.cliprill.signing.release \
  --certificate Signing/Cliprill.pem
python3 scripts/build-app.py
python3 scripts/test-signing.py ../Cliprill.app
```

The builder discovers that local configuration and unlocks its dedicated keychain
using the saved password. Other setups can pass `--signing-config` pointing to the
generated `environment.json`, or provide the three `CLIPRILL_SIGNING_*` variables
listed there. A configured but unavailable identity fails the build; it does not
silently substitute an ad-hoc signature. Builds without any configuration retain
an ad-hoc fallback for contributors. Contributors do not need the release key.

Private keys and passwords never enter build arguments or logs. The keychain
helper passes secret-bearing security commands through standard input and allows
`codesign` to use the key. It preserves existing keychain search entries without
changing the default keychain or installing certificate trust. The explicit
certificate-pinned requirement works without a trusted root. Keychain operations
have bounded timeouts and log only their operation names. App users do not need
to install this certificate as a trusted root.

## GitHub Actions

The `release-signing` environment allows only `v*` tags. It stores
`CLIPRILL_SIGNING_P12` (base64 of the encrypted archive) and
`CLIPRILL_SIGNING_PASSWORD`. Reusable CI selects this environment only for the
release workflow. A separate job without secrets checks the protected tag and
main ancestry before the signing jobs start. Each signer checks the imported
certificate against the committed PEM. The caller explicitly inherits secrets,
and the reusable workflow declares both signing secret names. A release job checks
that the environment supplied them before starting the build; it never prints
their values.

A repository ruleset restricts `v*` tag creation to administrators. This is the
trust boundary for the workflow definition itself: an ancestry check inside a
workflow cannot defend against a maintainer replacing that workflow on a tag.
Administrators control both release tags and environment settings. A separate
ruleset prevents tag updates and deletion without an administrator bypass.

PR and main CI use the separate `ci` environment, a fresh disposable certificate
and the `org.cliprill.Cliprill.ci` bundle ID. They do not receive the release key.
Each runner uses its own temporary keychain. An always-run cleanup step removes
that keychain and its search entry. No certificate trust is installed on the
runner. Private key files are never included in package artifacts or build caches.

Both architectures verify the app and helper against the expected certificate,
run 24 Swift tests and the packaged MCP smoke test, and run four additional signing
checks: changed-code-hash upgrade identity, resource tampering, changed bundle ID,
and missing signing certificate. These cryptographic checks do not by themselves
prove that a particular macOS installation retained its Accessibility grant.

The certificate is included with release downloads for verification. It is not a
request to install a system trust profile, disable Gatekeeper, or weaken macOS
privacy controls.
