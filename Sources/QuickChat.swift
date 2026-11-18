import Cocoa
import ScreenCaptureKit

// Both ⌘ keys: screenshot the front window and fly it into T3 Code, attached in the composer of
// the default target (a new thread in Home to start with) and ready for a prompt. No questions
// first. Afterwards a small chip says where it went; click it to send the screenshot somewhere
// else (a new thread in any project, or an existing thread) or to change the default.
enum QuickChat {
    private static var busy = false
    private static var flight: [NSWindow] = []
    private static var picker: QuickPicker?
    private static var chip: SentChip?
    /// Where the last screenshot was pasted (T3 route), so a redirect can take it back out.
    private static var placed: (route: String, target: ChatTarget)?

    /// What both ⌘ captures: the whole screen under the pointer (default) or the front window.
    enum Capture: String { case screen, window }
    static var captureMode: Capture {
        get { Capture(rawValue: UserDefaults.standard.string(forKey: "QuickChatCapture") ?? "") ?? .screen }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "QuickChatCapture") }
    }

    static func trigger(pick: Bool = false) {
        guard !busy else { return }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Sender.t3BundleID) != nil else {
            NSSound.beep(); return
        }
        busy = true
        chip?.close()
        let target = ChatTarget.standard
        let finish: (CGImage?, NSRect) -> Void = { image, rect in
            send(image, to: target, from: rect) { t3 in
                guard let image, t3 != nil else { return }
                showChip(image, sentTo: target, openPicker: pick)
            }
        }
        guard CGPreflightScreenCaptureAccess() else { send(nil, to: target, from: nil) { _ in }; return }
        if captureMode == .screen {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens[0]
            captureScreen(screen) { finish($0, screen.frame) }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let windows = CaptureSession.onScreenAppWindows()
        guard let source = windows.first(where: { $0.pid == front?.processIdentifier }) ?? windows.first else {
            send(nil, to: target, from: nil) { _ in }
            return
        }
        capture(source) { finish($0, source.rect) }
    }

    private static func showChip(_ image: CGImage, sentTo target: ChatTarget, openPicker: Bool) {
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let c = SentChip(image: ns, target: target) { from in
            chip = nil
            redirect(image, ns, sentTo: target, from: from)
        }
        chip = c
        c.show()
        if openPicker { c.click() }
    }

    /// The chip was clicked: pick another target for the same screenshot.
    private static func redirect(_ image: CGImage, _ ns: NSImage, sentTo: ChatTarget, from: NSRect) {
        guard !busy else { return }
        let back = NSWorkspace.shared.frontmostApplication
        let p = QuickPicker(image: ns, sentTo: sentTo) { target, thumb in
            picker = nil
            guard let target else { back?.activate(); return }
            busy = true
            unplace {
                send(image, to: target, from: thumb ?? from, flash: false) { t3 in
                    if t3 != nil { showChip(image, sentTo: target, openPicker: false) }
                }
            }
        }
        picker = p
        p.show()
    }

    /// Flies the screenshot into T3 while opening the target there, then pastes it in.
    private static func send(_ image: CGImage?, to target: ChatTarget, from rect: NSRect?, flash: Bool = true,
                             done: @escaping (NSRunningApplication?) -> Void) {
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
            busy = false
            if let t3, let png {
                paste(png, into: t3)
                placed = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let route = T3AX.route(t3.processIdentifier) { placed = (route, target) }
                }
            }
            done(t3)
        }
    }

    /// Takes the screenshot back out of where it was pasted, so redirecting leaves no junk:
    /// a new thread draft holding only the screenshot is then empty, and T3 drops it.
    /// Goes back to an existing thread first if T3 has moved on; a draft it has moved on from
    /// has no route back, so it is left as is.
    private static func unplace(then next: @escaping () -> Void) {
        guard let p = placed,
              let t3 = NSRunningApplication.runningApplications(withBundleIdentifier: T3Sender.t3BundleID).first
        else { next(); return }
        placed = nil
        let pid = t3.processIdentifier
        if T3AX.route(pid) == p.route { T3AX.removeLastImage(pid); next(); return }
        guard p.target.kind == .thread, let url = p.target.threadURL,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Sender.t3BundleID)
        else { next(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, _ in }
        func check(_ tries: Int) {
            if T3AX.route(pid) == p.route { T3AX.removeLastImage(pid); next() }
            else if tries == 0 { next() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(tries - 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check(15) }
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

    private static func captureScreen(_ screen: NSScreen, done: @escaping (CGImage?) -> Void) {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content, let display = content.displays.first(where: { $0.displayID == id }) else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            cfg.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            cfg.showsCursor = false
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
        // One overlay per display: with separate Spaces per display, a window spanning all
        // screens only shows on one of them. Each overlay draws the same card in global
        // coordinates (offset by its screen), so the flight crosses displays too.
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let start = rect.offsetBy(dx: -union.minX, dy: -union.minY)
        var wins: [NSWindow] = [], cards: [CALayer] = [], flashes: [CALayer] = []
        for scr in NSScreen.screens {
            let win = NSWindow(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .popUpMenu
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.setFrame(scr.frame, display: false)
            let root = NSView(frame: NSRect(origin: .zero, size: scr.frame.size))
            root.wantsLayer = true
            win.contentView = root
            let world = CALayer()
            world.frame = CGRect(x: union.minX - scr.frame.minX, y: union.minY - scr.frame.minY,
                                 width: union.width, height: union.height)
            root.layer?.addSublayer(world)

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
            world.addSublayer(card)
            win.orderFrontRegardless()
            wins.append(win); cards.append(card); flashes.append(flash)
        }
        flight = wins

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
        flashAnim.values = [0, 0.35, 0]
        flashAnim.keyTimes = [0, 0.25, 1]
        flashAnim.duration = 0.32
        if withFlash { flashes.forEach { $0.add(flashAnim, forKey: "flash") } }

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

        for card in cards {
            card.add(press, forKey: "press")
            card.add(move, forKey: "move")
            card.add(shrink, forKey: "shrink")
            card.add(shadowFade, forKey: "shadow")
            card.add(fade, forKey: "fade")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + lift + travel + 0.06) {
            wins.forEach { $0.orderOut(nil) }
            if flight.first === wins.first { flight = [] }
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

/// T3 Code's web view through the accessibility tree (Electron exposes it on request).
enum T3AX {
    private static func element(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, String) -> Bool) -> Bool {
        guard depth < 80 else { return false }
        if visit(e, attr(e, "AXRole") as? String ?? "") { return true }
        for c in attr(e, "AXChildren") as? [AXUIElement] ?? [] where walk(c, depth: depth + 1, visit) { return true }
        return false
    }

    /// The route T3 shows, e.g. "/draft/<id>" or "/<environment>/<thread>".
    static func route(_ pid: pid_t) -> String? {
        var route: String?
        _ = walk(element(pid)) { e, role in
            guard role == "AXWebArea" else { return false }
            route = (attr(e, "AXURL") as? URL)?.fragment
            return route != nil
        }
        return route
    }

    /// Presses the composer's last "Remove image…" button: the pasted screenshot is the newest.
    @discardableResult
    static func removeLastImage(_ pid: pid_t) -> Bool {
        var last: AXUIElement?
        _ = walk(element(pid)) { e, role in
            if role == "AXButton", (attr(e, "AXDescription") as? String)?.hasPrefix("Remove image") == true { last = e }
            return false
        }
        guard let last else { return false }
        return AXUIElementPerformAction(last, kAXPressAction as CFString) == .success
    }
}
