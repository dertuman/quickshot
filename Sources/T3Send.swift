import Cocoa

// Sends a screenshot to T3 Code as a new thread, through T3's own `t3 thread start` CLI.
// The image is written to disk and referenced by absolute path, so the agent can open it
// and T3 renders it inline. The message also says which app, window and page the screenshot
// was taken in, and where the project's locator thinks that is in the code, so the agent
// starts at the right file instead of searching for it.
// Defaults (overridable with `defaults write com.alex.quickshot ...`):
//   T3Project  project folder for the thread (default ~/Documents/GitHub, the home repo)
//   T3CLI      path to the t3 launcher (default ~/.t3/bin/t3)
//   T3Locator  program that maps a screenshot to code (default <T3Project>/scripts/where).
//              Called as `<locator> --image <png> [--url <page>]`. Skipped when it is missing.
final class T3Sender: NSObject, NSTextFieldDelegate {
    static var current: T3Sender?

    private let png: Data
    private let source: AppWindow?
    private var imageURL: URL?
    private var sent = false
    private let prepared = DispatchGroup()
    private let lock = NSLock()
    private var context: ScreenContext?
    private var located: String?
    private var panel: NSPanel?
    private var field: NSTextField?
    private var status: NSTextField?
    private var sendButton: NSButton?

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static var project: String {
        UserDefaults.standard.string(forKey: "T3Project")
            ?? home.appendingPathComponent("Documents/GitHub").path
    }

    static var cli: String {
        UserDefaults.standard.string(forKey: "T3CLI")
            ?? home.appendingPathComponent(".t3/bin/t3").path
    }

    static var locator: String {
        UserDefaults.standard.string(forKey: "T3Locator")
            ?? URL(fileURLWithPath: project).appendingPathComponent("scripts/where").path
    }

    static func begin(png: Data, source: AppWindow? = nil) {
        current?.close()
        let sender = T3Sender(png: png, source: source)
        current = sender
        sender.present()
        sender.prepare()
    }

    private init(png: Data, source: AppWindow?) {
        self.png = png
        self.source = source
    }

    /// Runs while the prompt is being typed: saves the image, reads what it was taken in and
    /// asks the locator where that is in the code. Send waits a moment for it, then goes without.
    private func prepare() {
        guard let url = try? writeImage() else { return }   // send() tries again and reports
        imageURL = url
        let source = self.source
        prepared.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let context = source.map(ScreenContextReader.read)
            let located = Self.locate(image: url, page: context?.page)
            self.lock.lock()
            self.context = context
            self.located = located
            self.lock.unlock()
            self.prepared.leave()
        }
    }

    // MARK: Prompt panel

    private func present() {
        let width: CGFloat = 460
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 132),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Send to T3"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let thumb = NSImageView(frame: NSRect(x: 16, y: 44, width: 64, height: 64))
        thumb.image = NSImage(data: png)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true

        let field = NSTextField(frame: NSRect(x: 92, y: 76, width: width - 108, height: 24))
        field.placeholderString = "What should the agent do with this? (optional)"
        field.delegate = self
        field.target = self
        field.action = #selector(send)

        let project = NSTextField(labelWithString: "New thread in \(Self.displayPath(Self.project))")
        project.font = .systemFont(ofSize: 11)
        project.textColor = .secondaryLabelColor
        project.frame = NSRect(x: 92, y: 52, width: width - 108, height: 16)
        project.lineBreakMode = .byTruncatingMiddle

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .systemRed
        status.frame = NSRect(x: 16, y: 14, width: width - 200, height: 16)
        status.lineBreakMode = .byTruncatingTail

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let send = NSButton(title: "Send", target: self, action: #selector(send))
        send.keyEquivalent = "\r"
        for b in [cancel, send] { b.bezelStyle = .rounded; b.sizeToFit() }
        send.frame.origin = NSPoint(x: width - 16 - send.frame.width, y: 8)
        cancel.frame.origin = NSPoint(x: send.frame.minX - 8 - cancel.frame.width, y: 8)

        for v in [thumb, field, project, status, cancel, send] { content.addSubview(v) }
        panel.contentView = content
        panel.center()

        self.panel = panel
        self.field = field
        self.status = status
        self.sendButton = send

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func cancel() { close() }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        // A screenshot that was never sent is not referenced by any thread.
        if !sent, let imageURL { try? FileManager.default.removeItem(at: imageURL) }
        if T3Sender.current === self { T3Sender.current = nil }
    }

    // MARK: Sending

    @objc private func send() {
        guard sendButton?.isEnabled == true else { return }
        let prompt = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: URL
        if let imageURL {
            url = imageURL
        } else {
            do { url = try writeImage() } catch {
                showError("Could not save the screenshot: \(error.localizedDescription)")
                return
            }
            imageURL = url
        }
        let title = prompt.isEmpty ? "Screenshot" : String(prompt.split(separator: "\n").first ?? "Screenshot").prefix(80).description

        sendButton?.isEnabled = false
        field?.isEnabled = false
        status?.textColor = .secondaryLabelColor
        status?.stringValue = "Starting thread…"

        let cli = Self.cli, project = Self.project
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.prepared.wait(timeout: .now() + 4)
            self.lock.lock()
            let context = self.context, located = self.located
            self.lock.unlock()
            let message = Self.message(prompt: prompt, image: url, context: context, located: located)
            let result = Self.run(cli, ["thread", "start", "--json", "--title", title, project, "-"], stdin: message)
            DispatchQueue.main.async { self.finish(result) }
        }
    }

    private func finish(_ r: (code: Int32, out: String, err: String)) {
        guard r.code == 0 else {
            let detail = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            showError(detail.isEmpty ? "t3 exited with status \(r.code)" : detail)
            sendButton?.isEnabled = true
            field?.isEnabled = true
            return
        }
        // Sent: the thread runs in T3 without pulling it to the front.
        sent = true
        close()
    }

    private func showError(_ text: String) {
        status?.textColor = .systemRed
        status?.stringValue = text
        status?.toolTip = text
    }

    static func message(prompt: String, image: URL, context: ScreenContext? = nil, located: String? = nil) -> String {
        let ask = prompt.isEmpty ? "Here is a screenshot. Look at it and tell me what you see, or what needs doing." : prompt
        var text = "\(ask)\n\n![Screenshot](\(image.path))\n\nScreenshot file: \(image.path)"
        if let context { text += "\nTaken in: \(context.summary)" }
        if let located {
            let tool = locator.hasPrefix(project + "/") ? String(locator.dropFirst(project.count + 1)) : locator
            text += "\n\nWhere this is in the code, from `\(tool)` run on the screenshot. "
                + "It is already done, so do not run it again. Check the file before relying on it.\n"
                + "```\n\(located)\n```"
        }
        return text
    }

    /// Asks the project's locator where the screenshot is in the code. nil when the project has
    /// no locator, it takes too long, or it exits nonzero (nothing found, or too weak a match
    /// to be worth the agent's attention: most screenshots of other things end up there).
    static func locate(image: URL, page: String?) -> String? {
        let tool = locator
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        var args = ["--image", image.path]
        if let page { args += ["--url", page] }
        let r = run(tool, args, stdin: nil, timeout: 6)
        let text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.code == 0, !text.isEmpty else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(30).joined(separator: "\n") + (lines.count > 30 ? "\n..." : "")
    }

    private func writeImage() throws -> URL {
        // ~/Pictures/QuickShot/T3: kept (threads link to it) and free of spaces, since the
        // path goes into Markdown image syntax unescaped.
        let dir = Self.home.appendingPathComponent("Pictures/QuickShot/T3", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        var url = dir.appendingPathComponent("screenshot-\(df.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("screenshot-\(df.string(from: Date()))-\(n).png")
            n += 1
        }
        try png.write(to: url, options: .atomic)
        return url
    }

    static let t3BundleID = "com.t3tools.t3code"

    /// Both ⌘ keys: bring T3 Code forward and start a new chat (its chat.new shortcut, ⌘⇧O).
    static func openNewChat() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t3BundleID) else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, _ in
            DispatchQueue.main.async { pressNewChat(app: app, deadline: Date().addingTimeInterval(5)) }
        }
    }

    private static func pressNewChat(app: NSRunningApplication?, deadline: Date) {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == t3BundleID, app?.isFinishedLaunching != false else {
            // Wait for T3 to launch (cold start) or take focus before sending the shortcut.
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pressNewChat(app: app, deadline: deadline) }
            }
            return
        }
        // A cold start needs a moment before the web view handles keys.
        let delay: TimeInterval = (app?.launchDate.map { Date().timeIntervalSince($0) < 4 } ?? false) ? 1.5 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let src = CGEventSource(stateID: .privateState)
            let keyO: CGKeyCode = 31
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyO, keyDown: down) else { continue }
                e.flags = [.maskCommand, .maskShift]
                e.postToPid(front!.processIdentifier)
            }
        }
    }

    static func run(_ path: String, _ args: [String], stdin: String?, timeout: TimeInterval? = nil) -> (code: Int32, out: String, err: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return (127, "", "T3 CLI not found at \(path). Open T3 Code once, or set it with: defaults write com.alex.quickshot T3CLI <path>")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: project)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        do { try p.run() } catch { return (126, "", error.localizedDescription) }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    private static func displayPath(_ path: String) -> String {
        path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}
