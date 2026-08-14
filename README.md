<p align="center">
  <img src="assets/logo.svg" width="150" alt="QuickShot logo">
</p>

<h1 align="center">QuickShot</h1>

<p align="center"><b>Snap it. Arrow it. Paste it. Or record it.<br>One key. Zero waiting.</b></p>

Press fn+⌃ and your screen freezes instantly, all monitors at once. Drag over what matters, drop a red arrow on it, hit ⏎. It's on your clipboard before your brain catches up. Need motion? Hit **Record** and the same selection becomes a featherweight MP4, ready to paste anywhere. No OBS, no setup screens, no account, no cloud. Free forever.

## Install

Paste this in Terminal:

```
curl -fsSL https://raw.githubusercontent.com/dertuman/quickshot/main/install.sh | bash
```

Allow **Accessibility** and **Screen Recording** when macOS asks (that's how it sees the hotkey and takes the shot). Then press fn+⌃ and drag. That's it.

Prefer building from source? `git clone https://github.com/dertuman/quickshot && cd quickshot && ./build.sh` (needs the Xcode Command Line Tools).

## Use

- **fn+⌃** (left control) freezes all your screens under a dimmed overlay. Drag to select. Press it again to bail out, same as Esc.
- Grab the corner and edge handles to resize the selection. Your drawings stay pinned to the screen content while you do.
- **Drag inside the selection to draw** — a red arrow by default. The toolbar under the selection switches tools: **Move**, **Arrow**, **Box**.
- **⏎, ⌘C, or ⌃C** copies the annotated shot to your clipboard and closes. **Save…** (or ⌘S) writes a PNG instead. **Esc** bails out.
- **Record** (or R) records the selected region instead: a thin red border marks it, the menu bar icon becomes a red stop button, and fn+⌃ (or clicking it) stops. The MP4 lands on your Desktop with the file already on your clipboard, ready to paste into Slack or wherever. 60 fps, H.264, no audio, tiny files.

Keyboard while the overlay is up:

| Key | Does |
| --- | --- |
| `A` | Arrow tool |
| `B` | Box tool |
| `R` | Record the selection as MP4 |
| `M` or `V` | Move tool (drag inside to reposition the selection) |
| `⌘Z` | Undo last drawing |
| `⏎` / `⌘C` / `⌃C` | Copy and close |
| `⌘S` | Save as PNG |
| `Esc` | Cancel |

Want QuickShot to start when your Mac starts? System Settings > General > Login Items, add QuickShot.

## Why

I used Lightshot for years, but on a multi-monitor setup it takes a second or two before you can even start selecting. That delay, hundreds of times a day, adds up. QuickShot does the two things I actually used — red arrows and red boxes on a region of the screen — and does them instantly.

## How it works

One Swift file. A menu bar app watches for fn+⌃ with a listen-only event tap (Carbon hotkeys can't see the fn key), snapshots every display with ScreenCaptureKit the moment you press it, and shows the frozen frames under borderless full-screen overlays. Selection, resize handles, and annotations are plain AppKit drawing on top. Copy composites the cropped region and your drawings at full Retina resolution and puts a PNG on the clipboard. Record streams just the selected region through ScreenCaptureKit into a hardware-encoded H.264 MP4 (frames are only emitted when pixels change, so files stay small). Nothing ever leaves your Mac.

Recording needs macOS 15 or newer; screenshots work further back.

The build signs with your Apple Development certificate if you have one (so the Screen Recording grant survives rebuilds) and falls back to ad-hoc signing if you don't.

## License

MIT
