import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers
import ApplicationServices

// MARK: - Annotations

enum Tool: Int {
    case move = 0
    case arrow = 1
    case box = 2
}

enum Annotation {
    case arrow(from: NSPoint, to: NSPoint)
    case box(rect: NSRect)
}

func drawAnnotation(_ a: Annotation) {
    let color = NSColor.systemRed
    color.set()
    switch a {
    case .arrow(let from, let to):
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let head: CGFloat = min(20, max(10, len * 0.25))
        let angle = atan2(dy, dx)
        let back = NSPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.move(to: from)
        path.line(to: back)
        path.stroke()
        let spread: CGFloat = .pi / 7
        let p1 = NSPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head)
        let p2 = NSPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head)
        let tri = NSBezierPath()
        tri.move(to: to)
        tri.line(to: p1)
        tri.line(to: p2)
        tri.close()
        tri.fill()
    case .box(let rect):
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = 4
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay view (one per screen)

final class OverlayView: NSView {
    weak var session: CaptureSession?
    let screenImage: CGImage

    var selection: NSRect?
    var annotations: [Annotation] = []
    private var draft: Annotation?
    var tool: Tool = .arrow

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private enum DragMode {
        case none
        case creating
        case moving
        case resizing(Handle)
        case drawing
    }

    private var dragMode: DragMode = .none
    private var dragStart: NSPoint = .zero
    private var origRect: NSRect = .zero

    private var toolbar: NSView?
    private var toolControl: NSSegmentedControl?

    init(frame: NSRect, image: CGImage) {
        self.screenImage = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(screenImage, in: bounds)

        NSColor.black.withAlphaComponent(0.45).setFill()
        if let sel = selection, sel.width > 0, sel.height > 0 {
            let dim = NSBezierPath(rect: bounds)
            dim.appendRect(sel)
            dim.windingRule = .evenOdd
            dim.fill()

            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: sel).addClip()
            for a in annotations { drawAnnotation(a) }
            if let d = draft { drawAnnotation(d) }
            NSGraphicsContext.current?.restoreGraphicsState()

            let border = NSBezierPath(rect: sel)
            border.lineWidth = 1.5
            border.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()

            for h in Handle.allCases {
                let p = handlePoint(h, in: sel)
                let dot = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.black.withAlphaComponent(0.5).setStroke()
                NSBezierPath(ovalIn: dot).stroke()
            }

            drawSizeLabel(for: sel)
        } else {
            NSBezierPath(rect: bounds).fill()
        }
    }

    private func drawSizeLabel(for sel: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: "\(Int(sel.width)) × \(Int(sel.height))", attributes: attrs)
        let sz = str.size()
        var org = NSPoint(x: sel.minX, y: sel.maxY + 8)
        if org.y + sz.height + 4 > bounds.maxY { org.y = sel.maxY - sz.height - 8 }
        org.x = max(8, min(org.x, bounds.maxX - sz.width - 12))
        let bg = NSRect(x: org.x - 5, y: org.y - 3, width: sz.width + 10, height: sz.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: org)
    }

    private func handlePoint(_ h: Handle, in r: NSRect) -> NSPoint {
        switch h {
        case .topLeft: return NSPoint(x: r.minX, y: r.maxY)
        case .top: return NSPoint(x: r.midX, y: r.maxY)
        case .topRight: return NSPoint(x: r.maxX, y: r.maxY)
        case .left: return NSPoint(x: r.minX, y: r.midY)
        case .right: return NSPoint(x: r.maxX, y: r.midY)
        case .bottomLeft: return NSPoint(x: r.minX, y: r.minY)
        case .bottom: return NSPoint(x: r.midX, y: r.minY)
        case .bottomRight: return NSPoint(x: r.maxX, y: r.minY)
        }
    }

    private func hitHandle(_ p: NSPoint, in r: NSRect) -> Handle? {
        for h in Handle.allCases {
            let hp = handlePoint(h, in: r)
            if hypot(p.x - hp.x, p.y - hp.y) <= 10 { return h }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p

        if let sel = selection {
            if let h = hitHandle(p, in: sel) {
                dragMode = .resizing(h)
                origRect = sel
                toolbar?.isHidden = true
                return
            }
            if sel.contains(p) {
                if tool == .move {
                    dragMode = .moving
                    origRect = sel
                    toolbar?.isHidden = true
                } else {
                    dragMode = .drawing
                }
                return
            }
        }

        // Start a fresh selection
        session?.clearSelections(except: self)
        annotations.removeAll()
        selection = NSRect(origin: p, size: .zero)
        dragMode = .creating
        toolbar?.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .creating:
            selection = NSRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                               width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
        case .moving:
            var r = origRect.offsetBy(dx: p.x - dragStart.x, dy: p.y - dragStart.y)
            r.origin.x = max(0, min(r.origin.x, bounds.width - r.width))
            r.origin.y = max(0, min(r.origin.y, bounds.height - r.height))
            selection = r
        case .resizing(let h):
            selection = resized(origRect, handle: h, dx: p.x - dragStart.x, dy: p.y - dragStart.y)
        case .drawing:
            switch tool {
            case .arrow:
                draft = .arrow(from: dragStart, to: p)
            case .box:
                draft = .box(rect: NSRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                                          width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y)))
            case .move:
                break
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .creating:
            if let sel = selection, sel.width < 5 || sel.height < 5 {
                selection = nil
            }
        case .drawing:
            if let d = draft {
                let keep: Bool
                switch d {
                case .arrow(let f, let t): keep = hypot(t.x - f.x, t.y - f.y) > 4
                case .box(let r): keep = r.width > 4 || r.height > 4
                }
                if keep { annotations.append(d) }
            }
            draft = nil
        default:
            break
        }
        dragMode = .none
        updateToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func resized(_ r: NSRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> NSRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft: minX += dx; maxY += dy
        case .top: maxY += dy
        case .topRight: maxX += dx; maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        case .bottomLeft: minX += dx; minY += dy
        case .bottom: minY += dy
        case .bottomRight: maxX += dx; minY += dy
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    override func resetCursorRects() {
        if let sel = selection {
            addCursorRect(bounds, cursor: .crosshair)
            addCursorRect(sel, cursor: tool == .move ? .openHand : .crosshair)
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        let cmdOrCtrl = mods.contains(.command) || mods.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // esc
            session?.dismiss()
        } else if event.keyCode == 36 || event.keyCode == 76 { // return / enter
            session?.copyAndFinish(from: self)
        } else if cmdOrCtrl && key == "c" {
            session?.copyAndFinish(from: self)
        } else if cmdOrCtrl && key == "s" {
            session?.saveAndFinish(from: self)
        } else if cmdOrCtrl && key == "z" {
            undoAnnotation()
        } else if key == "a" {
            selectTool(.arrow)
        } else if key == "b" || key == "r" {
            selectTool(.box)
        } else if key == "m" || key == "v" {
            selectTool(.move)
        } else {
            super.keyDown(with: event)
        }
    }

    func selectTool(_ t: Tool) {
        tool = t
        toolControl?.selectedSegment = t.rawValue
        window?.invalidateCursorRects(for: self)
    }

    func undoAnnotation() {
        _ = annotations.popLast()
        needsDisplay = true
    }

    func clearSelection() {
        selection = nil
        annotations.removeAll()
        draft = nil
        toolbar?.isHidden = true
        needsDisplay = true
    }

    // MARK: Toolbar

    private func buildToolbar() -> NSView {
        let control = NSSegmentedControl(labels: ["Move", "Arrow", "Box"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(toolChanged(_:)))
        control.selectedSegment = tool.rawValue
        toolControl = control

        let undoButton = NSButton(title: "Undo", target: self, action: #selector(undoPressed))
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(savePressed))
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        let cancelButton = NSButton(title: "✕", target: self, action: #selector(cancelPressed))
        copyButton.keyEquivalent = "\r"
        for b in [undoButton, saveButton, copyButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
        }

        let stack = NSStackView(views: [control, undoButton, copyButton, saveButton, cancelButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        let fit = stack.fittingSize
        let pad: CGFloat = 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: fit.width + pad * 2, height: fit.height + pad * 2))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.9).cgColor
        container.layer?.cornerRadius = 9
        stack.frame = NSRect(x: pad, y: pad, width: fit.width, height: fit.height)
        container.addSubview(stack)
        addSubview(container)
        return container
    }

    func updateToolbar() {
        guard let sel = selection, sel.width >= 5, sel.height >= 5 else {
            toolbar?.isHidden = true
            return
        }
        if toolbar == nil { toolbar = buildToolbar() }
        guard let bar = toolbar else { return }
        let size = bar.frame.size
        var x = sel.maxX - size.width
        x = max(8, min(x, bounds.maxX - size.width - 8))
        var y = sel.minY - size.height - 10
        if y < 8 { y = sel.maxY + 10 }
        if y + size.height > bounds.maxY - 8 { y = sel.minY + 10 }
        bar.setFrameOrigin(NSPoint(x: x, y: y))
        bar.isHidden = false
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        tool = Tool(rawValue: sender.selectedSegment) ?? .arrow
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    @objc private func undoPressed() { undoAnnotation(); window?.makeFirstResponder(self) }
    @objc private func copyPressed() { session?.copyAndFinish(from: self) }
    @objc private func savePressed() { session?.saveAndFinish(from: self) }
    @objc private func cancelPressed() { session?.dismiss() }

    // MARK: Composite

    func renderComposite() -> NSBitmapImageRep? {
        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return nil }
        let s = CGFloat(screenImage.width) / bounds.width
        let pw = Int(round(sel.width * s))
        let ph = Int(round(sel.height * s))
        guard pw > 0, ph > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let t = NSAffineTransform()
        t.scaleX(by: s, yBy: s)
        t.translateX(by: -sel.minX, yBy: -sel.minY)
        t.concat()
        ctx.cgContext.draw(screenImage, in: CGRect(origin: .zero, size: bounds.size))
        for a in annotations { drawAnnotation(a) }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: sel.width, height: sel.height)
        return rep
    }
}

// MARK: - Capture session

final class CaptureSession {
    static var current: CaptureSession?

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []

    static func begin() {
        guard current == nil else { return }
        let session = CaptureSession()
        current = session
        session.start()
    }

    private func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content else {
                DispatchQueue.main.async { self.fail(error) }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [CGDirectDisplayID: CGImage] = [:]
            for display in content.displays {
                group.enter()
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                    cfg.width = mode.pixelWidth
                    cfg.height = mode.pixelHeight
                } else {
                    cfg.width = display.width
                    cfg.height = display.height
                }
                cfg.showsCursor = false
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { image, _ in
                    if let image {
                        lock.lock()
                        images[display.displayID] = image
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.present(images: images)
            }
        }
    }

    private func present(images: [CGDirectDisplayID: CGImage]) {
        guard !images.isEmpty else {
            fail(nil)
            return
        }
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let image = images[displayID] else { continue }
            let win = OverlayWindow(contentRect: screen.frame,
                                    styleMask: .borderless,
                                    backing: .buffered, defer: false)
            win.level = .screenSaver
            win.isOpaque = true
            win.backgroundColor = .black
            win.hasShadow = false
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
            view.session = self
            win.contentView = view
            windows.append(win)
            views.append(view)
        }
        guard !windows.isEmpty else {
            fail(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        var keyWindow = windows[0]
        for (i, screen) in NSScreen.screens.enumerated() where i < windows.count {
            if screen.frame.contains(mouse) {
                keyWindow = windows.first { $0.frame == screen.frame } ?? windows[0]
            }
        }
        for win in windows { win.orderFrontRegardless() }
        keyWindow.makeKeyAndOrderFront(nil)
        if let view = keyWindow.contentView {
            keyWindow.makeFirstResponder(view)
        }
    }

    private func fail(_ error: Error?) {
        CaptureSession.current = nil
        let alert = NSAlert()
        alert.messageText = "QuickShot couldn't capture the screen"
        var info = "Make sure QuickShot has Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then relaunch QuickShot."
        if let error { info += "\n\n\(error.localizedDescription)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func clearSelections(except view: OverlayView) {
        for v in views where v !== view {
            v.clearSelection()
        }
    }

    func copyAndFinish(from view: OverlayView) {
        guard let rep = view.renderComposite(),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        pb.setData(png, forType: .png)
        dismiss()
    }

    func saveAndFinish(from view: OverlayView) {
        guard let rep = view.renderComposite(),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        dismiss()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Screenshot \(df.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    func dismiss() {
        for win in windows {
            win.orderOut(nil)
            win.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        CaptureSession.current = nil
    }
}

// MARK: - Hotkey (modifier chords via event tap, since Carbon hotkeys can't see fn or sides)

final class ChordHotKey {
    // Device-dependent modifier bits from IOLLEvent.h, the ones that distinguish sides.
    private static let leftControlMask: UInt64 = 0x0001  // NX_DEVICELCTLKEYMASK
    private static let leftOptionMask: UInt64 = 0x0020   // NX_DEVICELALTKEYMASK

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var comboDown = false
    private let onTrigger: () -> Void

    var isActive: Bool { tap != nil }

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger

        let mask = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let hotKey = Unmanaged<ChordHotKey>.fromOpaque(userInfo!).takeUnretainedValue()
            hotKey.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        source = runLoopSource
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        let flags = event.flags
        let fnCtrl = flags.contains(.maskSecondaryFn) && flags.contains(.maskControl)
        let leftCtrlLeftOpt = flags.rawValue & Self.leftControlMask != 0
            && flags.rawValue & Self.leftOptionMask != 0
        let active = fnCtrl || leftCtrlLeftOpt
        if active && !comboDown {
            comboDown = true
            DispatchQueue.main.async { self.onTrigger() }
        } else if !active {
            comboDown = false
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var hotKeyStatusItem: NSMenuItem?
    private var hotKey: ChordHotKey?
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "QuickShot")
        }
        let menu = NSMenu()
        menu.delegate = self
        let captureItem = NSMenuItem(title: "Capture Area (fn+⌃ or ⌃+⌥)",
                                     action: #selector(captureFromMenu),
                                     keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        let statusLine = NSMenuItem(title: "", action: #selector(openAccessibilitySettings),
                                    keyEquivalent: "")
        statusLine.target = self
        menu.addItem(statusLine)
        hotKeyStatusItem = statusLine
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit QuickShot",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item

        // The event tap needs Accessibility; this shows the system prompt once.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        installHotkey()
    }

    @objc func captureFromMenu() {
        startCapture()
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if hotKey?.isActive == true {
            hotKeyStatusItem?.title = "Hotkey active"
            hotKeyStatusItem?.action = nil
        } else {
            hotKeyStatusItem?.title = "⚠️ Hotkey off — grant Accessibility…"
            hotKeyStatusItem?.action = #selector(openAccessibilitySettings)
        }
    }

    private func installHotkey() {
        let hk = ChordHotKey { AppDelegate.shared?.startCapture() }
        if hk.isActive {
            hotKey = hk
            retryTimer?.invalidate()
            retryTimer = nil
        } else if retryTimer == nil {
            // No Accessibility grant yet; keep trying so the hotkey starts
            // working the moment the user flips the toggle.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                AppDelegate.shared?.installHotkeyFromTimer()
            }
        }
    }

    private func installHotkeyFromTimer() {
        guard hotKey == nil else { return }
        installHotkey()
    }

    func startCapture() {
        CaptureSession.begin()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
