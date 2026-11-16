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
- **Drag inside the selection to draw**: a red arrow by default. The toolbar under the selection switches tools: **Move**, **Arrow**, **Box**.
- **Slam the spacebar** (or ⏎, ⌘C, ⌃C) and the annotated shot is on your clipboard. The whole thing is fn+⌃, drag, space. **Save…** (or ⌘S) writes a PNG instead. **Esc** bails out.
- **Send to T3** (`T` or the **T3** button) starts a new [T3 Code](https://t3.codes) thread with the screenshot attached, in `~/Documents/GitHub` by default. Change the folder with `defaults write com.alex.quickshot T3Project /path/to/project`.
- **History** keeps your last 100 captures (screenshots and recordings). Open **History…** from the menu bar icon, click any shot to preview it, and hit **Copy** (or ⏎, or double-click) to put it back on your clipboard, ready to paste anywhere. Toggle **Keep History** in the menu to turn it off; nothing is stored while it's off.
- **Record** (or R) records the selected region instead: a thin red border marks it, the menu bar icon becomes a red stop button, and fn+⌃ (or clicking it) stops. The MP4 lands on your Desktop with the file already on your clipboard, ready to paste into Slack or wherever. 60 fps, H.264, no audio, tiny files.

Keyboard while the overlay is up:

| Key | Does |
| --- | --- |
| `A` | Arrow tool |
| `B` | Box tool |
| `R` | Record the selection as MP4 |
| `T` | Send to T3 Code as a new thread (optional prompt, then it opens the thread) |
| `M` or `V` | Move tool (drag inside to reposition the selection) |
| `⌘Z` | Undo last drawing |
| `space` / `⏎` / `⌘C` / `⌃C` | Copy and close |
| `⌘S` | Save as PNG |
| `Esc` | Cancel |

Want QuickShot to start when your Mac starts? System Settings > General > Login Items, add QuickShot.

## Why

Every screenshot tool I tried either lags the moment you plug in a second monitor or buries screen recording under a pile of settings. You point at things and you record things hundreds of times a day; that should cost zero seconds and zero clicks of setup. QuickShot does exactly those two things, the instant you press the key.

## How it works

One Swift file. A menu bar app watches for fn+⌃ with a listen-only event tap (Carbon hotkeys can't see the fn key), snapshots every display with ScreenCaptureKit the moment you press it, and shows the frozen frames under borderless full-screen overlays. Selection, resize handles, and annotations are plain AppKit drawing on top. Copy composites the cropped region and your drawings at full Retina resolution and puts a PNG on the clipboard. Record streams just the selected region through ScreenCaptureKit into a hardware-encoded H.264 MP4 (frames are only emitted when pixels change, so files stay small). Nothing ever leaves your Mac.

Recording needs macOS 15 or newer; screenshots work further back.

The build signs with your Apple Development certificate if you have one (so the Screen Recording grant survives rebuilds) and falls back to ad-hoc signing if you don't.

## License

MIT

## Automatic recording controls

The running app accepts local, same-user recording commands. Build and install the
updated app once. The client is bundled at
`/Applications/QuickShot.app/Contents/Resources/quickshotctl` (also `bin/quickshotctl`
in the repository). It requires Python 3. Existing macOS Screen Recording
permission still applies; the controls do not request or bypass permissions.

```bash
bin/quickshotctl sources
bin/quickshotctl status
bin/quickshotctl start --window 4205 --insets 87 0 0 0 --output /absolute/path/demo.mp4
bin/quickshotctl mark 'clicked Run tests'
bin/quickshotctl stop
```

Choose the actual window ID from `sources`; IDs change between sessions.
`--insets` means **top, right, bottom, left** in logical screen points. The example
removes 87 points of browser chrome; inspect the current window before choosing
insets. Alternatively use `--display ID --rect X Y WIDTH HEIGHT`, in display-local
top-left coordinates. The whole region must fit one display.

This records the visible **display region**, so keep the intended window in place
and unobscured until `stop`. It captures the cursor but no audio. Automatic
recordings do not change the clipboard, open Finder, or add to capture history.
Manual selection and recording retain their existing behavior.

Every command emits JSON and returns nonzero on failure. `start` confirms the
stream started; `stop` waits for the recording output to finish writing the MP4.
Existing output files are never overwritten. `status` reports recording state,
path and elapsed time; `mark` stores approximate elapsed timestamps in the
adjacent `demo.mp4.markers.json` file for editing. Markers are recorded from stream
start confirmation, so inspect nearby frames for exact cuts.

The controls use a private `0700` mailbox in
`~/Library/Application Support/QuickShot/Control`, with `0600` request files,
owner checks and expiring requests. There is no network listener. Keep the
updated app running. A timeout is an uncertain outcome: inspect `status` before
retrying `start` or `stop`. `--timeout SECONDS` precedes the command (default 45,
maximum 300). `sources` lists available display and window metadata.

Client protocol checks: `python3 -m unittest discover -s tests -v`.
