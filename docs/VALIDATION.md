# Validation

Environment: macOS on arm64, Xcode 16.4, Swift 6.1.2. Tests use a separate data
directory and a QA bundle identifier; no production clipboard history is used as
a fixture.

## Automated release checks

GitHub Actions runs the Swift test suite, release packaging, strict code-signature
verification and packaged MCP integration tests on native arm64 and x86_64 macOS
15 runners with Xcode 16.4. The required `CI` check also validates workflow syntax
and requires the dependency lockfile and notices to remain unchanged by the build.
Tag releases repeat those checks and publish the artifacts from that tagged run.
These checks do not simulate a physical paste into a destination application.

The 0.2.1 tag introduced the fixed self-signed certificate configuration, but its
release jobs stopped at credential import and produced no public download assets.
0.2.2 is the first public release using that certificate. PR/main builds use a
disposable certificate and separate bundle ID. Four signing checks verify upgrade
identity and rejection of changed resources, bundle IDs and missing certificates.
The packaged app and MCP helper are both checked against the expected identity.
See [signing and upgrades](SIGNING.md) for the one-time Accessibility migration.

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

## 2026-09-16 image support

- 24 tests pass: the previous 15 core tests, five image storage/queue tests, and
  four native clipboard representation tests using private named pasteboards.
- Release build, strict/deep signature verification and the packaged MCP smoke
  test passed on the local arm64 Mac. MCP exposes 11 tools; the isolated background
  app log was empty. These results do not claim a remote CI run.
- Image tests verify mixed order, duplicate references, full pixel dimensions,
  transparency in PNG/TIFF, browser image-over-URL preference, concealed types,
  text replacement, pruning, history clearing, restart/Undo, invalid input,
  atomic append rejection and schema 1 text-data migration.
- Automated clipboard checks do not read or overwrite the user's general
  clipboard and do not dispatch a key event. Physical destination-app reception
  and visual appearance remain for user feedback.

## 2026-09-16 panel polish for 0.3.0

- The local arm64 build passes all 24 Swift tests, release packaging and the four
  signing identity/tamper checks. The packaged MCP smoke test passes with 11 tools
  using an isolated data directory and capture disabled.
- Search keeps the native editor and intrinsic line height. The list scroller
  customizes only native part drawing, preserving AppKit's tracking and overlay
  fading, and observes accessibility display changes to invalidate its custom
  colors and width immediately. No queue delivery or storage code changed.
- English and Simplified Chinese catalogs include the new clear-search label;
  both pass plutil and have matching keys.
- No additional screenshot tuning or physical keyboard/IME tests were run for
  this iteration. Automated checks do not verify the new rendered appearance.
- Both architectures run the existing protected PR checks and repeat those
  checks on the release tag before publishing their packages.

## 2026-09-17 pinboards and efficiency for 0.5.0

- Local arm64: 35 Swift tests pass. New coverage includes schema 2 migration,
  independent saved snippets, history cleanup/restart, persisted idempotency,
  stale revisions and atomic moves, invalid reordering/inputs, bounded content
  paging, and image retention until the last board reference is removed.
  An unchanged-reference-set regression test checks immediate image disposal.
  Image-capture preferences skip image payload loading while preserving plain text.
- Release packaging and four fixed-signature upgrade/tamper checks pass.
  Packaged MCP integration initializes and lists 21 tools, creates/reads/edits
  boards, verifies metadata-only reads and retry safety, and verifies saved
  snippets after an app restart. Existing queue integration checks still pass.
- The isolated `--no-capture` smoke run asserts `poll_interval_ms == 0` and
  `poll_ticks == 0`. Throughout hidden queue/board reads and writes, the list
  rebuild counter stays at its initial value. These are direct work-elimination
  checks, not claims of a measured percentage CPU or battery improvement.
- Default capture interval is now 500 ms (previously 250 ms); Fast is 200 ms and
  Low power is 1,000 ms. Active queues use 200 ms plus the unchanged per-dispatch
  clipboard/focus checks. Slower capture can miss rapidly replaced clipboard
  contents; users can choose Fast.
- English and Simplified Chinese catalogs have 137 matching keys, pass plutil,
  and resolve all literal UI localization references. Python syntax and diff
  whitespace checks pass. Tests use synthetic contents and no physical paste.
- No repeated screenshot tuning was performed. New pinboard rendering, physical
  keyboard delivery, login-item approval and real destination-app behavior await
  user feedback; build/core/MCP results do not establish those manual outcomes.
- Protected PR and tag workflows run native arm64 and Intel checks independently;
  see the actual GitHub runs for their completion status.
