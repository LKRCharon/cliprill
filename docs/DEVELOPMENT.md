# Developer guide

[简体中文首页](../README.md) · [English home](../README.en.md)

For installing and using Cliprill, start with the README. This guide covers
building, testing and changing the app.

## Build and verify

Requires Xcode 16.4 / Swift 6.1 or later and Python 3. No third-party Python modules.

```sh
swift package resolve
swift test --disable-automatic-resolution
python3 scripts/build-app.py
```

`Package.resolved` pins remote dependencies. KeyboardShortcuts 2.3.0 is vendored with
one documented resource-loader adaptation for signed app bundles. The script packages the two binaries,
localized resources, original generated icon and dependency notices, then signs
and verifies the bundle. It uses a configured signing identity when available;
unconfigured contributor builds remain ad-hoc signed. Output defaults to
`../Cliprill.app`. See [signing setup](SIGNING.md) for certificate signing.

For an isolated manual test build:

```sh
python3 scripts/build-app.py --configuration debug --output /tmp/Cliprill-QA.app --bundle-id org.cliprill.Cliprill.qa
/tmp/Cliprill-QA.app/Contents/MacOS/Cliprill --data-dir /tmp/cliprill-qa --no-capture
```

`--background` leaves the panel closed. `--no-capture` avoids recording the real
clipboard during QA. The app and helper must use the same data directory. See
[validation](VALIDATION.md) for the tested scope and remaining native paste checks.

GitHub Actions runs Swift tests, release packaging/signature verification and the
packaged MCP smoke test on Apple Silicon and Intel. See [CONTRIBUTING.md](../CONTRIBUTING.md)
for isolated test commands and PR guidance, [SECURITY.md](../SECURITY.md) for private
vulnerability reports, and [the release process](RELEASING.md) for maintainers.

## Code map

| Location | Responsibility |
| --- | --- |
| `Sources/CliprillApp` | AppKit panel, editors, settings, shortcuts, permissions and paste coordination |
| `Sources/CliprillCore` | History, FIFO queues, pinboards, SQLite persistence and local IPC |
| `Sources/CliprillClipboard` | Reading clipboard representations and writing text/PNG/TIFF |
| `Sources/CliprillMCP` | MCP tool schemas and the embedded stdio helper |
| `Tests` | State transitions, migration, image lifetime and private-pasteboard checks |
| `scripts` | Packaging, signatures, generated assets and packaged integration checks |

The app owns the core and serves a private Unix socket; the MCP helper connects
to it instead of opening another database owner. The default database is
`~/Library/Application Support/Cliprill/cliprill.sqlite`. Text, image blobs,
thumbnails, source-app names and retry receipts stay local. Keep real clipboard
contents out of fixtures, logs, screenshots and public issues.

Schema 3 adds independent pinboards and reads schema 1/2. Board payload changes
commit with state and retry receipts in the same SQLite transaction. Older app
versions cannot open schema 3: downgrade recovery needs both the old app and a
pre-migration database backup, taken while Cliprill is stopped.

## Paste delivery contract

Cliprill sends tagged paste key events to the captured foreground app and advances
the queue after dispatch. macOS provides no universal acknowledgement that the
recipient read the clipboard. A dispatched item does not guarantee receipt; a
crash between dispatch and commit can require manual review.

Distinct rapid requests are serialized with a 160 ms dispatch interval. Holding
Command–V does not repeatedly consume a queue. The last dispatched item stays on
the clipboard until the next request. Focus, clipboard revision, permissions and
Secure Input are rechecked before dispatch. Menu/trackpad Paste and remapped paste
keys do not consume the queue. These constraints matter when changing delivery
logic; automated core tests do not establish physical target-app reception.

## Further documentation

- [Contributing](../CONTRIBUTING.md): PR expectations and required checks.
- [MCP integration](MCP.md): client setup, tools, paging and retry semantics.
- [Interaction design](INTERACTIONS.md): panel behavior, shortcuts and accessibility.
- [Pinboards](PINBOARDS.md): snapshots, storage limits and design research.
- [Images](IMAGES.md): representation handling and the original image migration.
- [Validation](VALIDATION.md): recorded checks and manual-test boundaries.
- [Signing](SIGNING.md): contributor builds, fixed release identity and upgrades.
- [Releasing](RELEASING.md): protected branches, tags and publication.
- [Security](../SECURITY.md): private vulnerability reports and trust boundaries.

## Licensing and distribution

Original code is **AGPL-3.0-only**. This strong-copyleft license permits commercial
use; it does not ban commercial forks. Dependencies retain their licenses in
`ThirdPartyNotices/`. See [LICENSE](../LICENSE) and [BRAND.md](../BRAND.md).
Rebuilding, changing signatures or moving a build may require reauthorizing
Accessibility. The build script creates a local bundle; only the release workflow
publishes tagged packages.
