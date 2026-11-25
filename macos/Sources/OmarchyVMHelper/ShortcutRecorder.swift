import AppKit
import ApplicationServices

/// Records the next shortcut pressed while the app is active.
///
/// The shortcuts people want to keep are mostly ones macOS or another app
/// acts on before the key window sees them, such as Control-Right Arrow.
/// With Accessibility, an HID-level event tap sees them first and keeps
/// macOS from acting on them while recording; without it, a local monitor
/// records the rest.
@MainActor
final class ShortcutRecorder {
    enum Press: Equatable {
        case shortcut(keyCode: Int, modifiers: ShortcutModifiers)
        case needsModifier
        case cancel
    }

    private var handler: ((KeptShortcut?) -> Void)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var swallowedKeys = Set<Int64>()

    var isRecording: Bool { handler != nil }

    /// Calls `handler` once: with the shortcut, or nil when cancelled.
    func start(_ handler: @escaping (KeptShortcut?) -> Void) {
        stop()
        self.handler = handler
        if !installTap() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(keyCode: Int(event.keyCode), flags: event.modifierFlags)
                return nil
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    func stop() {
        removeTap()
        endRecording()
    }

    /// A shortcut needs Control, Option or Command, so typing in Omarchy
    /// keeps working, capitals included; Escape alone cancels.
    nonisolated static func classify(keyCode: Int, flags: NSEvent.ModifierFlags) -> Press {
        let modifiers = ShortcutModifiers(flags)
        if modifiers.isDisjoint(with: [.control, .option, .command]) {
            return keyCode == 53 && modifiers.isEmpty ? .cancel : .needsModifier
        }
        return .shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private func handle(keyCode: Int, flags: NSEvent.ModifierFlags) {
        switch Self.classify(keyCode: keyCode, flags: flags) {
        case .cancel:
            finish(nil)
        case .needsModifier:
            NSSound.beep()
        case let .shortcut(keyCode, modifiers):
            var shortcut = KeptShortcut(
                keyCode: keyCode, modifiers: modifiers, key: KeyLabels.label(keyCode: keyCode)
            )
            shortcut.name = MacSystemShortcuts.name(of: shortcut)
            finish(shortcut)
        }
    }

    /// The tap stays until the recorded key is released, so its repeats
    /// and key up can't act on macOS or the launcher. The handler runs
    /// after the tap callback returns, so resizing the sheet can't hold up
    /// the Mac's keyboard.
    private func finish(_ shortcut: KeptShortcut?) {
        guard let handler else { return }
        endRecording()
        if swallowedKeys.isEmpty { removeTap() }
        DispatchQueue.main.async { handler(shortcut) }
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        handler = nil
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        swallowedKeys.removeAll()
    }

    private func installTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue) | (UInt64(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated { recorder.handleTap(type: type, event: event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            let swallowed = swallowedKeys.remove(keyCode) != nil
            if !isRecording && swallowedKeys.isEmpty { removeTap() }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }
        if swallowedKeys.contains(keyCode) { return nil }
        guard NSApp.isActive, isRecording else { return Unmanaged.passUnretained(event) }
        swallowedKeys.insert(keyCode)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            handle(keyCode: Int(keyCode), flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        }
        return nil
    }
}
