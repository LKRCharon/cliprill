# Pinboards

Use **Shift–Command–B** or the **Pinboards / 常用** tab for reusable items.
Create a board from **⋯ → New pinboard**, then choose its name and one of six
colors. The picker remembers the last board. **Add item** saves text directly;
History's context menu offers **Pin to board**, including for captured images.

Give long snippets short labels such as “Personal email” or “Internship impact”.
Return or double-click pastes once and closes the panel, preserving the saved
item. Space / Command–Y opens the full preview. Context menus support editing,
ordering, moving between boards and removing items. Deleting a whole board asks
for confirmation. Switching here pauses any active FIFO queue.

Each saved item is an independent snapshot. History cleanup, capacity and age
limits do not remove it. Editing a saved snippet does not edit the history copy.
Multiple boards may hold independent copies of the same content. Images share
immutable blobs and are collected only after their last history/queue/board
reference is gone.

A sensitive item hides its body and thumbnail in the list, tooltip and accessible
row label; search only matches its label. Full preview/edit and pasting are
explicit ways to reveal it. The global preview setting can hide all board body
previews. These are display preferences, not encryption. Storage is local under
the current user's private application-support directory. Same-user software and
configured MCP clients may access saved content. Use a short non-sensitive label.

## Storage and API

Schema 3 reads schema 1/2 and defaults missing boards to empty. Board payloads are
stored separately from the changing history/queue snapshot in the same SQLite
transaction. Only changed boards are encoded/written. Persisted retry receipts
commit with mutations; stale revisions reject edits and cross-board moves.

Limits: 30 boards, 500 items per board, 2,000 items and 8 MB text/labels total;
256 KiB per text item. Queue and board images together are bounded to 256 MiB,
sharing references; history has its existing independent image-retention budget.

MCP adds `board_list`, `board_get`, `board_create`, `board_update`, `board_delete`,
`board_add`, `board_edit_item`, `board_remove`, `board_reorder`, and `board_move`.
All writes require an idempotency key; edits require the current revision, and a
move requires both revisions. `board_get` defaults to metadata; explicitly set
`include_content: true` to retrieve text. Image bytes are never returned. Follow
`next_offset` for bounded pages. Tool schemas describe all arguments.

## Design research, 2026-09-17

[Paste's official Pinboards guide](https://pasteapp.io/help/organize-with-pinboards)
describes named/color-coded collections, pinning from history, rearranging and
moving items, and preservation after history expires. Read-only inspection of
Paste 6.6.10 (29788902)'s shipped English localization corroborated creation,
context-menu/drag pinning and history-independent retention. No personal Paste
items were read, and no Paste assets or code were copied.

Cliprill adopts permanent named/color-coded collections while keeping its compact
pointer-local AppKit panel. Direct text entry and preview masking suit personal
form snippets. Unlike Paste, this release uses independent copies, current-board
search and menu-based ordering; it does not include cloud sharing, synchronization,
or drag-and-drop organization.
