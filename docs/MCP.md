# MCP integration

[简体中文首页](../README.md) · [English home](../README.en.md) · [Developer guide](DEVELOPMENT.md)

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
| `history_search` | Read bounded text history or image metadata pages |
| `board_list`, `board_get` | Read board metadata; text requires `include_content: true` |
| `board_create`, `board_update`, `board_delete` | Create, rename, recolor or delete a pinboard |
| `board_add`, `board_edit_item`, `board_remove` | Save text/history snapshots, edit or remove items |
| `board_reorder`, `board_move` | Reorder saved items or atomically move between boards |

Every MCP write requires `idempotency_key`. Repeating a key with identical arguments
returns the original saved response, even after a restart; use `queue_get` for current
state. Reusing a key with changed arguments returns `idempotency_conflict`. A queue
being dispatched returns `busy` for concurrent mutations; retry with the same key.
Version mismatches return `revision_conflict`, and invalid permutations fail atomically.

To enqueue an existing image, use an item such as `{"history_id":"ID_FROM_HISTORY_SEARCH"}`
in `queue_create` or `queue_append`. Each item accepts either `text` or `history_id`,
with an optional `label`. Image responses include kind, dimensions and size;
image pixels are not embedded in MCP JSON responses.

Limits: 100 saved queues, 1,000 entries per queue, 256 KiB per text item, 2 MB per text import,
8 MB total queue text. Images are limited to 40 megapixels and 64 MiB after PNG
normalization, with 256 MiB for history images and a separate shared 256 MiB budget for unique queue/pinboard images.
History supports up to 2,000 entries within an 8 MB text budget;
search pages return up to 100 entries and 2 MB of encoded items. The local message limit is 4 MB.

For shell inspection, the helper also supports:

```sh
"/path/to/Cliprill.app/Contents/MacOS/cliprill-mcp" --call queue_list '{}'
```

Pinboard edits require `expected_revision`; a cross-board move also requires
`destination_revision`. `board_add` accepts exactly one of `text` and `history_id`.
Board content is paged like queues and images return metadata only. A sensitive
item's preview flag does not restrict explicit `include_content: true` reads.
See [pinboard storage and limits](PINBOARDS.md#storage-and-api).

## Access and troubleshooting

Configured MCP clients can read clipboard history and explicitly request saved
text. Connect only clients you intend to give that access. The socket verifies the
current user; it does not isolate Cliprill from other software running as that user.

If the helper cannot connect, open Cliprill and check that the app and helper use
the same data directory. Queue activation needs macOS Accessibility permission;
creating and reading queues or boards does not. See [development and isolated
testing](DEVELOPMENT.md) for `--no-capture` and separate data directories.
