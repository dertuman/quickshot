import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers
import ApplicationServices
import AVFoundation

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
    var displayID: CGDirectDisplayID = 0
    var screenFrame: NSRect = .zero
    var backingScale: CGFloat = 2

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

    private var hoveredHandle: Handle?
    private var handleHover: [Handle: CGFloat] = [:]
    private var hoverTimer: Timer?
    private var pushedCursor = false

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
                drawHandle(h, at: handlePoint(h, in: sel))
            }

            drawSizeLabel(for: sel)
        } else {
            NSBezierPath(rect: bounds).fill()
        }
    }

    private func drawHandle(_ h: Handle, at p: NSPoint) {
        let t = handleHover[h] ?? 0
        let radius = 4 + 2 * t

        if t > 0.01 {
            let halo = NSRect(x: p.x - radius - 5, y: p.y - radius - 5,
                              width: (radius + 5) * 2, height: (radius + 5) * 2)
            NSColor.white.withAlphaComponent(0.18 * t).setFill()
            NSBezierPath(ovalIn: halo).fill()
        }

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        let dot = NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35 + 0.25 * t).setStroke()
        ring.stroke()
    }

    private func setHovered(_ h: Handle?) {
        guard h != hoveredHandle else { return }
        hoveredHandle = h
        startHoverAnimation()
    }

    private func startHoverAnimation() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            var settled = true
            for h in Handle.allCases {
                let target: CGFloat = (h == self.hoveredHandle) ? 1 : 0
                let current = self.handleHover[h] ?? 0
                let next = current + (target - current) * 0.3
                if abs(target - next) < 0.002 {
                    self.handleHover[h] = target
                } else {
                    self.handleHover[h] = next
                    settled = false
                }
            }
            self.needsDisplay = true
            if settled {
                t.invalidate()
                self.hoverTimer = nil
            }
        }
        if let t = hoverTimer { RunLoop.current.add(t, forMode: .eventTracking) }
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

    private static let handleHitRadius: CGFloat = 14

    private func handleRect(_ h: Handle, in r: NSRect) -> NSRect {
        let p = handlePoint(h, in: r)
        let s = Self.handleHitRadius
        return NSRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2)
    }

    private func resizeCursor(for h: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch h {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .left: position = .left
            case .right: position = .right
            case .bottomLeft: position = .bottomLeft
            case .bottom: position = .bottom
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        let selectorName: String
        switch h {
        case .topLeft, .bottomRight: selectorName = "_windowResizeNorthWestSouthEastCursor"
        case .topRight, .bottomLeft: selectorName = "_windowResizeNorthEastSouthWestCursor"
        case .left, .right: selectorName = "_windowResizeEastWestCursor"
        case .top, .bottom: selectorName = "_windowResizeNorthSouthCursor"
        }
        let sel = NSSelectorFromString(selectorName)
        if NSCursor.responds(to: sel),
           let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return c
        }
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    private func hitHandle(_ p: NSPoint, in r: NSRect) -> Handle? {
        for h in Handle.allCases {
            let hp = handlePoint(h, in: r)
            if hypot(p.x - hp.x, p.y - hp.y) <= Self.handleHitRadius { return h }
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
                setHovered(h)
                pushCursor(resizeCursor(for: h))
                toolbar?.isHidden = true
                return
            }
            if sel.contains(p) {
                if tool == .move {
                    dragMode = .moving
                    origRect = sel
                    pushCursor(.closedHand)
                    toolbar?.isHidden = true
                } else {
                    dragMode = .drawing
                }
                return
            }
        }

        // Start a fresh selection
        setHovered(nil)
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
        popCursorIfNeeded()
        let p = convert(event.locationInWindow, from: nil)
        setHovered(selection.flatMap { hitHandle(p, in: $0) })
        applyCursor(at: p)
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
        addCursorRect(bounds, cursor: .crosshair)
        guard let sel = selection, sel.width > 0, sel.height > 0 else { return }
        addCursorRect(sel, cursor: tool == .move ? .openHand : .crosshair)
        // Added last so they win the hit test against the selection body.
        for h in Handle.allCases {
            addCursorRect(handleRect(h, in: sel), cursor: resizeCursor(for: h))
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .none = dragMode else { return }
        let p = convert(event.locationInWindow, from: nil)
        setHovered(selection.flatMap { hitHandle(p, in: $0) })
        applyCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Cursor rects are unreliable on a borderless screen-saver-level window,
    /// so drive the cursor straight off the pointer position.
    private func applyCursor(at p: NSPoint) {
        guard !pushedCursor else { return }
        if let h = hoveredHandle {
            resizeCursor(for: h).set()
        } else if let sel = selection, sel.contains(p) {
            (tool == .move ? NSCursor.openHand : NSCursor.crosshair).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func pushCursor(_ cursor: NSCursor) {
        cursor.push()
        pushedCursor = true
    }

    private func popCursorIfNeeded() {
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
    }


    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        let cmdOrCtrl = mods.contains(.command) || mods.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // esc
            session?.dismiss()
        } else if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { // return / enter / space
            session?.copyAndFinish(from: self)
        } else if cmdOrCtrl && key == "c" {
            session?.copyAndFinish(from: self)
        } else if cmdOrCtrl && key == "s" {
            session?.saveAndFinish(from: self)
        } else if cmdOrCtrl && key == "z" {
            undoAnnotation()
        } else if key == "a" {
            selectTool(.arrow)
        } else if key == "b" {
            selectTool(.box)
        } else if key == "r" {
            session?.startRecording(from: self)
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
        if let loc = window?.mouseLocationOutsideOfEventStream {
            applyCursor(at: convert(loc, from: nil))
        }
    }

    func undoAnnotation() {
        _ = annotations.popLast()
        needsDisplay = true
    }

    func clearSelection() {
        setHovered(nil)
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
        let recordButton = NSButton(title: "Record", target: self, action: #selector(recordPressed))
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(savePressed))
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        let cancelButton = NSButton(title: "✕", target: self, action: #selector(cancelPressed))
        copyButton.keyEquivalent = "\r"
        for b in [undoButton, recordButton, saveButton, copyButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
        }

        let stack = NSStackView(views: [control, undoButton, recordButton, copyButton, saveButton, cancelButton])
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
    @objc private func recordPressed() { session?.startRecording(from: self) }
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

// MARK: - History

struct HistoryItem {
    let url: URL
    let date: Date
    let isVideo: Bool
}

final class HistoryStore {
    static let shared = HistoryStore()
    private static let enabledKey = "HistoryEnabled"
    private static let maxItems = 100

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("QuickShot/History", isDirectory: true)
    }

    private func makeURL(prefix: String, ext: String) -> URL {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(prefix) \(df.string(from: Date()))"
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    func saveImage(_ png: Data) {
        guard isEnabled else { return }
        try? png.write(to: makeURL(prefix: "Screenshot", ext: "png"))
        prune()
    }

    func saveVideo(at source: URL) {
        guard isEnabled else { return }
        try? FileManager.default.copyItem(at: source, to: makeURL(prefix: "Recording", ext: "mp4"))
        prune()
    }

    func items() -> [HistoryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: [.creationDateKey],
                                                    options: .skipsHiddenFiles) else { return [] }
        return urls.compactMap { url -> HistoryItem? in
            let ext = url.pathExtension.lowercased()
            guard ext == "png" || ext == "mp4" else { return nil }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return HistoryItem(url: url, date: date, isVideo: ext == "mp4")
        }.sorted { $0.date > $1.date }
    }

    func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: item.url)
    }

    func clear() {
        for item in items() { delete(item) }
    }

    private func prune() {
        let all = items()
        guard all.count > Self.maxItems else { return }
        for item in all[Self.maxItems...] { delete(item) }
    }
}

// MARK: - History window

final class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static var shared: HistoryWindowController?

    private var window: NSWindow!
    private var tableView: NSTableView!
    private var previewView: NSImageView!
    private var infoLabel: NSTextField!
    private var copyButton: NSButton!
    private var revealButton: NSButton!
    private var deleteButton: NSButton!
    private var emptyLabel: NSTextField!
    private var items: [HistoryItem] = []
    private var thumbnails: [URL: NSImage] = [:]

    static func show() {
        if shared == nil { shared = HistoryWindowController() }
        shared?.present()
    }

    override init() {
        super.init()
        buildWindow()
    }

    private func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "History"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 360)
        win.center()
        win.delegate = self
        window = win

        let content = NSView()
        win.contentView = content

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        let table = NSTableView()
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(copySelected)
        table.target = self
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyDown
        preview.imageFrameStyle = .none
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        preview.layer?.cornerRadius = 8
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewView = preview
        content.addSubview(preview)

        let info = NSTextField(labelWithString: "")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byWordWrapping
        info.maximumNumberOfLines = 3
        info.translatesAutoresizingMaskIntoConstraints = false
        infoLabel = info
        content.addSubview(info)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copySelected))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copyButton = copy
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealSelected))
        reveal.bezelStyle = .rounded
        revealButton = reveal
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        delete.bezelStyle = .rounded
        deleteButton = delete
        let buttons = NSStackView(views: [copy, reveal, delete])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        let empty = NSTextField(labelWithString: "No captures yet")
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel = empty
        content.addSubview(empty)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 280),

            preview.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),

            info.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            info.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),

            buttons.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    func reload() {
        let selectedURL = selectedItem()?.url
        items = HistoryStore.shared.items()
        thumbnails = thumbnails.filter { pair in items.contains { $0.url == pair.key } }
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        if let selectedURL, let idx = items.firstIndex(where: { $0.url == selectedURL }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateDetail()
    }

    private func selectedItem() -> HistoryItem? {
        let row = tableView?.selectedRow ?? -1
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    private func thumbnail(for item: HistoryItem) -> NSImage? {
        if let cached = thumbnails[item.url] { return cached }
        var image: NSImage?
        if item.isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                image = NSImage(cgImage: cg, size: .zero)
            }
        } else {
            image = NSImage(contentsOf: item.url)
        }
        if let image { thumbnails[item.url] = image }
        return image
    }

    private func updateDetail() {
        guard let item = selectedItem() else {
            previewView.image = nil
            infoLabel.stringValue = ""
            for b in [copyButton, revealButton, deleteButton] { b?.isEnabled = false }
            return
        }
        for b in [copyButton, revealButton, deleteButton] { b?.isEnabled = true }
        previewView.image = thumbnail(for: item)

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var parts = [df.string(from: item.date)]
        if let image = previewView.image, let rep = image.representations.first, rep.pixelsWide > 0 {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh) px")
        }
        if let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if item.isVideo { parts.append("MP4 (copies as a file)") }
        infoLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    @objc private func copySelected() {
        guard let item = selectedItem() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isVideo {
            pb.writeObjects([item.url as NSURL])
        } else if let png = try? Data(contentsOf: item.url), let image = NSImage(data: png) {
            pb.writeObjects([image])
            pb.setData(png, forType: .png)
        }
    }

    @objc private func revealSelected() {
        guard let item = selectedItem() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem() else { return }
        HistoryStore.shared.delete(item)
        reload()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let item = items[row]
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 4
            iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 72),
                iv.heightAnchor.constraint(equalToConstant: 48),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.imageView?.image = thumbnail(for: item)
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        cell.textField?.stringValue = (item.isVideo ? "🎬 " : "") + df.string(from: item.date)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }
}

// MARK: - Recording

final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4)
        path.lineWidth = 3
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

@available(macOS 15.0, *)
final class RecordingSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static var current: RecordingSession?

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect  // display-local points, origin top-left
    private let pixelSize: CGSize
    private let borderWindow: NSWindow
    private let fileURL: URL
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var stopping = false
    private var finalized = false

    static func begin(displayID: CGDirectDisplayID, sourceRect: CGRect,
                      pixelSize: CGSize, globalRegion: NSRect) {
        guard current == nil else { return }
        let session = RecordingSession(displayID: displayID, sourceRect: sourceRect,
                                       pixelSize: pixelSize, globalRegion: globalRegion)
        current = session
        session.start()
    }

    private init(displayID: CGDirectDisplayID, sourceRect: CGRect,
                 pixelSize: CGSize, globalRegion: NSRect) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        fileURL = desktop.appendingPathComponent("Recording \(df.string(from: Date())).mp4")

        // The border sits entirely outside the recorded region so it never
        // appears in the video.
        let frame = globalRegion.insetBy(dx: -6, dy: -6)
        borderWindow = NSWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        borderWindow.isOpaque = false
        borderWindow.backgroundColor = .clear
        borderWindow.hasShadow = false
        borderWindow.level = .screenSaver
        borderWindow.ignoresMouseEvents = true
        borderWindow.isReleasedWhenClosed = false
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderWindow.animationBehavior = .none
        borderWindow.contentView = RecordingBorderView()
        super.init()
    }

    private func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let display = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                DispatchQueue.main.async { self.fail(error) }
                return
            }
            do {
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = self.sourceRect
                cfg.width = Int(self.pixelSize.width)
                cfg.height = Int(self.pixelSize.height)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                cfg.showsCursor = true
                let filter = SCContentFilter(display: display, excludingWindows: [])

                let recCfg = SCRecordingOutputConfiguration()
                recCfg.outputURL = self.fileURL
                recCfg.outputFileType = .mp4
                recCfg.videoCodecType = .h264
                let output = SCRecordingOutput(configuration: recCfg, delegate: self)

                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addRecordingOutput(output)
                self.stream = stream
                self.recordingOutput = output
                stream.startCapture { err in
                    DispatchQueue.main.async {
                        if let err { self.fail(err) } else { self.didStart() }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }

    private func didStart() {
        borderWindow.orderFrontRegardless()
        AppDelegate.shared?.setRecording(true)
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        stream?.stopCapture { _ in
            // didFinishRecording normally lands first; this is the backstop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.finishRecording() }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.finishRecording() }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { self.fail(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            if !self.stopping { self.fail(error) }
        }
    }

    private func finishRecording() {
        guard !finalized else { return }
        finalized = true
        borderWindow.orderOut(nil)
        AppDelegate.shared?.setRecording(false)
        RecordingSession.current = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
        HistoryStore.shared.saveVideo(at: fileURL)
        HistoryWindowController.shared?.reload()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func fail(_ error: Error?) {
        guard !finalized else { return }
        finalized = true
        borderWindow.orderOut(nil)
        AppDelegate.shared?.setRecording(false)
        RecordingSession.current = nil
        let alert = NSAlert()
        alert.messageText = "Recording failed"
        alert.informativeText = error?.localizedDescription ?? "Unknown error"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
            win.animationBehavior = .none
            win.acceptsMouseMovedEvents = true
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
            view.session = self
            view.displayID = displayID
            view.screenFrame = screen.frame
            view.backingScale = screen.backingScaleFactor
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
        HistoryStore.shared.saveImage(png)
        HistoryWindowController.shared?.reload()
        dismiss()
    }

    func startRecording(from view: OverlayView) {
        guard #available(macOS 15.0, *) else {
            dismiss()
            let alert = NSAlert()
            alert.messageText = "Recording needs macOS 15 or newer"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        guard let sel = view.selection, sel.width >= 5, sel.height >= 5 else { return }
        let scale = view.backingScale
        // SCStream wants the region in display-local points with a top-left origin.
        let sourceRect = CGRect(x: sel.minX, y: view.bounds.height - sel.maxY,
                                width: sel.width, height: sel.height)
        // H.264 needs even pixel dimensions.
        let pw = max(2, Int(sel.width * scale) & ~1)
        let ph = max(2, Int(sel.height * scale) & ~1)
        let globalRegion = NSRect(x: view.screenFrame.origin.x + sel.minX,
                                  y: view.screenFrame.origin.y + sel.minY,
                                  width: sel.width, height: sel.height)
        let displayID = view.displayID
        dismiss()
        RecordingSession.begin(displayID: displayID, sourceRect: sourceRect,
                               pixelSize: CGSize(width: pw, height: ph),
                               globalRegion: globalRegion)
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
            HistoryStore.shared.saveImage(png)
            HistoryWindowController.shared?.reload()
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
    // Device-dependent modifier bit from IOLLEvent.h, the one that distinguishes sides.
    private static let leftControlMask: UInt64 = 0x0001  // NX_DEVICELCTLKEYMASK

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
        let fnDown = flags.contains(.maskSecondaryFn)
        let ctrlDown = flags.rawValue & Self.leftControlMask != 0
        let active = fnDown && ctrlDown
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
    private var captureMenuItem: NSMenuItem?
    private var keepHistoryMenuItem: NSMenuItem?
    private var hotKey: ChordHotKey?
    private var retryTimer: Timer?
    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "QuickShot")
        }
        let menu = NSMenu()
        menu.delegate = self
        let captureItem = NSMenuItem(title: "Capture Area (fn+⌃)",
                                     action: #selector(captureFromMenu),
                                     keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        captureMenuItem = captureItem
        let historyItem = NSMenuItem(title: "History…",
                                     action: #selector(showHistory),
                                     keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let keepItem = NSMenuItem(title: "Keep History",
                                  action: #selector(toggleHistory),
                                  keyEquivalent: "")
        keepItem.target = self
        menu.addItem(keepItem)
        keepHistoryMenuItem = keepItem
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

    @objc func showHistory() {
        HistoryWindowController.show()
    }

    @objc func toggleHistory() {
        HistoryStore.shared.isEnabled.toggle()
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setRecording(_ on: Bool) {
        isRecording = on
        if let button = statusItem?.button {
            if on {
                button.image = NSImage(systemSymbolName: "stop.circle.fill",
                                       accessibilityDescription: "Stop recording")
                button.contentTintColor = .systemRed
            } else {
                button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                       accessibilityDescription: "QuickShot")
                button.contentTintColor = nil
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        captureMenuItem?.title = isRecording ? "Stop Recording (fn+⌃)" : "Capture Area (fn+⌃)"
        keepHistoryMenuItem?.state = HistoryStore.shared.isEnabled ? .on : .off
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
        // The same chord toggles: stop a recording, or dismiss the overlay, like Esc.
        if #available(macOS 15.0, *), let recording = RecordingSession.current {
            recording.stop()
            return
        }
        if let session = CaptureSession.current {
            session.dismiss()
        } else {
            CaptureSession.begin()
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
