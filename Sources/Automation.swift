import Cocoa
import ScreenCaptureKit

// Same-user file mailbox: no network listener, no remote access, no permission bypass.
// Requests expire so a timed-out client cannot unexpectedly begin recording later.
final class AutomationControl {
    static let shared = AutomationControl()
    private var timer: Timer?
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuickShot/Control", isDirectory: true)
    private var starting = false
    var lastResult: [String: Any] = ["state": "idle"]

    func install() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        } catch { NSLog("QuickShot controls unavailable: %@", error.localizedDescription) }
    }

    private func poll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in files where url.lastPathComponent.hasSuffix(".request.json") {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let data = try? Data(contentsOf: url), data.count < 16384 else { continue }
            try? FileManager.default.removeItem(at: url)
            let response = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("response.json")
            let reply: ([String: Any]) -> Void = { result in
                guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
                try? data.write(to: response, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: response.path)
            }
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let expiry = request["expires"] as? Double, expiry > Date().timeIntervalSince1970 else {
                    throw ControlError("Expired or invalid request")
                }
                try handle(request, reply: reply)
            } catch { reply(["ok": false, "error": error.localizedDescription]) }
        }
    }

    private func handle(_ r: [String: Any], reply: @escaping ([String: Any]) -> Void) throws {
        guard #available(macOS 15.0, *) else { throw ControlError("Recording requires macOS 15 or newer") }
        switch r["command"] as? String {
        case "status":
            var result = RecordingSession.current?.controlStatus ?? lastResult
            if starting { result["state"] = "starting" }
            result["ok"] = true
            reply(result)
        case "stop":
            guard let session = RecordingSession.current else { throw ControlError("No recording is active") }
            session.controlStops.append(reply)
            session.stop()
        case "mark":
            guard let session = RecordingSession.current else { throw ControlError("No recording is active") }
            guard let label = r["label"] as? String, !label.isEmpty, label.count <= 300 else { throw ControlError("A short marker label is required") }
            reply(session.mark(label))
        case "context":
            // What a screenshot taken now would be of: the frontmost normal window, or the
            // frontmost one of the named app. The same reading Send to T3 attaches.
            let wanted = (r["app"] as? String)?.lowercased()
            let windows = CaptureSession.onScreenAppWindows()
            guard let window = windows.first(where: { wanted == nil || $0.app.lowercased().contains(wanted!) }) else {
                throw ControlError(wanted == nil ? "No app window is on screen" : "No window of that app is on screen")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ScreenContextReader.read(window)
                var result: [String: Any] = ["ok": true, "app": context.app, "title": context.title]
                if let location = context.location { result["location"] = location }
                reply(result)
            }
        case "sources", "start":
            guard CGPreflightScreenCaptureAccess() else { throw ControlError("Grant QuickShot Screen Recording permission in System Settings, then relaunch it") }
            if r["command"] as? String == "start" {
                guard RecordingSession.current == nil, !starting, CaptureSession.current == nil else { throw ControlError("A recording or selection is already active") }
                starting = true
            }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                DispatchQueue.main.async {
                    defer { self.starting = false }
                    do {
                        guard let content = content else { throw error ?? ControlError("Cannot enumerate capture sources") }
                        if r["command"] as? String == "sources" {
                            reply(["ok": true, "displays": content.displays.map { d in
                                ["id": d.displayID, "x": d.frame.minX, "y": d.frame.minY,
                                 "width": d.frame.width, "height": d.frame.height] as [String: Any]
                            }, "windows": content.windows.filter { $0.windowLayer == 0 }.map { w in
                                ["id": w.windowID, "app": w.owningApplication?.applicationName ?? "",
                                 "title": w.title ?? "", "x": w.frame.minX, "y": w.frame.minY,
                                 "width": w.frame.width, "height": w.frame.height] as [String: Any]
                            }])
                        } else {
                            guard let expiry = r["expires"] as? Double, expiry > Date().timeIntervalSince1970 else { throw ControlError("Start request expired") }
                            try self.start(r, content: content, reply: reply)
                        }
                    } catch { reply(["ok": false, "error": error.localizedDescription]) }
                }
            }
        default: throw ControlError("Unknown command")
        }
    }

    @available(macOS 15.0, *)
    private func start(_ r: [String: Any], content: SCShareableContent, reply: @escaping ([String: Any]) -> Void) throws {
        guard RecordingSession.current == nil else { throw ControlError("A recording is already active") }
        guard let path = r["output"] as? String, path.hasPrefix("/"), path.hasSuffix(".mp4") else { throw ControlError("An absolute .mp4 output path is required") }
        let output = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: path + ".markers.json") else { throw ControlError("Output already exists; choose another filename") }
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path) else { throw ControlError("Output folder does not exist") }
        let display: SCDisplay
        let region: CGRect
        if let windowID = r["window"] as? UInt32 {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw ControlError("Window is not available") }
            let inset = r["insets"] as? [Double] ?? [0,0,0,0]
            guard inset.count == 4, inset.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw ControlError("Insets must be nonnegative top,right,bottom,left") }
            let rect = CGRect(x: window.frame.minX + inset[3], y: window.frame.minY + inset[0],
                              width: window.frame.width - inset[1] - inset[3], height: window.frame.height - inset[0] - inset[2])
            guard let d = content.displays.first(where: { $0.frame.contains(rect) }) else { throw ControlError("Capture region must fit on one display") }
            display = d
            region = rect.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        } else {
            guard let displayID = r["display"] as? UInt32, let d = content.displays.first(where: { $0.displayID == displayID }),
                  let values = r["rect"] as? [Double], values.count == 4, values.allSatisfy({ $0.isFinite }) else { throw ControlError("Supply a window or display and x,y,width,height") }
            display = d
            region = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        guard region.width >= 8, region.height >= 8,
              CGRect(origin: .zero, size: display.frame.size).contains(region) else { throw ControlError("Invalid or out-of-display capture region") }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { throw ControlError("Display is unavailable") }
        let scale = screen.backingScaleFactor
        let global = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
                            width: region.width, height: region.height)
        RecordingSession.begin(displayID: display.displayID, sourceRect: region,
            pixelSize: CGSize(width: max(2, Int(region.width * scale) & ~1), height: max(2, Int(region.height * scale) & ~1)),
            globalRegion: global, output: output, controlReply: reply)
    }
}

struct ControlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
