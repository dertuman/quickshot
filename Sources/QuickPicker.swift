import Cocoa

/// Hold both ⌘ keys: a small panel over the screenshot to pick where it goes. Type to filter,
/// arrows to move, ↵ or click to send, ⌘D to make the highlighted target the default.
final class QuickPicker: NSObject, NSTextFieldDelegate {
    private final class KeyPanel: NSPanel {
        var onKeyEquivalent: ((NSEvent) -> Bool)?
        override var canBecomeKey: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
        }
    }

    private final class Row: NSView {
        let target: ChatTarget
        var onHover: (() -> Void)?
        var onClick: (() -> Void)?
        var selected = false { didSet { needsDisplay = true } }
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")

        init(target: ChatTarget, isDefault: Bool, width: CGFloat) {
            self.target = target
            super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
            title.stringValue = target.label
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            var bits: [String] = []
            if target.kind == .thread { bits.append(target.project) }
            if isDefault { bits.append("Default") }
            detail.stringValue = bits.joined(separator: " · ")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.alignment = .right
            detail.sizeToFit()
            let dw = min(detail.frame.width, width * 0.4)
            detail.frame = NSRect(x: width - 12 - dw, y: 7, width: dw, height: 16)
            title.frame = NSRect(x: 12, y: 6, width: width - 36 - dw, height: 18)
            addSubview(title)
            addSubview(detail)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard selected else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        override func viewDidMoveToWindow() { refreshColors() }
        func refreshColors() {
            title.textColor = selected ? .white : .labelColor
            detail.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        }
        override func mouseEntered(with event: NSEvent) { onHover?() }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private static let width: CGFloat = 440
    private let image: NSImage?
    private let done: (ChatTarget?, NSRect?) -> Void
    private var panel: KeyPanel?
    private var field: NSTextField!
    private var imageView: NSImageView!
    private var list: NSView!
    private var rows: [Row] = []
    private var selection = 0
    private var projects: [ChatTarget] = []
    private var threads: [ChatTarget] = []
    private var defaultTarget = ChatTarget.standard
    private var finished = false

    init(image: NSImage?, done: @escaping (ChatTarget?, NSRect?) -> Void) {
        self.image = image
        self.done = done
        super.init()
        (projects, threads) = Catalog.load()
        if defaultTarget.kind == .thread, !threads.contains(defaultTarget) { threads.insert(defaultTarget, at: 0) }
        if defaultTarget.kind == .newThread, !projects.contains(defaultTarget) { projects.insert(defaultTarget, at: 0) }
    }

    func setImage(_ image: NSImage) {
        guard let imageView, !finished else { return }
        let keep = selection
        imageView.image = image
        rebuild()
        select(keep)
    }

    func show() {
        let w = Self.width
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onKeyEquivalent = { [weak self] e in self?.keyEquivalent(e) ?? false }

        let bg = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true

        field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Send to…"
        field.delegate = self

        list = NSView()
        let hint = NSTextField(labelWithString: "↵ send    ⌘D make default    esc cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.tag = 7

        for v in [imageView!, field!, list!, hint] { bg.addSubview(v) }
        panel.contentView = bg
        self.panel = panel
        rebuild()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.midY - panel.frame.height / 2 + f.height * 0.08))
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    // MARK: List

    private var candidates: [(section: String, items: [ChatTarget])] {
        let q = field?.stringValue.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if q.isEmpty {
            return [("New thread in", Array(projects.prefix(4))), ("Add to", Array(threads.prefix(6)))]
        }
        let match: (ChatTarget) -> Bool = { t in
            t.label.lowercased().contains(q) || t.project.lowercased().contains(q)
        }
        return [("New thread in", Array(projects.filter(match).prefix(3))),
                ("Add to", Array(threads.filter(match).prefix(7)))]
    }

    private func rebuild() {
        guard let panel, let bg = panel.contentView else { return }
        let w = Self.width
        list.subviews.forEach { $0.removeFromSuperview() }
        rows = []
        var y: CGFloat = 0
        var views: [(NSView, CGFloat)] = []
        for (section, items) in candidates where !items.isEmpty {
            let label = NSTextField(labelWithString: section)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            views.append((label, 22))
            for t in items {
                let row = Row(target: t, isDefault: t == defaultTarget, width: w - 16)
                let index = rows.count
                row.onHover = { [weak self] in self?.select(index) }
                row.onClick = { [weak self] in self?.choose(index) }
                rows.append(row)
                views.append((row, 30))
            }
        }
        if rows.isEmpty {
            let none = NSTextField(labelWithString: "No match")
            none.textColor = .secondaryLabelColor
            views.append((none, 30))
        }
        let listHeight = views.reduce(0) { $0 + $1.1 }
        y = listHeight
        for (v, h) in views {
            y -= h
            if v is Row { v.frame = NSRect(x: 0, y: y, width: w - 16, height: h) }
            else { v.frame = NSRect(x: 12, y: y + 3, width: w - 40, height: 16) }
            list.addSubview(v)
        }

        // Stack from the bottom: hint, list, field, image.
        let pad: CGFloat = 8
        let hintH: CGFloat = 26
        let fieldH: CGFloat = 36
        let imageH: CGFloat = imageView.image == nil ? 0 : 150
        let total = hintH + listHeight + pad + fieldH + (imageH > 0 ? imageH + 12 : 0) + 4
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = total
        frame.origin.y = top - total
        panel.setFrame(frame, display: true)

        if let hint = bg.viewWithTag(7) { hint.frame = NSRect(x: 14, y: 6, width: w - 28, height: 16) }
        list.frame = NSRect(x: 8, y: hintH, width: w - 16, height: listHeight)
        field.frame = NSRect(x: 16, y: hintH + listHeight + pad, width: w - 32, height: 24)
        imageView.frame = NSRect(x: 12, y: total - 12 - imageH, width: w - 24, height: imageH)

        let defaultIndex = rows.firstIndex { $0.target == defaultTarget }
        select(field.stringValue.isEmpty ? (defaultIndex ?? 0) : 0)
    }

    private func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        selection = max(0, min(rows.count - 1, i))
        for (n, r) in rows.enumerated() { r.selected = n == selection; r.refreshColors() }
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(selection + 1)
        case #selector(NSResponder.moveUp(_:)): select(selection - 1)
        case #selector(NSResponder.insertNewline(_:)): choose(selection)
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        default: return false
        }
        return true
    }

    private func keyEquivalent(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.modifierFlags.contains(.command),
              e.charactersIgnoringModifiers?.lowercased() == "d", rows.indices.contains(selection) else { return false }
        defaultTarget = rows[selection].target
        ChatTarget.standard = defaultTarget
        let keep = selection
        rebuild()
        select(keep)
        return true
    }

    // MARK: Finish

    private func choose(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        finish(rows[i].target)
    }

    private func finish(_ target: ChatTarget?) {
        guard !finished, let panel else { return }
        finished = true
        // Where the screenshot sits on screen, so it can fly from there.
        var from: NSRect?
        if let img = imageView.image, imageView.frame.height > 0 {
            let box = imageView.frame
            let s = min(box.width / img.size.width, box.height / img.size.height)
            let size = NSSize(width: img.size.width * s, height: img.size.height * s)
            let local = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
            from = panel.convertToScreen(local)
        }
        panel.orderOut(nil)
        self.panel = nil
        done(target, from)
    }
}
