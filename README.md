<p align="center">
  <img src="assets/logo.svg" width="150" alt="QuickShot logo">
</p>

# QuickShot

Press fn+⌃, drag over what you want, draw a red arrow at the thing, hit ⏎. It's in your clipboard. Instant even on multi-monitor setups, because the screen is frozen locally the moment you press the key. No account, no cloud, free forever.

## Install

You need a Mac. That's it.

**1. Install QuickShot.** Paste this in Terminal:

```
git clone https://github.com/dertuman/quickshot && cd quickshot && ./install.sh
```

This builds the app (a few seconds) and puts it in Applications. If Terminal complains about missing developer tools, run `xcode-select --install` first.

**2. Allow the two permissions** when macOS asks: **Accessibility** (to see the fn+⌃ hotkey) and **Screen Recording** (to take the shot). If you missed the prompts, go to System Settings > Privacy & Security and turn QuickShot on in both lists, then relaunch it.

**3. Press fn+⌃ and drag.** Done. Both keys sit in the bottom-left corner of the keyboard, one hand, no contortion.

## Use

- **fn+⌃** (left control) freezes all your screens under a dimmed overlay. Drag to select. Press it again to bail out, same as Esc.
- Grab the corner and edge handles to resize the selection. Your drawings stay pinned to the screen content while you do.
- **Drag inside the selection to draw** — a red arrow by default. The toolbar under the selection switches tools: **Move**, **Arrow**, **Box**.
- **⏎, ⌘C, or ⌃C** copies the annotated shot to your clipboard and closes. **Save…** (or ⌘S) writes a PNG instead. **Esc** bails out.

Keyboard while the overlay is up:

| Key | Does |
| --- | --- |
| `A` | Arrow tool |
| `B` or `R` | Box tool |
| `M` or `V` | Move tool (drag inside to reposition the selection) |
| `⌘Z` | Undo last drawing |
| `⏎` / `⌘C` / `⌃C` | Copy and close |
| `⌘S` | Save as PNG |
| `Esc` | Cancel |

Want QuickShot to start when your Mac starts? System Settings > General > Login Items, add QuickShot.

## Why

I used Lightshot for years, but on a multi-monitor setup it takes a second or two before you can even start selecting. That delay, hundreds of times a day, adds up. QuickShot does the two things I actually used — red arrows and red boxes on a region of the screen — and does them instantly.

## How it works

One Swift file. A menu bar app watches for fn+⌃ with a listen-only event tap (Carbon hotkeys can't see the fn key), snapshots every display with ScreenCaptureKit the moment you press it, and shows the frozen frames under borderless full-screen overlays. Selection, resize handles, and annotations are plain AppKit drawing on top. Copy composites the cropped region and your drawings at full Retina resolution and puts a PNG on the clipboard. Nothing ever leaves your Mac.

The build signs with your Apple Development certificate if you have one (so the Screen Recording grant survives rebuilds) and falls back to ad-hoc signing if you don't.

## License

MIT
