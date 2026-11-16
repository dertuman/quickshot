import Cocoa
import ApplicationServices

/// A normal app window that was on screen when a capture started.
struct AppWindow {
    let rect: NSRect      // global Cocoa coordinates (origin bottom left)
    let bounds: CGRect    // global screen coordinates (origin top left), as the window server reports them
    let pid: pid_t
    let app: String
    let title: String
}

/// What a screenshot shows: the app and window it was taken in and, when the app exposes it,
/// the page or document open there. Sent along to T3 so the agent knows where to look.
struct ScreenContext {
    let app: String
    let title: String
    let location: String?   // page address in a browser, file path in a document app

    var summary: String {
        var text = app
        if !title.isEmpty && title != app { text += ", \"\(title)\"" }
        if let location { text += " (\(location))" }
        return text
    }

    /// The location when it is a web address, which a project locator can map to a route.
    var page: String? {
        guard let location, !location.hasPrefix("/") else { return nil }
        return location
    }
}

/// Reads a window's page or document through the Accessibility API, which QuickShot is already
/// granted for its hotkey. No new permission, and nothing is read when the grant is missing.
enum ScreenContextReader {
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "app.zen-browser.zen",
    ]

    static func read(_ window: AppWindow) -> ScreenContext {
        ScreenContext(app: window.app, title: window.title, location: location(of: window))
    }

    private static func location(of window: AppWindow) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let element = axWindow(of: app, matching: window) else { return nil }
        let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
        let isBrowser = browsers.contains(bundle)
        // Document apps (and Safari) name what the window shows in AXDocument.
        if let document = string(element, kAXDocumentAttribute), let cleaned = clean(document, web: isBrowser) {
            return cleaned
        }
        guard isBrowser else { return nil }
        return webAddress(in: element).flatMap { clean($0, web: true) }
    }

    /// The accessibility window with the same frame as the window-server window, else the same
    /// title, else whichever the app calls its main window.
    private static func axWindow(of app: AXUIElement, matching window: AppWindow) -> AXUIElement? {
        let windows = elements(app, kAXWindowsAttribute)
        if let match = windows.first(where: { w in
            guard let frame = frame(of: w) else { return false }
            return abs(frame.minX - window.bounds.minX) < 3 && abs(frame.minY - window.bounds.minY) < 3
                && abs(frame.width - window.bounds.width) < 3 && abs(frame.height - window.bounds.height) < 3
        }) { return match }
        if !window.title.isEmpty, let match = windows.first(where: { string($0, kAXTitleAttribute) == window.title }) {
            return match
        }
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &main) == .success,
           let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
            return (main as! AXUIElement)
        }
        return windows.first
    }

    /// The address of the page in a browser window: the web area's URL when the browser exposes
    /// it, else what the address bar shows. Breadth first with a node and time budget, and never
    /// into the page content itself.
    private static func webAddress(in window: AXUIElement) -> String? {
        let deadline = Date().addingTimeInterval(0.6)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var typed: String?
        while index < queue.count, index < 700, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success {
                    if let url = value as? URL { return url.absoluteString }
                    if let text = value as? String, !text.isEmpty { return text }
                }
                continue
            }
            if role == kAXTextFieldRole as String || role == "AXComboBox", typed == nil,
               let text = string(element, kAXValueAttribute), looksLikeAddress(text) {
                typed = text
            }
            if typed != nil && index > 250 { break }
            if depth < 14 {
                for child in elements(element, kAXChildrenAttribute) { queue.append((child, depth + 1)) }
            }
        }
        return typed
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count < 2000, !t.contains(" ") else { return false }
        return t.range(of: #"^([a-z][a-z0-9+.-]*://)?(localhost|[\w-]+(\.[\w-]+)+)(:\d+)?([/?#]\S*)?$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Paths for files, addresses without the query and fragment for pages: those can carry
    /// tokens, and the path is all a locator needs.
    private static func clean(_ raw: String, web: Bool) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("file://") { return URL(string: text)?.path }
        if text.hasPrefix("/") { return text }
        guard web || text.hasPrefix("http://") || text.hasPrefix("https://") else { return nil }
        guard looksLikeAddress(text) else { return nil }
        let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? text.endIndex
        return String(text[..<end])
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
