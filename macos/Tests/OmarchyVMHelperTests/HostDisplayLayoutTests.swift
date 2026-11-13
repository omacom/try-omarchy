import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Host display layout")
struct HostDisplayLayoutTests {
    // A 14-inch MacBook Pro panel, the main display, and a 27-inch display,
    // in points. AppKit puts the main display at the origin with Y pointing up.
    private let panel = HostDisplay(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true, isMain: true)

    private func external(x: CGFloat, y: CGFloat, main: Bool = false) -> HostDisplay {
        HostDisplay(frame: CGRect(x: x, y: y, width: 2560, height: 1440), isBuiltin: false, isMain: main)
    }

    @Test("a display to the right, bottoms aligned: the panel sits lower in the guest")
    func toTheRight() {
        let placements = HostDisplayLayout.placements([panel, external(x: 1512, y: 0)])
        #expect(HostDisplayLayout.line(placements) == "Virtual-1:0x458,Virtual-2:1512x0")
    }

    @Test("a display above, centred: the guest's origin is the display's top-left corner")
    func above() {
        let placements = HostDisplayLayout.placements([panel, external(x: -524, y: 982)])
        #expect(HostDisplayLayout.line(placements) == "Virtual-1:524x1440,Virtual-2:0x0")
    }

    @Test("a display to the left, tops aligned")
    func toTheLeft() {
        let placements = HostDisplayLayout.placements([panel, external(x: -2560, y: -458)])
        #expect(HostDisplayLayout.line(placements) == "Virtual-1:2560x0,Virtual-2:0x0")
    }

    @Test("a display below, left edges aligned")
    func below() {
        let placements = HostDisplayLayout.placements([panel, external(x: 0, y: -1440)])
        #expect(HostDisplayLayout.line(placements) == "Virtual-1:0x0,Virtual-2:0x982")
    }

    @Test("the main display is Virtual-1 wherever AppKit lists it; the rest go left to right")
    func order() {
        let placements = HostDisplayLayout.placements([
            external(x: 1512, y: 0), external(x: -2560, y: 0), panel,
        ])
        #expect(placements.map(\.output) == ["Virtual-1", "Virtual-2", "Virtual-3"])
        #expect(HostDisplayLayout.line(placements) == "Virtual-1:2560x458,Virtual-2:0x0,Virtual-3:4072x0")
    }

    @Test("an external display as the main display is Virtual-1, and the panel keeps the camera housing")
    func externalMain() {
        let notMain = HostDisplay(frame: CGRect(x: 248, y: -982, width: 1512, height: 982), isBuiltin: true)
        let displays = [external(x: 0, y: 0, main: true), notMain]
        #expect(HostDisplayLayout.line(HostDisplayLayout.placements(displays)) == "Virtual-1:0x0,Virtual-2:248x1440")
        #expect(HostDisplayLayout.panelOutput(displays) == "Virtual-2")
        #expect(HostDisplayLayout.pixels(displays, scales: [1, 2]) == "2560x1440")
    }

    @Test("with Camera notch off the panel's output stops above the strip, so a display below still meets it")
    func notchOff() {
        let belowTheStrip = HostDisplay(frame: panel.frame, isBuiltin: true, isMain: true, topInset: 32)
        let displays = [belowTheStrip, external(x: 0, y: -1440)]
        #expect(HostDisplayLayout.line(HostDisplayLayout.placements(displays)) == "Virtual-1:0x0,Virtual-2:0x950")
        #expect(HostDisplayLayout.pixels(displays, scales: [2, 1]) == "3024x1900")
        let above = [belowTheStrip, external(x: -524, y: 982)]
        #expect(HostDisplayLayout.line(HostDisplayLayout.placements(above)) == "Virtual-1:524x1472,Virtual-2:0x0")
    }

    @Test("the panel's output is named only while the panel is among the displays")
    func panelOutput() {
        #expect(HostDisplayLayout.panelOutput([panel, external(x: 1512, y: 0)]) == "Virtual-1")
        #expect(HostDisplayLayout.panelOutput([panel]) == "Virtual-1")
        #expect(HostDisplayLayout.panelOutput([external(x: 0, y: 0, main: true)]) == "")
        #expect(HostDisplayLayout.panelOutput([]) == "")
    }

    @Test("one display, or none, needs no arrangement")
    func alone() {
        #expect(HostDisplayLayout.line(HostDisplayLayout.placements([panel])) == "Virtual-1:0x0")
        #expect(HostDisplayLayout.line(HostDisplayLayout.placements([external(x: 100, y: 100)])) == "Virtual-1:0x0")
        #expect(HostDisplayLayout.placements([]).isEmpty)
        #expect(HostDisplayLayout.line([]) == "")
    }

    @Test("at most four displays, and empty frames are left out")
    func limits() {
        var displays = [panel, HostDisplay(frame: .zero, isBuiltin: false)]
        for index in 1...5 {
            displays.append(external(x: CGFloat(index) * 2560, y: 0))
        }
        let placements = HostDisplayLayout.placements(displays)
        #expect(placements.count == HostDisplayLayout.maximumDisplays)
        #expect(placements.last?.token == "Virtual-4:7680x0")
    }

    @Test("the first display's pixels come from its points and backing scale, the main display first")
    func pixels() {
        let external = external(x: 1512, y: 0)
        #expect(HostDisplayLayout.pixels([external, panel], scales: [1, 2]) == "3024x1964")
        #expect(HostDisplayLayout.pixels([external], scales: [1]) == "2560x1440")
        #expect(HostDisplayLayout.pixels([external, panel], scales: [1, 2]) == "3024x1964")
        #expect(HostDisplayLayout.pixels([panel], scales: [0]) == "1512x982")
        #expect(HostDisplayLayout.pixels([], scales: []) == "")
        #expect(HostDisplayLayout.pixels([panel], scales: []) == "")
    }

    @Test("the live arrangement is a list of placements, or nothing without a display")
    @MainActor
    func detected() throws {
        let detected = HostDisplayLayout.detect(notch: true)
        let placement = #"Virtual-[1-4]:[0-9]{1,5}x[0-9]{1,5}"#
        #expect(detected.isEmpty || detected.range(of: "^\(placement)(,\(placement)){0,3}$", options: .regularExpression) != nil)
    }
}
