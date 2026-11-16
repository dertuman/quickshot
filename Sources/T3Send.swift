import Cocoa

// Sends a screenshot to T3 Code as a new thread, through T3's own `t3 thread start` CLI.
// The image is written to disk and referenced by absolute path, so the agent can open it
// and T3 renders it inline. Defaults (overridable with `defaults write com.alex.quickshot ...`):
//   T3Project  project folder for the thread (default ~/Documents/GitHub, the home repo)
//   T3CLI      path to the t3 launcher (default ~/.t3/bin/t3)
final class T3Sender: NSObject, NSTextFieldDelegate {
    static var current: T3Sender?

    private let png: Data
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

    static func begin(png: Data) {
        current?.close()
        let sender = T3Sender(png: png)
        current = sender
        sender.present()
    }

    private init(png: Data) { self.png = png }

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
        if T3Sender.current === self { T3Sender.current = nil }
    }

    // MARK: Sending

    @objc private func send() {
        guard sendButton?.isEnabled == true else { return }
        let prompt = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: URL
        do { url = try writeImage() } catch {
            showError("Could not save the screenshot: \(error.localizedDescription)")
            return
        }
        let message = Self.message(prompt: prompt, image: url)
        let title = prompt.isEmpty ? "Screenshot" : String(prompt.split(separator: "\n").first ?? "Screenshot").prefix(80).description

        sendButton?.isEnabled = false
        field?.isEnabled = false
        status?.textColor = .secondaryLabelColor
        status?.stringValue = "Starting thread…"

        let cli = Self.cli, project = Self.project
        DispatchQueue.global(qos: .userInitiated).async {
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
        close()
        let threadID = Self.threadID(fromJSON: r.out)
        Self.openT3(project: Self.project, threadID: threadID)
    }

    private func showError(_ text: String) {
        status?.textColor = .systemRed
        status?.stringValue = text
        status?.toolTip = text
    }

    static func message(prompt: String, image: URL) -> String {
        let ask = prompt.isEmpty ? "Here is a screenshot. Look at it and tell me what you see, or what needs doing." : prompt
        return "\(ask)\n\n![Screenshot](\(image.path))\n\nScreenshot file: \(image.path)"
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

    static func threadID(fromJSON out: String) -> String? {
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.contains(" ") ? nil : trimmed
        }
        for key in ["threadId", "id"] { if let v = obj[key] as? String { return v } }
        if let t = obj["thread"] as? [String: Any], let v = t["id"] as? String { return v }
        return nil
    }

    static func openT3(project: String, threadID: String?) {
        // `t3 app <path>` focuses the desktop app on the project, where the new thread is on top.
        DispatchQueue.global(qos: .utility).async {
            let r = run(cli, ["app", project], stdin: nil)
            if r.code != 0 {
                DispatchQueue.main.async {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
    }

    static func run(_ path: String, _ args: [String], stdin: String?) -> (code: Int32, out: String, err: String) {
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
