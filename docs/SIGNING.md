# Signing and upgrades

Starting with 0.2.1, official Cliprill releases share the self-signed certificate
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
helper passes secret-bearing security commands through standard input, allows
`codesign` to use the key, and trusts the certificate only for code signing in the
signing user's domain. It preserves existing keychain search entries and does not
change the default keychain or system-wide certificate trust. App users do not
need to install this certificate as a trusted root.

## GitHub Actions

The `release-signing` environment allows only `v*` tags. It stores
`CLIPRILL_SIGNING_P12` (base64 of the encrypted archive) and
`CLIPRILL_SIGNING_PASSWORD`. Reusable CI selects this environment only for the
release workflow, checks the protected tag and main ancestry, and checks the
imported certificate against the committed PEM before signing.

PR and main CI use the separate `ci` environment, a fresh disposable certificate
and the `org.cliprill.Cliprill.ci` bundle ID. They do not receive the release key.
Each runner uses its own temporary keychain. An always-run cleanup step removes
that keychain, its search entry, and its certificate's temporary code-signing
trust. Private key files are never included in package artifacts or build caches.

Both architectures verify the app and helper against the expected certificate,
run 24 Swift tests and the packaged MCP smoke test, and run four additional signing
checks: changed-code-hash upgrade identity, resource tampering, changed bundle ID,
and missing signing certificate. These cryptographic checks do not by themselves
prove that a particular macOS installation retained its Accessibility grant.

The certificate is included with release downloads for verification. It is not a
request to install a system trust profile, disable Gatekeeper, or weaken macOS
privacy controls.
