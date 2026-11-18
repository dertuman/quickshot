import Cocoa
import AVFoundation
import ScreenCaptureKit

/// What a recording captures besides the screen. The toolbar choice is remembered between recordings.
struct AudioChoice {
    var mic: AVCaptureDevice?
    var system: Bool
    static let none = AudioChoice(mic: nil, system: false)
}

enum RecordingAudio {
    private static let micKey = "recordMicrophone"
    private static let systemKey = "recordSystemAudio"

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }

    /// The saved microphone, when it is connected and allowed. A disconnected one stays saved for next time.
    static var mic: AVCaptureDevice? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let id = UserDefaults.standard.string(forKey: micKey) else { return nil }
        return microphones.first { $0.uniqueID == id }
    }

    static var systemAudio: Bool {
        get { UserDefaults.standard.bool(forKey: systemKey) }
        set { UserDefaults.standard.set(newValue, forKey: systemKey) }
    }

    static var saved: AudioChoice { AudioChoice(mic: mic, system: systemAudio) }

    // MARK: Toolbar controls

    static func micPopup(target: AnyObject, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = target
        popup.action = action
        popup.toolTip = "Microphone to record"
        fillMicMenu(popup)
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        return popup
    }

    static func fillMicMenu(_ popup: NSPopUpButton) {
        let menu = popup.menu!
        menu.removeAllItems()
        let off = NSMenuItem(title: "No mic", action: nil, keyEquivalent: "")
        off.image = symbol("mic.slash")
        menu.addItem(off)
        let denied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        if denied {
            let allow = NSMenuItem(title: "Allow Microphone Access…", action: nil, keyEquivalent: "")
            allow.representedObject = "settings"
            menu.addItem(allow)
        } else {
            for device in microphones {
                let item = NSMenuItem(title: device.localizedName, action: nil, keyEquivalent: "")
                item.image = symbol("mic.fill")
                item.representedObject = device.uniqueID
                menu.addItem(item)
            }
        }
        let current = mic?.uniqueID
        popup.selectItem(at: max(0, menu.items.firstIndex { ($0.representedObject as? String) == current && current != nil } ?? 0))
    }

    static func systemPopup(target: AnyObject, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = target
        popup.action = action
        popup.toolTip = "Sound playing on this Mac"
        let off = NSMenuItem(title: "No computer audio", action: nil, keyEquivalent: "")
        off.image = symbol("speaker.slash")
        let on = NSMenuItem(title: "Computer audio", action: nil, keyEquivalent: "")
        on.image = symbol("speaker.wave.2.fill")
        popup.menu!.addItem(off)
        popup.menu!.addItem(on)
        popup.selectItem(at: systemAudio ? 1 : 0)
        return popup
    }

    /// Saves the picked microphone, asking for access the first time.
    static func choose(micFrom popup: NSPopUpButton, onSettings: () -> Void) {
        let id = popup.selectedItem?.representedObject as? String
        if id == "settings" {
            popup.selectItem(at: 0)
            onSettings()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        UserDefaults.standard.set(id, forKey: micKey)
        guard id != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { fillMicMenu(popup) }
        }
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// Peak level of an audio buffer, 0...1 on a 50 dB scale.
    static func level(_ buffer: CMSampleBuffer) -> Float {
        guard let format = buffer.formatDescription?.audioStreamBasicDescription else { return 0 }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        try? buffer.withAudioBufferList { list, _ in
            for b in list {
                guard let data = b.mData else { continue }
                if isFloat {
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(b.mDataByteSize) / 4 { peak = max(peak, abs(p[i])) }
                } else if format.mBitsPerChannel == 16 {
                    let p = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<Int(b.mDataByteSize) / 2 { peak = max(peak, abs(Float(p[i]) / 32768)) }
                }
            }
        }
        guard peak > 0 else { return 0 }
        return max(0, min(1, (20 * log10(peak) + 50) / 50))
    }
}

// MARK: - Recording HUD

final class LevelMeter: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 48, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        guard level > 0 else { return }
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * CGFloat(level), height: bounds.height),
                     xRadius: 3, yRadius: 3).fill()
    }
}

/// Shows what is being captured, with live levels, and a Stop button. Recordings exclude QuickShot's
/// own windows, so it never appears in the video.
final class RecordingHUD: NSObject {
    private let panel: NSPanel
    private var meters: [SCStreamOutputType: LevelMeter] = [:]
    private let onStop: () -> Void

    init(region: NSRect, audio: AudioChoice, onStop: @escaping () -> Void) {
        self.onStop = onStop
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        var views: [NSView] = []
        func source(_ symbol: String, _ tip: String, _ type: SCStreamOutputType) {
            let icon = NSImageView(image: RecordingAudio.symbol(symbol)!)
            icon.contentTintColor = .white
            let meter = LevelMeter()
            meters[type] = meter
            let pair = NSStackView(views: [icon, meter])
            pair.spacing = 5
            pair.toolTip = tip
            views.append(pair)
        }
        if let mic = audio.mic { source("mic.fill", mic.localizedName, .microphone) }
        if audio.system { source("speaker.wave.2.fill", "Computer audio", .audio) }
        if views.isEmpty {
            let icon = NSImageView(image: RecordingAudio.symbol("speaker.slash")!)
            icon.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: "No audio")
            label.textColor = .secondaryLabelColor
            let pair = NSStackView(views: [icon, label])
            pair.spacing = 5
            views.append(pair)
        }
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopPressed))
        stop.image = RecordingAudio.symbol("stop.fill")
        stop.imagePosition = .imageLeading
        stop.bezelStyle = .rounded
        stop.toolTip = "Stop recording (fn+⌃)"
        views.append(stop)

        let stack = NSStackView(views: views)
        stack.spacing = 14
        let fit = stack.fittingSize
        let pad: CGFloat = 6
        let size = NSSize(width: fit.width + pad * 2 + 6, height: fit.height + pad * 2)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.9).cgColor
        content.layer?.cornerRadius = 9
        stack.frame = NSRect(x: pad + 6, y: pad, width: fit.width, height: fit.height)
        content.addSubview(stack)

        // Below the recorded region, outside its red border, or inside its bottom edge when there's no room.
        let visible = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: region.midX, y: region.midY)) } ?? NSScreen.main)?.visibleFrame ?? region
        var origin = NSPoint(x: region.midX - size.width / 2, y: region.minY - 6 - 8 - size.height)
        if origin.y < visible.minY + 8 { origin.y = max(visible.minY, region.minY) + 12 }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))

        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
    }

    func show() { panel.orderFrontRegardless() }

    /// Replaces the levels with a spinner the moment Stop is pressed, so it never looks stuck.
    func showSaving() {
        guard let content = panel.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Saving…")
        label.textColor = .white
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 8
        let fit = stack.fittingSize
        stack.frame = NSRect(x: (content.bounds.width - fit.width) / 2, y: (content.bounds.height - fit.height) / 2,
                             width: fit.width, height: fit.height)
        content.addSubview(stack)
    }
    func close() { panel.orderOut(nil) }

    /// Called on the main thread; the meter falls back gently so speech reads as a steady bar.
    func update(_ type: SCStreamOutputType, level: Float) {
        guard let meter = meters[type] else { return }
        meter.level = max(level, meter.level * 0.8)
    }

    @objc private func stopPressed() { onStop() }
}
