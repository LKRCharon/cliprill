# UI and interaction decisions

Approved 2026-09-15. Preserve the working queue workflow while updating the native AppKit interface.

## Queue workflow

- **Shift–Command–V** opens Cliprill near the pointer. Migrate only the original Control–Option–V default; preserve customized shortcuts.
- Switching from History to Queue starts the selected nonempty queue. Selecting another queue pauses the previous one and starts the selected one.
- The Queue panel stays visible when another app receives focus. Its blank top edge can be dragged. Clicking another app releases the panel's key status.
- Each ordinary **Command–V** in the destination dispatches one FIFO item and commits one dequeue. Returning to History pauses the queue.
- Refreshing or filtering never restarts a manually or automatically paused queue. Search never changes order or the real next item.
- Closing the panel leaves the background service running. Restart recovery is paused. External copies and Secure Input retain their existing safety behavior.
- Enter pastes a History item and previews a Queue item. Option–Enter enqueues a History item. Command–Y previews; Command–1/2 changes History/Queue.
- Escape belongs to an active IME composition first, then closes a preview, clears a query, or closes the panel. Space in the search field remains text.
- Text and captured images can share a queue. Image rows show thumbnails and dimensions; Enter pastes an image from History or previews it in Queue. Clearing history preserves queued images. See [image support](IMAGES.md).

## Visual implementation

The 420 pt native floating panel has a 14 pt draggable top strip, a 38 pt search surface, one mode row, a 52 pt item list, and one footer. Low-frequency actions live in the top menu and each row's context menu. The footer shows queue state, remaining count and one relevant action.

Initial height is clamped to 300–552 pt from 160 + 52 × row count, then bounded by the screen. Opening, changing modes/queues, importing and clearing search can resize the panel. Ordinary search edits and background queue updates keep its frame stable. The first row is positioned close to the pointer.

Light appearance uses white, with neutral hover and selection. Dark appearance uses an opaque matching palette. System accent indicates keyboard focus and permission completion. Increased Contrast strengthens boundaries. Surfaces are opaque for Reduce Transparency and resizing has no decorative animation.

Controls retain native text editing and button/menu accessibility. Public Lucide 0.456.0 SVGs use a 24-unit grid, 1.75-unit stroke, 16 pt display size (18 pt in the menu bar), and 28 pt button targets. AppKit loads these vectors directly. Vendor/Lucide/manifest.json pins sources and hashes; scripts/prepare-icons.py reproduces resource copies. The full upstream ISC/Feather MIT notices ship in ThirdPartyNotices/Lucide-LICENSE. No proprietary reference assets are included.

The search icon, native input and clear button occupy separate layout regions, with an 8 pt gap between the icon and input. The input uses its native intrinsic height, centered with the icon, so placeholder text and the editing caret share the same vertical alignment. The clear button's space stays reserved when the query is empty. A single 1 pt outline follows the 38 pt search surface; keyboard focus uses the system accent and Increased Contrast raises it to 2 pt. Placeholder text uses the secondary text color. Clicking the icon or input padding focuses search instead of dragging the panel.

The list scroller has no painted track or border and uses a 6 pt rounded thumb. Dragging or Increased Contrast widens it to 8 pt and strengthens its color. Native hit areas, dragging, scrolling and overlay fading remain in AppKit; the system's Show scroll bars preference controls whether it uses overlay or always-visible presentation.

## Accessibility permission

Permission help appears when a paste or activation requires access, or from Settings. It explains the need, opens the macOS Accessibility page, and reveals the **running app bundle** in Finder when missing from the permission list. The user can drag that app into System Settings.

The guide polls AXIsProcessTrusted() while visible and checks again on focus. After permission is enabled, **Continue** returns to the requested workflow. Queue continuation checks that the user is still viewing the same queue and uses its current revision. History returns to the panel for another explicit paste. Permission completion itself never sends a paste to System Settings.

Permission changes remain in the user's macOS controls. Ad-hoc builds may require re-enabling access; if macOS still rejects the event tap, Cliprill reports the error with the existing restart hint.

## Validation boundary

Run the core suite, release packaging/signature checks and packaged MCP smoke test. This iteration deliberately avoids repeated screenshot or visual tuning sessions. Physical keyboard behavior, appearance, IME and permission completion remain for the user's trial feedback; automated core checks do not prove those interactions.
