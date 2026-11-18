import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers
import ApplicationServices
import AVFoundation
import AVKit

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

    var selection: NSRect? { didSet { if selection != nil { hoverWindow = nil } } }
    var annotations: [Annotation] = []
    /// On-screen app windows in view coordinates, front to back, for click-to-select.
    var windowRects: [NSRect] = []
    private var hoverWindow: NSRect?
    private var pendingWindowClick: NSRect?
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
        } else if let win = hoverWindow {
            let dim = NSBezierPath(rect: bounds)
            dim.appendRect(win)
            dim.windingRule = .evenOdd
            dim.fill()
            let border = NSBezierPath(rect: win.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            NSColor.white.withAlphaComponent(0.9).setStroke()
            border.stroke()
        } else {
            NSBezierPath(rect: bounds).fill()
        }
    }

    func updateHoverWindow(at p: NSPoint) {
        let next = selection == nil ? windowRects.first { $0.contains(p) } : nil
        if next != hoverWindow {
            hoverWindow = next
            needsDisplay = true
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

        if event.clickCount == 2, let sel = selection, sel.contains(p) {
            draft = nil
            dragMode = .none
            session?.copyAndFinish(from: self)
            return
        }

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

        // Start a fresh selection. A click without a drag selects the window under it.
        pendingWindowClick = selection == nil ? (hoverWindow ?? windowRects.first { $0.contains(p) }) : nil
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
        let shift = event.modifierFlags.contains(.shift)
        switch dragMode {
        case .creating:
            selection = Self.rect(from: dragStart, to: p, square: shift)
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
                draft = .arrow(from: dragStart, to: shift ? Self.snap45(from: dragStart, to: p) : p)
            case .box:
                draft = .box(rect: Self.rect(from: dragStart, to: p, square: shift))
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
                selection = pendingWindowClick.map { $0.intersection(bounds) }
            }
            pendingWindowClick = nil
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
        updateToolbar()
        setHovered(overToolbar(p) ? nil : selection.flatMap { hitHandle(p, in: $0) })
        applyCursor(at: p)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Rect spanning two points; with `square`, the larger side wins and the drag direction is kept.
    static func rect(from a: NSPoint, to b: NSPoint, square: Bool) -> NSRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return NSRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    /// Snaps the end point to the nearest 45 degree angle, keeping the length.
    static func snap45(from a: NSPoint, to b: NSPoint) -> NSPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return NSPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
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
        if let bar = toolbar, !bar.isHidden { addCursorRect(bar.frame, cursor: .arrow) }
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
        setHovered(overToolbar(p) ? nil : selection.flatMap { hitHandle(p, in: $0) })
        updateHoverWindow(at: p)
        applyCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        if hoverWindow != nil { hoverWindow = nil; needsDisplay = true }
    }

    private func overToolbar(_ p: NSPoint) -> Bool {
        guard let bar = toolbar, !bar.isHidden else { return false }
        return bar.frame.contains(p)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Cursor rects are unreliable on a borderless screen-saver-level window,
    /// so drive the cursor straight off the pointer position.
    private func applyCursor(at p: NSPoint) {
        guard !pushedCursor else { return }
        if overToolbar(p) {
            NSCursor.arrow.set()
        } else if let h = hoveredHandle {
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
        } else if (123...126).contains(Int(event.keyCode)), var sel = selection {
            // Arrow keys nudge the selection 1pt (Shift: 10pt); Option resizes it from the bottom-right corner.
            let step: CGFloat = mods.contains(.shift) ? 10 : 1
            let d: (CGFloat, CGFloat) = [123: (-step, 0), 124: (step, 0), 125: (0, -step), 126: (0, step)][Int(event.keyCode)]!
            if mods.contains(.option) {
                // Right/Down grow (right and bottom edges move out), Left/Up shrink.
                let h = max(5, sel.height - d.1)
                sel.origin.y += sel.height - h
                sel.size.height = h
                sel.size.width = max(5, sel.width + d.0)
            } else {
                sel = sel.offsetBy(dx: d.0, dy: d.1)
            }
            sel.origin.x = max(0, min(sel.origin.x, bounds.width - sel.width))
            sel.origin.y = max(0, min(sel.origin.y, bounds.height - sel.height))
            selection = sel
            updateToolbar()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        } else if key == "a" {
            selectTool(.arrow)
        } else if key == "b" {
            selectTool(.box)
        } else if key == "r" {
            session?.startRecording(from: self)
        } else if key == "t" {
            session?.sendToT3(from: self)
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
        control.setToolTip("Move the selection (M)", forSegment: 0)
        control.setToolTip("Arrow (A, Shift snaps to 45°)", forSegment: 1)
        control.setToolTip("Box (B, Shift for a square)", forSegment: 2)
        toolControl = control

        let undoButton = NSButton(title: "Undo", target: self, action: #selector(undoPressed))
        let recordButton = NSButton(title: "Record", target: self, action: #selector(recordPressed))
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(savePressed))
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        let t3Button = NSButton(title: "T3", target: self, action: #selector(t3Pressed))
        t3Button.toolTip = "Send to T3 Code as a new thread (T)"
        let cancelButton = NSButton(title: "✕", target: self, action: #selector(cancelPressed))
        copyButton.keyEquivalent = "\r"
        undoButton.toolTip = "Undo last drawing (⌘Z)"
        recordButton.toolTip = "Record the selection as MP4 (R)"
        saveButton.toolTip = "Save as PNG (⌘S)"
        copyButton.toolTip = "Copy and close (⏎, double-click)"
        cancelButton.toolTip = "Cancel (Esc)"
        for b in [undoButton, recordButton, saveButton, t3Button, copyButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
        }

        let micPopup = RecordingAudio.micPopup(target: self, action: #selector(micChanged(_:)))
        let systemPopup = RecordingAudio.systemPopup(target: self, action: #selector(systemAudioChanged(_:)))
        let recordGroup = NSStackView(views: [recordButton, micPopup, systemPopup])
        recordGroup.spacing = 4

        let stack = NSStackView(views: [control, undoButton, recordGroup, t3Button, copyButton, saveButton, cancelButton])
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
        window?.invalidateCursorRects(for: self)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        tool = Tool(rawValue: sender.selectedSegment) ?? .arrow
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    @objc private func undoPressed() { undoAnnotation(); window?.makeFirstResponder(self) }
    @objc private func recordPressed() { session?.startRecording(from: self) }
    @objc private func micChanged(_ sender: NSPopUpButton) {
        RecordingAudio.choose(micFrom: sender) { session?.dismiss() }
        window?.makeFirstResponder(self)
    }
    @objc private func systemAudioChanged(_ sender: NSPopUpButton) {
        RecordingAudio.systemAudio = sender.indexOfSelectedItem == 1
        window?.makeFirstResponder(self)
    }
    @objc private func copyPressed() { session?.copyAndFinish(from: self) }
    @objc private func savePressed() { session?.saveAndFinish(from: self) }
    @objc private func t3Pressed() { session?.sendToT3(from: self) }
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

/// Draws a capture scaled to fit, never upscaled past its natural point size,
/// with rounded corners and a soft shadow. It has no intrinsic size, so a
/// 3000 px screenshot can't force the window to grow.
private final class PreviewStageView: NSView {
    private let shadowLayer = CALayer()
    private let imageLayer = CALayer()

    var image: CGImage? {
        didSet {
            imageLayer.contents = image
            shadowLayer.isHidden = image == nil
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.22
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        imageLayer.cornerRadius = 8
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 0.5
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        shadowLayer.addSublayer(imageLayer)
        layer?.addSublayer(shadowLayer)
        shadowLayer.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let image, bounds.width > 0, bounds.height > 0 else { return }
        let backing = window?.backingScaleFactor ?? 2
        let natural = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
        let scale = min(1, bounds.width / natural.width, bounds.height / natural.height)
        let size = CGSize(width: floor(natural.width * scale), height: floor(natural.height * scale))
        let rect = CGRect(x: floor((bounds.width - size.width) / 2),
                          y: floor((bounds.height - size.height) / 2),
                          width: size.width, height: size.height)
        shadowLayer.frame = rect
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                                        cornerWidth: 8, cornerHeight: 8, transform: nil)
        imageLayer.frame = CGRect(origin: .zero, size: size)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageLayer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

private final class HistoryTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51, 117: onDelete?()                       // delete, forward delete
        case 36, 76: onCopy?()                          // return, enter
        case 8 where flags == .command: onCopy?()       // ⌘C
        default: super.keyDown(with: event)
        }
    }
}

private final class HistoryCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("historyCell")
    let thumb = NSView()
    let play = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 0.5
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.translatesAutoresizingMaskIntoConstraints = false

        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Recording")
        play.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        play.contentTintColor = .white
        play.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black.withAlphaComponent(0.6); return s }()
        play.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumb)
        addSubview(play)
        addSubview(text)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 60),
            thumb.heightAnchor.constraint(equalToConstant: 38),
            play.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            play.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: CGImage?) {
        thumb.layer?.contents = image
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
            thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }
}

final class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource,
                                     NSTableViewDelegate, NSToolbarDelegate, NSMenuDelegate {
    static var shared: HistoryWindowController?

    private enum Row {
        case header(String)
        case item(HistoryItem)
    }

    private static let copyID = NSToolbarItem.Identifier("copy")
    private static let revealID = NSToolbarItem.Identifier("reveal")
    private static let deleteID = NSToolbarItem.Identifier("delete")

    private var window: NSWindow!
    private var tableView: HistoryTableView!
    private var stage: PreviewStageView!
    private var playerView: AVPlayerView!
    private var infoLabel: NSTextField!
    private var emptyState: NSStackView!
    private var emptyTitle: NSTextField!
    private var emptyDetail: NSTextField!
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

    private var items: [HistoryItem] = []
    private var rows: [Row] = []
    private var thumbnails: [URL: CGImage] = [:]
    private var pendingThumbnails: Set<URL> = []
    private var detailToken = UUID()

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
        window.makeFirstResponder(tableView)
    }

    // MARK: Layout

    private func buildWindow() {
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        let sidebarVC = NSViewController()
        sidebarVC.view = buildSidebar()
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 340
        sidebar.canCollapse = false
        split.addSplitViewItem(sidebar)

        let detailVC = NSViewController()
        detailVC.view = buildDetail()
        let detail = NSSplitViewItem(viewController: detailVC)
        detail.minimumThickness = 340
        split.addSplitViewItem(detail)

        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.contentViewController = split
        win.title = "History"
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 380)
        win.delegate = self

        let toolbar = NSToolbar(identifier: "QuickShotHistoryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar

        // Default to a comfortable size that always fits the current screen,
        // then let any size the user picked previously win.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        win.setContentSize(NSSize(width: min(900, visible.width * 0.8),
                                  height: min(580, visible.height * 0.8)))
        win.center()
        win.setFrameAutosaveName("QuickShotHistory")
        if !visible.contains(win.frame) {
            let size = NSSize(width: min(win.frame.width, visible.width),
                              height: min(win.frame.height, visible.height))
            win.setFrame(NSRect(origin: win.frame.origin, size: size), display: false)
            win.center()
        }
        split.splitView.autosaveName = "QuickShotHistorySplit"
        window = win
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        let table = HistoryTableView()
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 52
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(copySelected)
        table.onCopy = { [weak self] in self?.copySelected() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    private func buildDetail() -> NSView {
        let content = NSView()

        let stage = PreviewStageView()
        stage.translatesAutoresizingMaskIntoConstraints = false
        self.stage = stage
        content.addSubview(stage)

        let player = AVPlayerView()
        player.controlsStyle = .inline
        player.wantsLayer = true
        player.layer?.cornerRadius = 8
        player.layer?.masksToBounds = true
        player.isHidden = true
        player.translatesAutoresizingMaskIntoConstraints = false
        playerView = player
        content.addSubview(player)

        let info = NSTextField(labelWithString: "")
        info.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor
        info.alignment = .center
        info.lineBreakMode = .byTruncatingMiddle
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        info.translatesAutoresizingMaskIntoConstraints = false
        infoLabel = info
        content.addSubview(info)

        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 36, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField(labelWithString: "")
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = .secondaryLabelColor
        let emptyDetail = NSTextField(wrappingLabelWithString: "")
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .tertiaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.preferredMaxLayoutWidth = 260
        let empty = NSStackView(views: [icon, emptyTitle, emptyDetail])
        empty.orientation = .vertical
        empty.spacing = 6
        empty.setCustomSpacing(12, after: icon)
        empty.translatesAutoresizingMaskIntoConstraints = false
        self.emptyState = empty
        self.emptyTitle = emptyTitle
        self.emptyDetail = emptyDetail
        content.addSubview(empty)

        let safe = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stage.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
            stage.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -16),

            player.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            player.topAnchor.constraint(equalTo: stage.topAnchor),
            player.bottomAnchor.constraint(equalTo: stage.bottomAnchor),

            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            info.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
        ])
        return content
    }

    // MARK: Data

    func reload() {
        let selectedURL = selectedItem()?.url
        items = HistoryStore.shared.items()
        let live = Set(items.map(\.url))
        thumbnails = thumbnails.filter { live.contains($0.key) }

        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        var built: [Row] = []
        var lastDay: Date?
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if day != lastDay {
                let label: String
                if calendar.isDateInToday(day) { label = "Today" }
                else if calendar.isDateInYesterday(day) { label = "Yesterday" }
                else { label = dayFormatter.string(from: day) }
                built.append(.header(label))
                lastDay = day
            }
            built.append(.item(item))
        }
        rows = built
        tableView.reloadData()

        let shots = items.filter { !$0.isVideo }.count
        let videos = items.count - shots
        var counts: [String] = []
        if shots > 0 { counts.append("\(shots) screenshot\(shots == 1 ? "" : "s")") }
        if videos > 0 { counts.append("\(videos) recording\(videos == 1 ? "" : "s")") }
        window.subtitle = counts.joined(separator: ", ")

        if let selectedURL, let idx = rowIndex(for: selectedURL) {
            select(row: idx)
        } else if let first = rows.firstIndex(where: { if case .item = $0 { return true }; return false }) {
            select(row: first)
        }
        updateDetail()
    }

    private func rowIndex(for url: URL) -> Int? {
        rows.firstIndex { if case .item(let i) = $0 { return i.url == url }; return false }
    }

    private func select(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func item(at row: Int) -> HistoryItem? {
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return nil }
        return item
    }

    private func selectedItem() -> HistoryItem? {
        item(at: tableView?.selectedRow ?? -1)
    }

    /// The row a context menu was opened on, falling back to the selection.
    private func actionItem() -> HistoryItem? {
        let clicked = tableView.clickedRow
        return clicked >= 0 ? item(at: clicked) : selectedItem()
    }

    private func thumbnail(for item: HistoryItem) -> CGImage? {
        if let cached = thumbnails[item.url] { return cached }
        guard !pendingThumbnails.contains(item.url) else { return nil }
        pendingThumbnails.insert(item.url)
        Task {
            let image = await Self.loadImage(item, maxPixel: 240)
            await MainActor.run {
                self.pendingThumbnails.remove(item.url)
                guard let image else { return }
                self.thumbnails[item.url] = image
                if let row = self.rowIndex(for: item.url),
                   let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryCellView {
                    cell.setThumbnail(image)
                }
            }
        }
        return nil
    }

    private static func loadImage(_ item: HistoryItem, maxPixel: Int) async -> CGImage? {
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try? await generator.image(at: .zero).image
        }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    private func updateDetail() {
        let token = UUID()
        detailToken = token
        let hasItem = selectedItem() != nil
        for id in [Self.copyID, Self.revealID, Self.deleteID] { toolbarItems[id]?.isEnabled = hasItem }

        emptyState.isHidden = !items.isEmpty
        if items.isEmpty {
            let enabled = HistoryStore.shared.isEnabled
            emptyTitle.stringValue = enabled ? "No captures yet" : "History is off"
            emptyDetail.stringValue = enabled
                ? "Screenshots and recordings you take will show up here."
                : "Turn on Keep History in the QuickShot menu to save captures here."
        }

        guard let item = selectedItem() else {
            stage.image = nil
            playerView.player?.pause()
            playerView.player = nil
            playerView.isHidden = true
            infoLabel.stringValue = ""
            return
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let date = df.string(from: item.date)
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }

        if item.isVideo {
            stage.image = nil
            playerView.isHidden = false
            if (playerView.player?.currentItem?.asset as? AVURLAsset)?.url != item.url {
                playerView.player?.pause()
                playerView.player = AVPlayer(url: item.url)
            }
            infoLabel.stringValue = ([date] + [size].compactMap { $0 }).joined(separator: "  ·  ")
            Task {
                let asset = AVURLAsset(url: item.url)
                guard let duration = try? await asset.load(.duration) else { return }
                let track = try? await asset.loadTracks(withMediaType: .video).first
                let natural = try? await track?.load(.naturalSize)
                await MainActor.run {
                    guard self.detailToken == token else { return }
                    var parts = [date]
                    if let natural { parts.append("\(Int(natural.width)) × \(Int(natural.height))") }
                    let secs = Int(duration.seconds.rounded())
                    parts.append(String(format: "%d:%02d", secs / 60, secs % 60))
                    if let size { parts.append(size) }
                    self.infoLabel.stringValue = parts.joined(separator: "  ·  ")
                }
            }
        } else {
            playerView.player?.pause()
            playerView.player = nil
            playerView.isHidden = true
            stage.image = thumbnails[item.url]  // instant low-res stand-in
            var parts = [date]
            if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                parts.append("\(w) × \(h)")
            }
            if let size { parts.append(size) }
            infoLabel.stringValue = parts.joined(separator: "  ·  ")
            Task {
                let image = await Self.loadImage(item, maxPixel: 3200)
                await MainActor.run {
                    guard self.detailToken == token, let image else { return }
                    self.stage.image = image
                }
            }
        }
    }

    // MARK: Actions

    @objc private func copySelected() {
        guard let item = actionItem() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isVideo {
            pb.writeObjects([item.url as NSURL])
        } else if let png = try? Data(contentsOf: item.url), let image = NSImage(data: png) {
            pb.writeObjects([image])
            pb.setData(png, forType: .png)
        }
        if let copy = toolbarItems[Self.copyID] {
            copy.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            }
        }
    }

    @objc private func revealSelected() {
        guard let item = actionItem() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func deleteSelected() {
        guard let item = actionItem() else { return }
        // Keep the selection in place: move to the next capture, or the previous one at the end.
        let flat = items.map(\.url)
        let next = flat.firstIndex(of: item.url).flatMap { idx -> URL? in
            if idx + 1 < flat.count { return flat[idx + 1] }
            return idx > 0 ? flat[idx - 1] : nil
        }
        if item.isVideo, (playerView.player?.currentItem?.asset as? AVURLAsset)?.url == item.url {
            playerView.player?.pause()
            playerView.player = nil
        }
        HistoryStore.shared.delete(item)
        tableView.deselectAll(nil)
        reload()
        if let next, let idx = rowIndex(for: next) { select(row: idx) }
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all captures?"
        alert.informativeText = "This removes every screenshot and recording in History. It can't be undone."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.playerView.player?.pause()
            self.playerView.player = nil
            HistoryStore.shared.clear()
            self.reload()
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard item(at: tableView.clickedRow) != nil else { return }
        menu.addItem(withTitle: "Copy", action: #selector(copySelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete All…", action: #selector(clearAll), keyEquivalent: "").target = self
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, Self.copyID, Self.revealID, Self.deleteID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let specs: [NSToolbarItem.Identifier: (String, String, Selector)] = [
            Self.copyID: ("Copy", "doc.on.doc", #selector(copySelected)),
            Self.revealID: ("Show in Finder", "folder", #selector(revealSelected)),
            Self.deleteID: ("Delete", "trash", #selector(deleteSelected)),
        ]
        guard let (label, symbol, action) = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        item.autovalidates = false
        toolbarItems[id] = item
        return item
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        item(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 28 }
        return 52
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let label):
            let id = NSUserInterfaceItemIdentifier("historyHeader")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = label
            return cell
        case .item(let item):
            let cell = tableView.makeView(withIdentifier: HistoryCellView.id, owner: nil) as? HistoryCellView
                ?? HistoryCellView()
            let df = DateFormatter()
            df.timeStyle = .short
            df.dateStyle = .none
            cell.title.stringValue = item.isVideo ? "Recording" : "Screenshot"
            cell.subtitle.stringValue = df.string(from: item.date)
            cell.play.isHidden = !item.isVideo
            cell.setThumbnail(thumbnail(for: item))
            return cell
        }
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
final class RecordingSession: NSObject, SCStreamDelegate, SCStreamOutput {
    static var current: RecordingSession?

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect  // display-local points, origin top-left
    private let pixelSize: CGSize
    private let borderWindow: NSWindow
    private let fileURL: URL
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var stopping = false
    private var finalized = false
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var controlReply: (([String: Any]) -> Void)?
    var controlStops: [([String: Any]) -> Void] = []
    private var markers: [[String: Any]] = []
    private var automated = false
    private let audio: AudioChoice
    private var hud: RecordingHUD?
    private let sampleQueue = DispatchQueue(label: "quickshot.samples")

    var controlStatus: [String: Any] {
        ["state": finalized ? "finished" : (stopping ? "stopping" : (startedAt == nil ? "starting" : "recording")),
         "path": fileURL.path, "elapsed": startedAt.map { Date().timeIntervalSince($0) } ?? 0,
         "markers": markers, "microphone": audio.mic?.localizedName ?? NSNull(), "systemAudio": audio.system]
    }

    func mark(_ label: String) -> [String: Any] {
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        markers.append(["label": label, "seconds": seconds])
        return ["ok": true, "seconds": seconds, "label": label]
    }

    static func begin(displayID: CGDirectDisplayID, sourceRect: CGRect,
                      pixelSize: CGSize, globalRegion: NSRect, output: URL? = nil,
                      audio: AudioChoice = .none,
                      controlReply: (([String: Any]) -> Void)? = nil) {
        guard current == nil else { return }
        let session = RecordingSession(displayID: displayID, sourceRect: sourceRect,
                                       pixelSize: pixelSize, globalRegion: globalRegion, output: output,
                                       audio: audio, controlReply: controlReply)
        current = session
        session.start()
    }

    private init(displayID: CGDirectDisplayID, sourceRect: CGRect,
                 pixelSize: CGSize, globalRegion: NSRect, output: URL?,
                 audio: AudioChoice, controlReply: (([String: Any]) -> Void)?) {
        self.displayID = displayID
        self.audio = audio
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        fileURL = output ?? desktop.appendingPathComponent("Recording \(df.string(from: Date())).mp4")
        self.controlReply = controlReply
        self.automated = output != nil

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
        if !automated {
            hud = RecordingHUD(region: globalRegion, audio: audio) { [weak self] in self?.stop() }
        }
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
                cfg.capturesAudio = self.audio.system
                cfg.excludesCurrentProcessAudio = true
                if let mic = self.audio.mic {
                    cfg.captureMicrophone = true
                    cfg.microphoneCaptureDeviceID = mic.uniqueID
                }
                // Leave out QuickShot's own windows (the recording controls) wherever they sit.
                let me = content?.applications.filter { $0.processID == getpid() } ?? []
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

                self.writer = try RecordingWriter(url: self.fileURL, size: self.pixelSize,
                                                  system: self.audio.system, mic: self.audio.mic != nil)
                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                if self.audio.system { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue) }
                if self.audio.mic != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.sampleQueue) }
                self.stream = stream
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
        startedAt = Date()
        controlReply?(["ok": true, "state": "recording", "path": fileURL.path])
        controlReply = nil
        borderWindow.orderFrontRegardless()
        hud?.show()
        AppDelegate.shared?.setRecording(true)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if stopping { return }
        writer?.append(sampleBuffer, type: type)
        guard type != .screen, hud != nil else { return }
        let level = RecordingAudio.level(sampleBuffer)
        DispatchQueue.main.async { self.hud?.update(type, level: level) }
    }

    func stop() {
        guard !stopping, startedAt != nil else { return }
        stopping = true
        stoppedAt = Date()
        borderWindow.orderOut(nil)
        hud?.showSaving()
        AppDelegate.shared?.setRecording(false)
        stream?.stopCapture { error in
            self.sampleQueue.async {
                guard let writer = self.writer else { return }
                writer.finish { writeError in
                    DispatchQueue.main.async {
                        if let e = writeError ?? error { self.fail(e) } else { self.finishRecording() }
                    }
                }
            }
        }
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
        hud?.close()
        AppDelegate.shared?.setRecording(false)
        RecordingSession.current = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let result: [String: Any] = ["ok": false, "state": "failed", "error": "Recording file is missing"]
            AutomationControl.shared.lastResult = result
            controlStops.forEach { $0(result) }
            return
        }
        let result: [String: Any] = ["ok": true, "state": "finished", "path": fileURL.path,
            "duration": startedAt.map { (stoppedAt ?? Date()).timeIntervalSince($0) } ?? 0, "markers": markers]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: fileURL.path + ".markers.json"), options: .atomic)
        }
        AutomationControl.shared.lastResult = result
        controlStops.forEach { $0(result) }
        controlStops.removeAll()
        if automated { return }
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
        stream?.stopCapture { _ in }
        borderWindow.orderOut(nil)
        hud?.close()
        AppDelegate.shared?.setRecording(false)
        RecordingSession.current = nil
        let result: [String: Any] = ["ok": false, "state": "failed", "error": error?.localizedDescription ?? "Unknown error"]
        AutomationControl.shared.lastResult = result
        controlReply?(result)
        controlReply = nil
        controlStops.forEach { $0(result) }
        controlStops.removeAll()
        if automated { return }
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

    /// Normal app windows, front to back, in global Cocoa coordinates. Read before the
    /// overlays exist so they never show up.
    private var appWindows: [AppWindow] = []

    static func onScreenAppWindows() -> [AppWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w >= 40, h >= 40 else { return nil }
            return AppWindow(rect: NSRect(x: x, y: primary.maxY - y - h, width: w, height: h),
                             bounds: CGRect(x: x, y: y, width: w, height: h),
                             pid: info[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                             app: info[kCGWindowOwnerName as String] as? String ?? "",
                             title: info[kCGWindowName as String] as? String ?? "",
                             windowID: info[kCGWindowNumber as String] as? CGWindowID ?? 0)
        }
    }

    private func start() {
        appWindows = Self.onScreenAppWindows()
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
            view.windowRects = appWindows.compactMap { w in
                let local = w.rect.intersection(screen.frame).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                return local.width >= 40 && local.height >= 40 ? local : nil
            }
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
        if let view = keyWindow.contentView as? OverlayView {
            keyWindow.makeFirstResponder(view)
            view.updateHoverWindow(at: NSPoint(x: mouse.x - keyWindow.frame.minX, y: mouse.y - keyWindow.frame.minY))
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
        // Nothing selected yet: copy the whole screen under the pointer (fn+⌃, then space).
        var view = views.first { $0.selection != nil } ?? view
        if view.selection == nil {
            let mouse = NSEvent.mouseLocation
            view = views.first { $0.screenFrame.contains(mouse) } ?? view
            view.selection = view.bounds
        }
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
        if let sel = view.selection { CaptureFlash.show(sel.offsetBy(dx: view.screenFrame.minX, dy: view.screenFrame.minY)) }
        dismiss()
    }

    func sendToT3(from view: OverlayView) {
        guard let rep = view.renderComposite(),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        // The frontmost window under the middle of the selection is what the screenshot shows.
        let source = view.selection.flatMap { sel -> AppWindow? in
            let middle = NSPoint(x: view.screenFrame.minX + sel.midX, y: view.screenFrame.minY + sel.midY)
            return appWindows.first { $0.rect.contains(middle) }
        }
        HistoryStore.shared.saveImage(png)
        HistoryWindowController.shared?.reload()
        if let sel = view.selection { CaptureFlash.show(sel.offsetBy(dx: view.screenFrame.minX, dy: view.screenFrame.minY)) }
        dismiss()
        T3Sender.begin(png: png, source: source)
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
                               globalRegion: globalRegion, audio: RecordingAudio.saved)
    }

    func saveAndFinish(from view: OverlayView) {
        guard let rep = view.renderComposite(),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        if let sel = view.selection { CaptureFlash.show(sel.offsetBy(dx: view.screenFrame.minX, dy: view.screenFrame.minY)) }
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

// MARK: - Capture flash

/// A faint brightening of exactly what was captured, so a screenshot is felt but not noticed.
enum CaptureFlash {
    private static var windows: [NSWindow] = []

    static func show(_ rect: NSRect, peak: Float = 0.14) {
        let win = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.setFrame(rect, display: false)
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        let layer = CALayer()
        layer.frame = view.bounds
        layer.backgroundColor = NSColor.white.cgColor
        layer.opacity = 0
        view.layer?.addSublayer(layer)
        win.contentView = view
        win.orderFrontRegardless()
        windows.append(win)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, peak, 0]
        anim.keyTimes = [0, 0.18, 1]
        anim.duration = 0.38
        anim.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        layer.add(anim, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            win.orderOut(nil)
            windows.removeAll { $0 === win }
        }
    }
}

// MARK: - Hotkey (modifier chords via event tap, since Carbon hotkeys can't see fn or sides)

final class ChordHotKey {
    // Device-dependent modifier bit from IOLLEvent.h, the one that distinguishes sides.
    private static let leftControlMask: UInt64 = 0x0001  // NX_DEVICELCTLKEYMASK
    private static let leftCommandMask: UInt64 = 0x0008  // NX_DEVICELCMDKEYMASK
    private static let rightCommandMask: UInt64 = 0x0010 // NX_DEVICERCMDKEYMASK

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var comboDown = false
    private var commandsDown = false
    private let onTrigger: () -> Void
    private let onBothCommands: () -> Void

    var isActive: Bool { tap != nil }

    init(onTrigger: @escaping () -> Void, onBothCommands: @escaping () -> Void = {}) {
        self.onTrigger = onTrigger
        self.onBothCommands = onBothCommands

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

        // Both ⌘ keys together (left and right), nothing else held: new T3 chat.
        let both = flags.rawValue & Self.leftCommandMask != 0 && flags.rawValue & Self.rightCommandMask != 0
        let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        let bothOnly = both && flags.intersection(others).isEmpty
        if bothOnly && !commandsDown {
            commandsDown = true
            DispatchQueue.main.async { self.onBothCommands() }
        } else if !both {
            commandsDown = false
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
    private var quickChatCaptureItems: [NSMenuItem] = []

    @objc private func setQuickChatCapture(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = QuickChat.Capture(rawValue: raw) {
            QuickChat.captureMode = mode
        }
    }
    private var hotKey: ChordHotKey?
    private var retryTimer: Timer?
    private var isRecording = false
    private var recordingTimer: Timer?
    private var recordingStarted = Date()

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
        menu.addItem(.separator())
        let both = NSMenuItem(title: "Both ⌘ to T3", action: nil, keyEquivalent: "")
        both.isEnabled = false
        menu.addItem(both)
        for (title, mode) in [("Full Screen", QuickChat.Capture.screen), ("Front Window", .window)] {
            let mi = NSMenuItem(title: title, action: #selector(setQuickChatCapture(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.indentationLevel = 1
            menu.addItem(mi)
            quickChatCaptureItems.append(mi)
        }
        menu.addItem(.separator())
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
        self.menu = menu
        statusItem = item

        // The event tap needs Accessibility; this shows the system prompt once.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        installHotkey()
        AutomationControl.shared.install()
        if CommandLine.arguments.contains("--show-history") { showHistory() }
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

    private var menu: NSMenu?

    /// While recording, the menu bar item shows the elapsed time and one click stops it.
    func setRecording(_ on: Bool) {
        isRecording = on
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let item = statusItem, let button = item.button else { return }
        if on {
            recordingStarted = Date()
            item.length = NSStatusItem.variableLength
            item.menu = nil
            button.target = self
            button.action = #selector(stopFromStatusItem)
            button.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Stop recording")
            button.imagePosition = .imageLeading
            button.contentTintColor = .systemRed
            button.toolTip = "Click to stop recording (fn+⌃)"
            updateRecordingTitle()
            let t = Timer(timeInterval: 1, repeats: true) { _ in AppDelegate.shared?.updateRecordingTitle() }
            RunLoop.main.add(t, forMode: .common)
            recordingTimer = t
        } else {
            item.length = NSStatusItem.squareLength
            item.menu = menu
            button.action = nil
            button.title = ""
            button.toolTip = nil
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "QuickShot")
            button.imagePosition = .imageOnly
            button.contentTintColor = nil
        }
    }

    private func updateRecordingTitle() {
        let s = Int(Date().timeIntervalSince(recordingStarted))
        statusItem?.button?.title = String(format: " %d:%02d", s / 60, s % 60)
        statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    @objc private func stopFromStatusItem() {
        if #available(macOS 15.0, *) { RecordingSession.current?.stop() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        captureMenuItem?.title = isRecording ? "Stop Recording (fn+⌃)" : "Capture Area (fn+⌃)"
        keepHistoryMenuItem?.state = HistoryStore.shared.isEnabled ? .on : .off
        for mi in quickChatCaptureItems {
            mi.state = mi.representedObject as? String == QuickChat.captureMode.rawValue ? .on : .off
        }
        if hotKey?.isActive == true {
            hotKeyStatusItem?.title = "Hotkey active"
            hotKeyStatusItem?.action = nil
        } else {
            hotKeyStatusItem?.title = "Hotkey off: grant Accessibility…"
            hotKeyStatusItem?.action = #selector(openAccessibilitySettings)
        }
    }

    private func installHotkey() {
        let hk = ChordHotKey(onTrigger: { AppDelegate.shared?.startCapture() },
                             onBothCommands: { QuickChat.trigger() })
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
