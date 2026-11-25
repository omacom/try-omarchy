import AppKit

/// One of the Mac's displays as AppKit places it, in its global point
/// coordinates, with the Y axis pointing up. The main display is the one
/// with the menu bar, AppKit's first. `topInset` is the camera strip full
/// screen stays out of (Camera notch off), which the guest's output then
/// does not cover.
struct HostDisplay: Equatable {
    let frame: CGRect
    let isBuiltin: Bool
    let isMain: Bool
    let topInset: CGFloat

    init(frame: CGRect, isBuiltin: Bool, isMain: Bool = false, topInset: CGFloat = 0) {
        self.frame = frame
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.topInset = topInset
    }

    /// The part of the display the guest's output covers.
    var area: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, frame.height - topInset))
    }
}

/// Where a guest output sits, in Hyprland's logical pixels from the top-left
/// corner of the rectangle enclosing every display.
struct HostDisplayPlacement: Equatable {
    let output: String
    let x: Int
    let y: Int

    var token: String { "\(output):\(x)x\(y)" }
}

/// The Mac's display arrangement, for one virtio-gpu head per display in
/// immersive mode: `tryomarchy.display_layout` tokens, the main display
/// first, so Omarchy's first output, its boot messages and its first-boot
/// setup are where macOS keeps its menu bar. Each head's scale follows its
/// display's backing scale, so the Mac's points are the guest's logical pixels
/// and the arrangement from System Settings carries over as it is. A
/// display's whole panel counts, camera housing included; the guest keeps its
/// bar beside the housing on its own, on the output `tryomarchy.display_panel`
/// names.
enum HostDisplayLayout {
    static let maximumDisplays = 4

    /// The main display first, then the others left to right and top to
    /// bottom, up to `maximumDisplays`. Mirrored displays arrive as one.
    static func chosen(_ displays: [HostDisplay]) -> [HostDisplay] {
        let usable = displays.filter { $0.area.width > 0 && $0.area.height > 0 }
        let main = usable.first(where: \.isMain).map { [$0] } ?? []
        let others = usable.filter { !main.contains($0) }
            .sorted { ($0.area.minX, -$0.area.maxY) < ($1.area.minX, -$1.area.maxY) }
        return Array((main + others).prefix(maximumDisplays))
    }

    static func placements(_ displays: [HostDisplay]) -> [HostDisplayPlacement] {
        let chosen = chosen(displays)
        guard let first = chosen.first else { return [] }
        let enclosing = chosen.dropFirst().reduce(first.area) { $0.union($1.area) }
        return chosen.enumerated().map { index, display in
            HostDisplayPlacement(
                output: "Virtual-\(index + 1)",
                x: Int((display.area.minX - enclosing.minX).rounded()),
                y: Int((enclosing.maxY - display.area.maxY).rounded())
            )
        }
    }

    /// The tokens for tryomarchy.display_layout ("Virtual-1:0x458,Virtual-2:1512x0"), or "".
    static func line(_ placements: [HostDisplayPlacement]) -> String {
        placements.map(\.token).joined(separator: ",")
    }

    /// The built-in panel's output ("Virtual-2"), whose bar keeps clear of the
    /// camera housing, or "" when the panel is not among the displays.
    static func panelOutput(_ displays: [HostDisplay]) -> String {
        guard let index = chosen(displays).firstIndex(where: \.isBuiltin) else { return "" }
        return "Virtual-\(index + 1)"
    }

    /// The first display's size in pixels ("3024x1964"), for the guest's
    /// first mode: Linux sizes its console when it probes the GPU and keeps
    /// that size, so the size has to be there before full screen reports it.
    /// "" without a display.
    static func pixels(_ displays: [HostDisplay], scales: [CGFloat]) -> String {
        guard let first = chosen(displays).first, let index = displays.firstIndex(of: first),
              index < scales.count else {
            return ""
        }
        let scale = max(scales[index], 1)
        return "\(Int((first.area.width * scale).rounded()))x\(Int((first.area.height * scale).rounded()))"
    }

    /// Every display, or the main one alone when macOS keeps full screen to
    /// one display at a time (Displays have separate Spaces, off). AppKit
    /// answers that question only once the application exists; the helper
    /// runs this as a plain command.
    @MainActor
    static func detect(notch: Bool) -> String {
        _ = NSApplication.shared
        let displays = hostDisplays(notch: notch)
        guard NSScreen.screensHaveSeparateSpaces else {
            return line(placements(Array(displays.prefix(1))))
        }
        return line(placements(displays))
    }

    @MainActor
    static func detectPanel() -> String {
        panelOutput(hostDisplays(notch: true))
    }

    @MainActor
    static func detectPixels(notch: Bool) -> String {
        pixels(hostDisplays(notch: notch), scales: NSScreen.screens.map(\.backingScaleFactor))
    }

    /// With Camera notch off, full screen on the built-in panel stays below
    /// the camera strip, so its output is that much shorter.
    @MainActor
    private static func hostDisplays(notch: Bool) -> [HostDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let builtin = number.map { CGDisplayIsBuiltin(CGDirectDisplayID($0.uint32Value)) != 0 } ?? false
            let inset = builtin && !notch ? max(0, screen.safeAreaInsets.top) : 0
            return HostDisplay(frame: screen.frame, isBuiltin: builtin, isMain: index == 0, topInset: inset)
        }
    }
}
