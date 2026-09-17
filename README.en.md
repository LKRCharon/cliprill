# Cliprill

[简体中文](README.md) · **English**

[![Release](https://img.shields.io/github/v/release/LKRCharon/cliprill)](https://github.com/LKRCharon/cliprill/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/LKRCharon/cliprill/releases/latest)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue)](LICENSE)

**Find what you copied, keep frequently used snippets handy, and paste a list in order.**

Cliprill is a free, open-source clipboard manager for macOS, with support for text and images. It lives in your menu bar and opens near your pointer. The interface is available in English and Simplified Chinese.

[**Download the latest version →**](https://github.com/LKRCharon/cliprill/releases/latest)

## Three ways to use it

| What you want to do | How it works | Default shortcut |
| --- | --- | --- |
| Find copied text, links or screenshots | **History**: search, preview, then press Return or double-click to paste | ⇧⌘C |
| Fill several fields or paste multiple snippets | **Queue**: each ⌘V pastes and removes the next item | ⇧⌘V |
| Reuse emails, addresses or work experience summaries | **Pinboards**: organize by name and color; pasting keeps the item | ⇧⌘B |

⇧ means Shift and ⌘ means Command. You can change all three shortcuts in Settings.

## Install

Requires **macOS 14 or later**. Supports Apple Silicon and Intel Macs.

1. Download the ZIP for your Mac from [Releases](https://github.com/LKRCharon/cliprill/releases/latest): `macOS-arm64` for M-series chips, or `macOS-x86_64` for Intel.
2. Unzip it, move **Cliprill.app** to **Applications**, and open it.
3. When you first use automatic pasting, follow the app's guide to allow Cliprill in **System Settings → Privacy & Security → Accessibility**.

Current releases use a fixed self-signed certificate and are not Apple-notarized. If macOS blocks the first launch, confirm you downloaded it from this repository, then use **System Settings → Privacy & Security → Open Anyway**.

## Find something you copied

Copy text or an image normally, then press **⇧⌘C** to open History. Search for a keyword, select an item, and press Return or double-click to paste it into the app you were using.

Click an item and pause briefly to preview it automatically (disable this in Settings). Hidden saved items never open automatically. Press **⌘Y** or use the context menu to preview full text or an image. Images retain their original pixel dimensions and transparency; the receiving app needs to support image pasting.

## Paste in order

When filling a form, prepare the values in a queue and paste them one at a time.

1. Click **＋** beside a History item to add it to the queue. You can also create a queue from the **⋯** menu and enter text directly, keeping it whole or choosing to split it by lines.
2. Press **⇧⌘V** to open Queue. The selected nonempty queue starts, and the panel stays visible.
3. Click the destination input in another app. Each **⌘V** pastes and removes the next item.

For example, a queue containing `A, A, B` pastes `A`, `A`, then `B` on three presses. Duplicates are kept, and text and images can share a queue.

Empty queues are automatically deleted after pasting or removing the last item by default. Turn this off in Settings → Queue to keep completed queues and restore the last dispatched item. Enabling the setting also removes existing empty queues.

Switching to History or Pinboards, or copying something else, pauses the queue. Closing the panel alone does not pause it. Use the menu to reorder or remove items, or restore the last dispatched item. Restoring an item does not undo text already pasted into another app.

## Keep frequently used information

Press **⇧⌘B** to open Pinboards. Create a board from the **⋯** menu and choose a name and color, such as “Personal details,” “Work experience,” or “Project summaries.”

- Right-click a History item and choose **Pin to board** to save text or an image.
- Add longer text directly and give it a short label for easy searching and editing.
- Reorder items or move them to another board.
- Press Return or double-click to paste. The item stays, even if you clear History.

You can hide previews for individual sensitive items, or turn off all saved-item previews in Settings. **Hiding a preview is not encryption**: opening a full preview, editing, or explicitly requesting content through an authorized MCP client can still reveal the original.

## Make it yours

Open Settings from **⋯** or by right-clicking the menu-bar icon. You can adjust:

- All three global shortcuts and startup at login.
- Whether to record the clipboard and save images.
- History capacity, retention and excluded apps.
- Automatic deletion of empty queues (on by default).
- Fast / Balanced / Low power capture speed and saved-item previews.

## Privacy and common questions

**Where is my content saved?** Text, images and source-app names stay on your Mac. There is no telemetry or cloud sync. You can pause capture and exclude apps in Settings. Sensitive information copied as ordinary text cannot always be detected automatically; pause capture before copying it if needed.

**Can an AI tool help prepare a queue?** Yes. Copy the MCP configuration from Settings into a compatible client to manage queues and pinboards. Connected clients can read clipboard history and request saved content, so connect only clients you trust. See the [MCP guide](docs/MCP.md) for setup.

**Why didn't a paste work?** Check Accessibility permission and make sure the destination input has focus. Sequential paste uses ordinary **⌘V**; choosing Paste from a context menu does not advance the queue. If the destination misses a paste and the queue still exists, restore the last item and retry. When a queue is deleted after its final paste, that pasted content remains on the system clipboard, so you can press ⌘V again.

**What content is supported?** Plain text and images. Rich-text formatting, Finder file transfers and full animated-image playback are not currently supported.

**Do upgrades need permission again?** Official releases from 0.2.2 onward retain the signing identity. When upgrading from 0.2.0 or earlier, remove the old Accessibility entry, then add and enable Cliprill from Applications again. Version 0.5 upgrades the data format. If you need a downgrade path, quit Cliprill and back up `~/Library/Application Support/Cliprill` first; a downgrade requires both the old app and the backed-up data.

## Feedback and contributing

[Report a problem or suggest an improvement](https://github.com/LKRCharon/cliprill/issues) in English or Chinese. Keep real identity numbers, passwords and private clipboard contents out of screenshots and examples. Report security vulnerabilities [privately](SECURITY.md).

Want to build or improve Cliprill? Start with the [developer guide](docs/DEVELOPMENT.md) and [contribution guide](CONTRIBUTING.md).

Cliprill is open source under [AGPL-3.0-only](LICENSE).
