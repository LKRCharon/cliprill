# Image clipboard support

Copy an image or a screenshot to the clipboard, then open Cliprill with
Shift–Command–C. History shows a thumbnail, dimensions and size. Enter pastes it
to the destination app; Command–Y or the context menu previews it. The row's plus
button adds the complete image to a queue. Text and images retain their order,
including duplicate images, and each Command–V consumes one item.

After installing this update, copy the image again: images ignored by the older
text-only build cannot be recovered from that build's saved history.

## Representation and compatibility

- Read PNG/TIFF first, with JPEG, HEIC/HEIF, GIF, BMP and WebP accepted when the
  system decoder supports their data. An image wins over accompanying URL text.
- Normalize orientation into a full-resolution lossless PNG. Preserve alpha;
  generate a separate 128 px thumbnail for the list.
- Publish both PNG and TIFF on paste for native and browser compatibility.
  A destination must support image paste; a plain text field cannot receive pixels.
- Animated images currently become their first frame. Finder file transfer,
  rich-text attachments, OCR and PDF clipboard payloads are outside this change.
- Image processing runs off the main actor. Paste requests arriving while the
  queue head is being prepared wait for that preparation. Recheck the destination,
  clipboard change count, pause generation and input permission before dispatch.

## Local storage and migration

Schema 2 adds an SQLite image table with PNG and thumbnail blobs, keyed by a hash
of the normalized PNG. Queue/history snapshots keep small image references.
The image insert, history change and removal of unreferenced images commit in one
transaction. A queued or consumed image remains retained for future paste/Undo,
even after history is cleared. Delete the queue as well to release its references.

Schema 1 text data migrates automatically, retaining history, queue IDs, item
order and restart recovery. The old text-only binary rejects schema 2. Keep the
pre-update app and database backup together if a rollback is needed.

Limits: 128 MiB encoded input, 40 megapixels, 64 MiB normalized PNG per image;
256 MiB of history images and 256 MiB of unique queue images, plus thumbnails.
Existing history count/age and text limits still apply. SQLite reuses freed pages;
logical cleanup does not promise immediate file shrinking or forensic erasure.

MCP items accept either new text or a history_id, plus an optional label. Image
responses carry kind, dimensions and byte count. They never include base64 pixels
or a filesystem path. No external image download or arbitrary file read is added.

## Verification

The 24-test suite includes four tests on unique, private macOS pasteboards. These
verify image-over-URL capture, PNG/TIFF data, dimensions, alpha, text replacement,
and concealed-image exclusion without reading or changing the general clipboard.
Core tests cover image deduplication, metadata, pruning, mixed FIFO queues,
duplicate image references, history clearing, restart/Undo, atomic append failure,
legacy text migration and invalid image rejection. The existing text/core suite
continues to pass.

Physical Command–V into other apps and the visual appearance remain for user
feedback. This iteration does not repeat screenshot-based UI tuning.
