import AppKit

/// The camera housing at the top of the Mac's built-in panel, as Omarchy's
/// display-cutouts.json describes a panel: the guest mode in physical pixels
/// and the rows the housing covers. QEMU's full screen covers the strip
/// beside the housing (qemu-cocoa-notch.patch) and offers the guest the
/// display's whole backing size, so the guest's mode is one of these sizes
/// exactly when the VM fills the panel; a window or an external display
/// never matches, and Omarchy's bar stays as it is there.
struct HostDisplayCutout: Equatable {
    let width: Int
    let height: Int
    let top: Int

    var token: String { "\(width)x\(height):\(top)" }
}

enum HostDisplayCutouts {
    static let defaultsKey = "HostDisplayCutouts"

    /// Every mode of the panel that reaches its top edge (the current mode's
    /// aspect; the shorter modes sit below the camera and have no housing),
    /// with the housing scaled from the current mode. The housing is one
    /// physical size, and each mode's pixels span the whole panel.
    static func cutouts(modes: [(width: Int, height: Int)], current: (width: Int, height: Int),
                        currentTop: Int) -> [HostDisplayCutout] {
        guard current.width > 0, current.height > 0, currentTop > 0, currentTop < current.height else {
            return []
        }
        var seen = Set<String>()
        var result: [HostDisplayCutout] = []
        for mode in modes + [current] where mode.width > 0 && mode.height > 0 {
            let skew = abs(mode.width * current.height - mode.height * current.width)
            guard Double(skew) <= 0.005 * Double(current.width * mode.height) else { continue }
            let top = Int((Double(currentTop) * Double(mode.height) / Double(current.height) - 0.001).rounded(.up))
            let cutout = HostDisplayCutout(width: mode.width, height: mode.height, top: top)
            if seen.insert(cutout.token).inserted {
                result.append(cutout)
            }
        }
        return result.sorted { ($0.width, $0.height) > ($1.width, $1.height) }
    }

    /// The tokens for tryomarchy.display_cutouts ("3024x1964:64,..."), or "".
    static func line(_ cutouts: [HostDisplayCutout]) -> String {
        cutouts.map(\.token).joined(separator: ",")
    }

    /// Measured on the built-in panel when it shows a mode with the housing;
    /// otherwise (the lid closed, a mode below the camera, a Mac without a
    /// notch) the last measurement, if there was one.
    @MainActor
    static func detect(defaults: UserDefaults = .standard) -> String {
        if let measured = measure() {
            let value = line(measured)
            defaults.set(value, forKey: defaultsKey)
            return value
        }
        return defaults.string(forKey: defaultsKey) ?? ""
    }

    /// Whether this Mac's built-in panel has a camera notch: measured now, or
    /// measured before (the lid may be closed while the launcher shows).
    @MainActor
    static func macHasNotch(defaults: UserDefaults = .standard) -> Bool {
        measure() != nil || !(defaults.string(forKey: defaultsKey) ?? "").isEmpty
    }

    @MainActor
    private static func measure() -> [HostDisplayCutout]? {
        let builtin = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDisplayIsBuiltin(CGDirectDisplayID($0.uint32Value)) != 0 } ?? false
        }
        guard let screen = builtin,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              screen.auxiliaryTopLeftArea != nil, screen.safeAreaInsets.top > 0 else {
            return nil
        }
        let display = CGDirectDisplayID(number.uint32Value)
        let scale = screen.backingScaleFactor
        let current = (width: Int((screen.frame.width * scale).rounded()),
                       height: Int((screen.frame.height * scale).rounded()))
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? [])
            .map { (width: $0.pixelWidth, height: $0.pixelHeight) }
        let top = Int((screen.safeAreaInsets.top * scale).rounded(.up))
        let measured = cutouts(modes: modes, current: current, currentTop: top)
        return measured.isEmpty ? nil : measured
    }
}
