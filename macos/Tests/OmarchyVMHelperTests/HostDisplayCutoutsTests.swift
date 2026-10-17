import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Host display cutouts")
struct HostDisplayCutoutsTests {
    // A 14-inch MacBook Pro's built-in modes, in pixels, as macOS lists them.
    private let modes: [(width: Int, height: Int)] = [
        (1920, 1200), (2048, 1280), (2048, 1330), (2294, 1432), (2294, 1490), (2560, 1600),
        (2704, 1690), (2704, 1756), (3024, 1890), (3024, 1964), (3600, 2250), (3600, 2338),
    ]

    @Test("every mode that reaches the top edge gets the housing, scaled up to whole rows")
    func panelModes() {
        let cutouts = HostDisplayCutouts.cutouts(modes: modes, current: (3024, 1964), currentTop: 64)
        #expect(cutouts == [
            HostDisplayCutout(width: 3600, height: 2338, top: 77),
            HostDisplayCutout(width: 3024, height: 1964, top: 64),
            HostDisplayCutout(width: 2704, height: 1756, top: 58),
            HostDisplayCutout(width: 2294, height: 1490, top: 49),
            HostDisplayCutout(width: 2048, height: 1330, top: 44),
        ])
        #expect(HostDisplayCutouts.line(cutouts) ==
            "3600x2338:77,3024x1964:64,2704x1756:58,2294x1490:49,2048x1330:44")
    }

    @Test("the same answer from any panel mode with the housing")
    func fromAScaledMode() {
        let cutouts = HostDisplayCutouts.cutouts(modes: modes, current: (3600, 2338), currentTop: 76)
        #expect(cutouts.first == HostDisplayCutout(width: 3600, height: 2338, top: 76))
        #expect(cutouts.contains(HostDisplayCutout(width: 3024, height: 1964, top: 64)))
    }

    @Test("modes below the camera and duplicate modes are left out")
    func belowTheCamera() {
        let cutouts = HostDisplayCutouts.cutouts(modes: modes + modes, current: (3024, 1964), currentTop: 64)
        #expect(!cutouts.contains { $0.height == 1890 || $0.height == 1200 || $0.height == 1600 })
        #expect(Set(cutouts.map(\.token)).count == cutouts.count)
    }

    @Test("no housing, no cutouts")
    func withoutAHousing() {
        #expect(HostDisplayCutouts.cutouts(modes: modes, current: (3024, 1964), currentTop: 0).isEmpty)
        #expect(HostDisplayCutouts.cutouts(modes: modes, current: (0, 0), currentTop: 64).isEmpty)
        #expect(HostDisplayCutouts.line([]) == "")
    }

    @Test("a Mac whose panel can't be measured now repeats the last measurement")
    @MainActor
    func remembered() throws {
        let suite = "dev.tryomarchy.tests.cutouts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("3024x1964:64", forKey: HostDisplayCutouts.defaultsKey)
        let detected = HostDisplayCutouts.detect(defaults: defaults)
        // On a Mac with a measurable notch this is a fresh line; elsewhere the stored one.
        #expect(!detected.isEmpty)
        #expect(defaults.string(forKey: HostDisplayCutouts.defaultsKey) == detected)
    }
}
