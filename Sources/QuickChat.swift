import Cocoa
import ScreenCaptureKit

// Both ⌘ keys: screenshot the front window, fly it into T3 Code, open a new chat and paste the
// screenshot into its composer, ready for a prompt. When T3 is already in front, just a new chat.
enum QuickChat {
    private static var busy = false
    private static var flight: NSWindow?

    static func trigger() {
        guard !busy else { return }
        guard let t3URL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Sender.t3BundleID) else {
            NSSound.beep(); return
        }
        busy = true
        let front = NSWorkspace.shared.frontmostApplication
        let t3PID = NSRunningApplication.runningApplications(withBundleIdentifier: T3Sender.t3BundleID).first?.processIdentifier
        let windows = CaptureSession.onScreenAppWindows().filter { $0.pid != t3PID }
        let source = front?.bundleIdentifier == T3Sender.t3BundleID ? nil
            : windows.first(where: { $0.pid == front?.processIdentifier }) ?? windows.first

        guard let source, CGPreflightScreenCaptureAccess() else {
            openNewChat(t3URL) { _ in busy = false }
            return
        }
        capture(source) { image in
            guard let image, let png = pngData(image) else {
                openNewChat(t3URL) { _ in busy = false }
                return
            }
            HistoryStore.shared.saveImage(png)
            HistoryWindowController.shared?.reload()

            let group = DispatchGroup()
            var t3: NSRunningApplication?
            group.enter()
            fly(image, from: source.rect, t3PID: t3PID) { group.leave() }
            group.enter()
            openNewChat(t3URL) { app in t3 = app; group.leave() }
            group.notify(queue: .main) {
                defer { busy = false }
                guard let t3 else { return }
                paste(png, into: t3)
            }
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
    private static func fly(_ image: CGImage, from rect: NSRect, t3PID: pid_t?, done: @escaping () -> Void) {
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

        // Land on T3's composer, centered in a new thread's main pane, or of the screen when T3
        // has no window yet (it comes forward there).
        let t3Window = t3PID.flatMap { pid in CaptureSession.onScreenAppWindows().first { $0.pid == pid } }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main ?? NSScreen.screens[0]
        // The attachment thumbnail sits at the composer's top left; the composer is centered
        // in the pane right of the sidebar, up to ~900pt wide, a little above the middle.
        let thumb: CGFloat = 78
        let landing: NSPoint = t3Window.map { w in
            let pane = NSRect(x: w.rect.minX + min(364, w.rect.width * 0.3), y: w.rect.minY,
                              width: w.rect.width - min(364, w.rect.width * 0.3), height: w.rect.height)
            let composerLeft = pane.midX - min(452, pane.width / 2 - 24)
            return NSPoint(x: composerLeft + 20 + thumb / 2, y: w.rect.maxY - w.rect.height * 0.44)
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
        flash.add(flashAnim, forKey: "flash")

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

    /// Brings T3 forward and presses its chat.newLocal shortcut (⌘⇧N: new thread in the current project). Calls back with T3 once the
    /// new chat had a moment to open, or nil when T3 never came forward.
    static func openNewChat(_ appURL: URL, done: @escaping (NSRunningApplication?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, _ in
            DispatchQueue.main.async { waitForFront(app, deadline: Date().addingTimeInterval(6), done: done) }
        }
    }

    private static func waitForFront(_ app: NSRunningApplication?, deadline: Date, done: @escaping (NSRunningApplication?) -> Void) {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              app.isFinishedLaunching else {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForFront(app, deadline: deadline, done: done) }
            } else { done(nil) }
            return
        }
        // A cold start needs time before the web view handles keys.
        let cold = app.launchDate.map { Date().timeIntervalSince($0) < 5 } ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + (cold ? 2 : 0.08)) {
            press(key: 45, flags: [.maskCommand, .maskShift], to: app)   // ⌘⇧N
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
