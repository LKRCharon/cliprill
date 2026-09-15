# Cliprill

[![CI](https://github.com/LKRCharon/cliprill/actions/workflows/ci.yml/badge.svg)](https://github.com/LKRCharon/cliprill/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/LKRCharon/cliprill)](https://github.com/LKRCharon/cliprill/releases/latest)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue)](LICENSE)

A small native macOS clipboard manager with a FIFO paste queue and an MCP interface.

Copy or import `A, A, B`, then press Command–V three times to paste `A`, `A`, `B`.
The panel opens near your pointer. Queues also work through an embedded MCP helper.

Cliprill 0.1.0 supports plain text, including multiline text. Requires macOS 14+.
The interface is available in English and Simplified Chinese.

## Install

Download the matching ZIP from [Releases](https://github.com/LKRCharon/cliprill/releases/latest):
`macOS-arm64` for Apple Silicon or `macOS-x86_64` for Intel. Unzip it and open
`Cliprill.app`; you can move it to Applications first. `SHA256SUMS.txt` accompanies
each release, and the source archive matches the tagged commit.

The app is ad-hoc signed, not Developer ID signed or notarized. macOS may block
the first launch. For a copy you trust, use **System Settings → Privacy & Security
→ Open Anyway**. Sequential paste also requires Accessibility access for that app.

## Start using it

1. Open `Cliprill.app`. It lives in the menu bar.
2. Press **Control–Option–V** to open the panel near the pointer. Change this shortcut in Settings.
3. Copy text normally to build history. Click a row's **+** to append it to the selected queue.
4. The top **+** creates a queue from text. Choose **Whole text** or explicitly split by lines.
5. Select **Queue → Start queue**. Enable Cliprill in **System Settings → Privacy & Security → Accessibility** when requested.
6. Focus your destination app. Each ordinary **Command–V** dispatches one item in FIFO order.

Use the arrow buttons to reorder remaining items, the trash button to remove one,
and the undo button to restore the last dispatched item. Restoring an item pauses
the queue; it does not undo text inside the destination app. Enter pastes a history
item; Option–Enter appends it to the queue. The preview button shows complete text.

Copying something else pauses an active queue. Closing the panel keeps the service
running. Restarting the app restores unfinished queues in a paused state. A queue
owns independent text snapshots, so clearing history does not empty it. Duplicate
entries are preserved; `A, A, B` takes three paste requests. No reverse insertion is needed.

## Paste behavior and limits

Cliprill sends tagged paste key events to the captured foreground app and advances
the queue after dispatch. macOS offers no universal acknowledgement that an app
read the clipboard. A dispatched item is **not a guarantee of successful receipt**.
If an app ignores the paste, restore the last item and retry. A crash between event
dispatch and the database commit can also cause an item to need manual review.

The last dispatched item remains on the clipboard until the next real paste
request. Distinct rapid presses are serialized with a 160 ms dispatch interval;
holding Command–V does not repeatedly consume the queue. A slow target can still
read late. V1 intercepts ordinary Command–V only, not menu/trackpad Paste, remapped
paste keys, Shift–Command–V, rich text, images, or files. Secure Input and missing
Accessibility permission prevent queue activation.

## MCP

Settings has **Copy MCP configuration**. The stdio helper is embedded in the app:

```json
{
  "mcpServers": {
    "cliprill": {
      "command": "/absolute/path/Cliprill.app/Contents/MacOS/cliprill-mcp",
      "args": []
    }
  }
}
```

The helper uses the official Swift MCP SDK. It connects through a current-user-only
Unix socket and starts its containing app in the background when necessary. No open
window or network service is required. Set `CLIPRILL_DATA_DIR` consistently in the
app and helper to use a separate data directory.

Example `queue_create` arguments:

```json
{
  "title": "Form fields",
  "idempotency_key": "form-001",
  "items": [
    {"label": "First field", "text": "A"},
    {"label": "Second field", "text": "A"},
    {"label": "Notes", "text": "Line one\nLine two"}
  ]
}
```

Read `queue_get` with `include_content: true` to verify exact order. Results use
`offset`/`limit` paging (up to 100 entries and 2 MB encoded items); follow `next_offset`
until null. `item_ids` always lists the complete queue order. `queue_activate`
prepares the clipboard and enables sequential paste; it never types by itself.

| Tool | Behavior |
| --- | --- |
| `queue_create`, `queue_append` | Atomic ordered writes; duplicate items kept |
| `queue_list`, `queue_get` | Metadata by default; text only on explicit request |
| `queue_reorder`, `queue_remove` | Require the current `expected_revision` |
| `queue_activate`, `queue_pause` | Control sequential paste |
| `queue_undo_last` | Restore the last dispatched item and pause |
| `queue_delete` | Delete a saved queue; requires current revision |
| `history_search` | Read bounded text history pages |

Every MCP write requires `idempotency_key`. Repeating a key with identical arguments
returns the original saved response, even after a restart; use `queue_get` for current
state. Reusing a key with changed arguments returns `idempotency_conflict`. A queue
being dispatched returns `busy` for concurrent mutations; retry with the same key.
Version mismatches return `revision_conflict`, and invalid permutations fail atomically.

Limits: 100 saved queues, 1,000 entries per queue, 256 KiB per item, 2 MB per import,
8 MB total queue text. History supports up to 2,000 entries within an 8 MB text budget;
search pages return up to 100 entries and 2 MB of encoded items. The local message limit is 4 MB.

For shell inspection, the helper also supports:

```sh
"/path/to/Cliprill.app/Contents/MacOS/cliprill-mcp" --call queue_list '{}'
```

## Data and privacy

The app stores text and source-app names locally in
`~/Library/Application Support/Cliprill/cliprill.sqlite` (SQLite, WAL, atomic snapshots
and retry receipts). The directory and socket are private to the current user.
There is no telemetry, cloud sync or app network listener. MCP clients you configure
can read text through the declared tools; no content is logged by the app/helper.

Transient/concealed pasteboard types and common password-manager bundle IDs are
excluded from history. Add further app exclusions in Settings. This cannot detect
every secret copied as plain text. History capture can be disabled. Clearing history
deletes application records; it is not a forensic disk-erasure guarantee.

## Build and verify

Requires Xcode 16.4 / Swift 6.1 or later and Python 3. No third-party Python modules.

```sh
swift package resolve
swift test --disable-automatic-resolution
python3 scripts/build-app.py
```

`Package.resolved` pins remote dependencies. KeyboardShortcuts 2.3.0 is vendored with
one documented resource-loader adaptation for signed app bundles. The script packages the two binaries,
localized resources, original generated icon and dependency notices, then ad-hoc
signs and verifies the bundle. Output defaults to `../Cliprill.app`.

For an isolated manual test build:

```sh
python3 scripts/build-app.py --configuration debug --output /tmp/Cliprill-QA.app --bundle-id org.cliprill.Cliprill.qa
/tmp/Cliprill-QA.app/Contents/MacOS/Cliprill --data-dir /tmp/cliprill-qa --no-capture
```

`--background` leaves the panel closed. `--no-capture` avoids recording the real
clipboard during QA. The app and helper must use the same data directory. See
`docs/VALIDATION.md` for the tested scope and remaining native paste checks.

GitHub Actions runs Swift tests, release packaging/signature verification and the
packaged MCP smoke test on Apple Silicon and Intel. See [CONTRIBUTING.md](CONTRIBUTING.md)
for isolated test commands and PR guidance, [SECURITY.md](SECURITY.md) for private
vulnerability reports, and [the release process](docs/RELEASING.md) for maintainers.

## License

Original code is **AGPL-3.0-only**. This is strong copyleft and allows commercial use;
it does not prohibit competitors or commercial forks. Dependencies retain their own
licenses in `ThirdPartyNotices/`. Brand use is discussed separately in `BRAND.md`.
Rebuilding or moving the app can require reauthorizing Accessibility. The build
script only creates a local app; the GitHub Release workflow publishes tagged builds.
