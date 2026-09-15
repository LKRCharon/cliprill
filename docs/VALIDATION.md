# Validation

Environment: macOS on arm64, Xcode 16.4, Swift 6.1.2. Tests use a separate data
directory and a QA bundle identifier; no production clipboard history is used as
a fixture.

## Automated release checks

GitHub Actions runs the 15 Swift tests, release packaging, strict ad-hoc signature
verification and packaged MCP integration tests on native arm64 and x86_64 macOS
15 runners with Xcode 16.4. The required `CI` check also validates workflow syntax
and requires the dependency lockfile and notices to remain unchanged by the build.
Tag releases repeat those checks and publish the artifacts from that tagged run.
These checks do not simulate a physical paste into a destination application.

## Original 0.1.0 verification

- 15 Swift tests pass. Coverage includes FIFO, duplicate entries, multiline/empty
  text, transaction rollback on invalid append, idempotency retries/conflicts,
  persisted receipts, paused restart recovery, reservations, stale revisions,
  reordering, undo, queue deletion, independent history retention, bounded JSON
  paging, exclusive instance ownership, and the real Unix socket round trip.
- The packaged helper completes an MCP initialize exchange and lists 11 tools.
  Integration checks cover create/get/append/reorder, text omission by default,
  idempotency conflict, invalid revision, history paging, closed-panel operation,
  and app restart. The repeatable driver is `scripts/smoke-mcp.py`.
- A physical keyboard test in TextEdit produced the following document in order:

  ```text
  Cliprill QA
  A
  A
  B
  第二行
  https://example.com
  ```

  The queue reported `cursor: 4`, `remaining: 0`, `state: completed`. The duplicated
  A entries consumed separately; the two-line B entry consumed once. A prior test
  interrupted by a separate copy paused with its remaining entries preserved.
- Native light/dark screenshots showed the Chinese empty-history state and the
  populated queue, including ordering, next-item label and toolbar controls.
  UI actions verified whole-text import, explicit line splitting with duplicates,
  append, full-text preview, search, item movement, queue menu and settings.
- The release bundle passed the MCP integration driver. Cold-starting its helper
  launched the native app with the window closed and created a paused queue through
  IPC. The QA no-capture flag propagated correctly across the background launch.
- The app bundle passes ad-hoc code-signature verification, with localized resources
  inside the signed Resources directory.

Physical keyboard QA used a bundle with Accessibility access. A normal launch of
the release app requires separate permission for the actual Cliprill bundle in
System Settings. Queue creation and MCP reads work without that permission.

## Scope still to test

- Repeated physical-keyboard runs in browser inputs, code editors and more native
  forms; rapid bursts/long key holds; slow or remote target apps.
- Multiple physical displays, different scale factors, Secure Input transitions,
  Accessibility revocation, and real Chinese IME composition while searching.
- Crash/fault injection precisely between event dispatch and database commit.

Simulated application keys can bypass a global event tap, so they cannot replace
physical Command–V testing. Dispatch has no universal acknowledgement from the
receiving application.


## 2026-09-15 compact panel update

- Swift debug build and 15 core tests passed with zero failures.
- Release packaging and strict/deep ad-hoc signature verification passed.
- The packaged MCP smoke test passed: 11 tools, isolated no-capture data, no
  visible panel, restart recovery and queue mutations. The background app log
  was empty.
- English/Chinese strings pass plutil; localization keys are consistent and all
  literal UI keys resolve. Public Lucide source hashes reproduce bundled SVGs.
- Queue delivery code and core storage are unchanged in this UI iteration.
  Explicit mode navigation, persistent queue visibility and Shift–Command–V
  preserve the working behavior recorded in INTERACTIONS.md.
- No screenshot/visual tuning or physical keyboard tests were run for this
  iteration. Prior 0.1.0 screenshots and physical paste results above do not
  validate the redesigned views. Appearance, IME and the permission guide's
  actual macOS completion flow await user feedback.
