import Cocoa
import ScreenCaptureKit

// Both ⌘ keys: screenshot the front window and fly it into T3 Code, attached in the composer
// and ready for a prompt. A quick tap sends it to the default target (a new thread in Home to
// start with). Holding the keys opens a picker: a new thread in any project, or an existing
// thread, and ⌘D there makes the choice the default for later taps.
enum QuickChat {
    private static var busy = false
    private static var flight: NSWindow?
    private static var picker: QuickPicker?
    private static let holdDelay: TimeInterval = 0.3

    static func trigger(pick: Bool = false) {
        guard !busy else { return }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Sender.t3BundleID) != nil else {
            NSSound.beep(); return
        }
        busy = true
        let front = NSWorkspace.shared.frontmostApplication
        let windows = CaptureSession.onScreenAppWindows()
        let source = windows.first(where: { $0.pid == front?.processIdentifier }) ?? windows.first

        // Capture right away, before any panel is on screen; decide tap or hold meanwhile.
        var image: CGImage?
        var captured = source == nil || !CGPreflightScreenCaptureAccess()
        var onCaptured: (() -> Void)?
        if !captured, let source {
            capture(source) { img in
                image = img
                captured = true
                onCaptured?()
                onCaptured = nil
            }
        }
        let whenCaptured: (@escaping () -> Void) -> Void = { body in
            if captured { body() } else { onCaptured = body }
        }

        let started = Date()
        func poll() {
            let held = CGEventSource.flagsState(.hidSystemState).contains(.maskCommand)
            if !held && !pick {
                // Tap: straight to the default target.
                whenCaptured { send(image, to: ChatTarget.standard, from: source?.rect) }
            } else if pick || Date().timeIntervalSince(started) >= holdDelay {
                openPicker(front: front, source: source, image: { image }, whenCaptured: whenCaptured)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { poll() }
            }
        }
        poll()
    }

    private static func openPicker(front: NSRunningApplication?, source: AppWindow?, image: @escaping () -> CGImage?,
                                   whenCaptured: (@escaping () -> Void) -> Void) {
        let nsImage = { (cg: CGImage?) in cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
        let p = QuickPicker(image: nsImage(image())) { target, from in
            picker = nil
            guard let target else {
                busy = false
                front?.activate()
                return
            }
            send(image(), to: target, from: from ?? source?.rect, flash: from == nil)
        }
        picker = p
        p.show()
        whenCaptured { if let img = nsImage(image()) { p.setImage(img) } }
    }

    /// Flies the screenshot into T3 while opening the target there, then pastes it in.
    private static func send(_ image: CGImage?, to target: ChatTarget, from rect: NSRect?, flash: Bool = true) {
        let t3PID = NSRunningApplication.runningApplications(withBundleIdentifier: T3Sender.t3BundleID).first?.processIdentifier
        let png = image.flatMap(pngData)
        if let png {
            HistoryStore.shared.saveImage(png)
            HistoryWindowController.shared?.reload()
        }
        let group = DispatchGroup()
        var t3: NSRunningApplication?
        if let image, let rect {
            group.enter()
            fly(image, from: rect, to: target.kind, t3PID: t3PID, flash: flash) { group.leave() }
        }
        group.enter()
        open(target) { app in t3 = app; group.leave() }
        group.notify(queue: .main) {
            defer { busy = false }
            if let t3, let png { paste(png, into: t3) }
        }
    }

    // MARK: Capture

    private static func capture(_ window: AppWindow, done: @escaping (CGImage?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            guard let scWindow = content?.windows.first(where: { $0.windowID == window.windowID }) else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let scale = NSScreen.screens.first(where: { $0.frame.intersects(window.rect) })?.backingScaleFactor ?? 2
            let cfg = SCStreamConfiguration()
            cfg.width = Int(scWindow.frame.width * scale)
            cfg.height = Int(scWindow.frame.height * scale)
            cfg.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { image, _ in
                DispatchQueue.main.async { done(image) }
            }
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: Animation

    /// A snapshot of the window lifts off (flash and a small press), then arcs down into
    /// T3's composer, shrinking to a thumbnail as it lands.
    private static func fly(_ image: CGImage, from rect: NSRect, to kind: ChatTarget.Kind, t3PID: pid_t?,
                            flash withFlash: Bool, done: @escaping () -> Void) {
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let win = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .popUpMenu
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.setFrame(union, display: false)
        let root = NSView(frame: NSRect(origin: .zero, size: union.size))
        root.wantsLayer = true
        win.contentView = root

        let start = rect.offsetBy(dx: -union.minX, dy: -union.minY)
        let card = CALayer()
        card.frame = start
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.35
        card.shadowRadius = 24
        card.shadowOffset = CGSize(width: 0, height: -8)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let face = CALayer()
        face.frame = card.bounds
        face.contents = image
        face.contentsGravity = .resizeAspect
        face.cornerRadius = 12
        face.masksToBounds = true
        let flash = CALayer()
        flash.frame = face.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        face.addSublayer(flash)
        card.addSublayer(face)
        root.layer?.addSublayer(card)
        win.orderFrontRegardless()
        flight = win

        // Land on T3's composer: centered in a new thread's main pane, at the bottom of an
        // existing thread, or mid screen when T3 has no window yet (it comes forward there).
        let t3Window = t3PID.flatMap { pid in CaptureSession.onScreenAppWindows().first { $0.pid == pid } }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main ?? NSScreen.screens[0]
        // The attachment thumbnail sits at the composer's top left; the composer is centered
        // in the pane right of the sidebar, up to ~900pt wide, a little above the middle.
        let thumb: CGFloat = 78
        let landing: NSPoint = t3Window.map { w in
            let pane = NSRect(x: w.rect.minX + min(364, w.rect.width * 0.3), y: w.rect.minY,
                              width: w.rect.width - min(364, w.rect.width * 0.3), height: w.rect.height)
            let composerLeft = pane.midX - min(452, pane.width / 2 - 24)
            let y = kind == .newThread ? w.rect.maxY - w.rect.height * 0.44 : w.rect.minY + 135
            return NSPoint(x: composerLeft + 20 + thumb / 2, y: y)
        } ?? NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let end = NSPoint(x: landing.x - union.minX, y: landing.y - union.minY)
        let startCenter = NSPoint(x: start.midX, y: start.midY)
        let endScale = min(1, thumb / max(start.width, 1))

        let lift: CFTimeInterval = 0.2, travel: CFTimeInterval = 0.62
        let now = CACurrentMediaTime()

        let flashAnim = CAKeyframeAnimation(keyPath: "opacity")
        flashAnim.values = [0, 0.7, 0]
        flashAnim.keyTimes = [0, 0.25, 1]
        flashAnim.duration = 0.32
        if withFlash { flash.add(flashAnim, forKey: "flash") }

        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [1, 0.95, 0.97]
        press.keyTimes = [0, 0.6, 1]
        press.duration = lift
        press.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let path = CGMutablePath()
        path.move(to: startCenter)
        // Arc: rise a little first, then drop into the composer.
        let control = CGPoint(x: (startCenter.x + end.x) / 2, y: max(startCenter.y, end.y) + 120)
        path.addQuadCurve(to: end, control: control)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.beginTime = now + lift
        move.duration = travel
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.15, 1)
        move.fillMode = .both
        move.isRemovedOnCompletion = false

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 0.97
        shrink.toValue = endScale
        shrink.beginTime = now + lift
        shrink.duration = travel
        shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.1, 1)
        shrink.fillMode = .both
        shrink.isRemovedOnCompletion = false

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = now + lift + travel - 0.12
        fade.duration = 0.16
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false

        let shadowFade = CABasicAnimation(keyPath: "shadowOpacity")
        shadowFade.fromValue = 0.35
        shadowFade.toValue = 0.15
        shadowFade.beginTime = now + lift
        shadowFade.duration = travel
        shadowFade.fillMode = .both
        shadowFade.isRemovedOnCompletion = false

        card.add(press, forKey: "press")
        card.add(move, forKey: "move")
        card.add(shrink, forKey: "shrink")
        card.add(shadowFade, forKey: "shadow")
        card.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + lift + travel + 0.06) {
            win.orderOut(nil)
            if flight === win { flight = nil }
            done()
        }
    }

    // MARK: T3

    /// Opens the target in T3 and calls back with T3 once its composer is ready, or nil when T3
    /// never came forward. A new thread: `t3 app <project>` selects the project, then T3's
    /// chat.newLocal shortcut (⌘⇧N) opens a new thread there. A thread: its deep link.
    static func open(_ target: ChatTarget, done: @escaping (NSRunningApplication?) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Sender.t3BundleID) else { done(nil); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let deadline = Date().addingTimeInterval(8)
        if target.kind == .thread, let url = target.threadURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { app, _ in
                DispatchQueue.main.async {
                    waitForFront(app, deadline: deadline, settle: 0.45, press: nil, done: done)
                }
            }
            return
        }
        let cli = T3Sender.cli, path = target.path
        DispatchQueue.global(qos: .userInitiated).async {
            let r = T3Sender.run(cli, ["app", path], stdin: nil, timeout: 5)
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, _ in
                    DispatchQueue.main.async {
                        // Give the project switch a moment before the shortcut (none when it failed:
                        // the new thread then opens in whichever project is current).
                        waitForFront(app, deadline: deadline, settle: r.code == 0 ? 0.25 : 0.08,
                                     press: (45, [.maskCommand, .maskShift]), done: done)   // ⌘⇧N
                    }
                }
            }
        }
    }

    private static func waitForFront(_ app: NSRunningApplication?, deadline: Date, settle: TimeInterval,
                                     press shortcut: (CGKeyCode, CGEventFlags)?, done: @escaping (NSRunningApplication?) -> Void) {
        // Also wait for the ⌘ keys of the chord to come up, so they don't mix into the shortcut.
        let held = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              app.isFinishedLaunching, held.isEmpty else {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    waitForFront(app, deadline: deadline, settle: settle, press: shortcut, done: done)
                }
            } else { done(nil) }
            return
        }
        // A cold start needs time before the web view handles keys.
        let cold = app.launchDate.map { Date().timeIntervalSince($0) < 5 } ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + (cold ? 2 : settle)) {
            guard let (key, flags) = shortcut else { done(app); return }
            press(key: key, flags: flags, to: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(app) }
        }
    }

    /// Pastes the screenshot into the focused composer, then puts the clipboard back.
    private static func paste(_ png: Data, into app: NSRunningApplication) {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setData(png, forType: .png)
        press(key: 9, flags: .maskCommand, to: app)   // ⌘V
        let change = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pb.changeCount == change else { return }   // something else copied since
            pb.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in pairs { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    private static func press(key: CGKeyCode, flags: CGEventFlags, to app: NSRunningApplication) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.postToPid(app.processIdentifier)
        }
    }
}
