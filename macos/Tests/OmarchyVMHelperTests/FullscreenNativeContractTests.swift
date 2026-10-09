import Foundation
import Testing

@Suite("Immersive presentation native contract")
struct FullscreenNativeContractTests {
    @Test("Runner keeps focused keyboard capture independent of presentation")
    func runnerMapping() throws {
        let runner = try source(named: "run-qemu-gpu.sh")

        #expect(runner.contains("case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in"))
        #expect(runner.contains("cocoa_full_screen=on\n    cocoa_immersive=on"))
        #expect(runner.contains("cocoa_full_screen=off\n    cocoa_immersive=off"))
        #expect(runner.contains("OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1"))
        #expect(runner.contains(
            "full-screen=$cocoa_full_screen,full-grab=on,immersive=$cocoa_immersive,swap-opt-cmd=off"
        ))
        #expect(!runner.contains("cocoa_full_grab"))
        #expect(runner.contains("host_keys=${OMARCHY_QEMU_GPU_HOST_KEYS-131,144,145,160,176,177,178}"))
        #expect(runner.contains("grep -Fq 'host-keys=code'"))
        #expect(runner.contains("swap-opt-cmd=off$cocoa_host_keys$cocoa_media_keys\""))
        #expect(runner.contains("case ${OMARCHY_QEMU_GPU_MEDIA_KEYS:-0} in"))
        #expect(runner.contains("grep -Fq 'media-keys=on|off'"))
    }

    @Test("Cocoa separates fullscreen presentation from focused keyboard capture")
    func cocoaBehavior() throws {
        let immersivePatch = try source(named: "patches/qemu-cocoa-immersive-mode.patch")
        let keyboardPatch = try source(named: "patches/qemu-cocoa-full-grab-focus.patch")

        #expect(immersivePatch.contains("'*immersive': 'bool'"))
        #expect(immersivePatch.contains("if (!immersive_mode_enabled)"))
        #expect(immersivePatch.contains("return proposedOptions;"))
        #expect(immersivePatch.contains("[fullScreenMenuItem setTitle:@\"Exit Full Screen\"]"))
        #expect(immersivePatch.contains("[fullScreenMenuItem setTitle:@\"Enter Full Screen\"]"))

        let fileScopeState = [
            " static bool swap_opt_cmd;",
            "+static bool full_grab_enabled;",
            "+static bool immersive_mode_enabled = true;",
            "+static NSMenuItem *fullScreenMenuItem;",
            " ",
            " static bool zoom_interpolation;",
        ].joined(separator: "\n")
        #expect(immersivePatch.contains(fileScopeState))
        #expect(!immersivePatch.contains("+    NSMenuItem *fullScreenMenuItem;"))

        #expect(keyboardPatch.contains(
            "return isMouseGrabbed ||\n" +
            "+           (full_grab_enabled && [[self window] isKeyWindow]);"
        ))
        #expect(keyboardPatch.contains("if ([view isKeyboardCaptured]"))
        #expect(keyboardPatch.contains("if (![self isKeyboardCaptured]"))

        let configuration = try #require(
            immersivePatch.range(of: "immersive_mode_enabled = !opts->u.cocoa.has_immersive")
        )
        let fullScreenEntry = try #require(
            immersivePatch.range(of: "[[cocoaView window] toggleFullScreen: nil]")
        )
        #expect(configuration.lowerBound < fullScreenEntry.lowerBound)
    }

    @Test("Cocoa recovers the full grab tap after macOS disables it")
    func tapRecovery() throws {
        let patch = try source(named: "patches/qemu-cocoa-full-grab-reenable.patch")

        // Both ways macOS can switch a tap off must be handled; handling only
        // the timeout leaves the tap dead after a user-input disable.
        #expect(patch.contains("type == kCGEventTapDisabledByTimeout ||"))
        #expect(patch.contains("type == kCGEventTapDisabledByUserInput"))
        #expect(patch.contains("[view reenableEventTap];"))
        #expect(patch.contains("CGEventTapEnable(eventsTap, true);"))

        // The guard has to run before +[NSEvent eventWithCGEvent:], which
        // returns nil for a disable notification and would otherwise swallow
        // it as an unhandled event.
        let guardClause = try #require(patch.range(of: "kCGEventTapDisabledByTimeout"))
        let eventConversion = try #require(
            patch.range(of: "NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];")
        )
        #expect(guardClause.lowerBound < eventConversion.lowerBound)
    }

    @Test("Runtime build applies the tap recovery after the full grab patch")
    func tapRecoveryIsBuilt() throws {
        let builder = try source(named: "build-qemu-gpu-runtime.sh")

        #expect(builder.contains(
            "reenable_patch=\"$native_dir/patches/qemu-cocoa-full-grab-reenable.patch\""
        ))
        #expect(builder.contains("verify_file_sha \"Try Omarchy Cocoa full-grab re-enable patch\""))

        // It edits handleTapEvent after the full-grab patch rewrites it, so the
        // order of the two patch invocations is part of the contract.
        let fullGrab = try #require(
            builder.range(of: "patch -d \"$source_dir\" -p1 -f -i \"$full_grab_patch\"")
        )
        let reenable = try #require(
            builder.range(of: "patch -d \"$source_dir\" -p1 -f -i \"$reenable_patch\"")
        )
        #expect(fullGrab.lowerBound < reenable.lowerBound)
    }

    @Test("Runtime build applies the host-keys pass-through after the tap recovery")
    func hostKeysAreBuilt() throws {
        let builder = try source(named: "build-qemu-gpu-runtime.sh")
        #expect(builder.contains(
            "host_keys_patch=\"$native_dir/patches/qemu-cocoa-host-keys.patch\""
        ))
        let reenable = try #require(
            builder.range(of: "patch -d \"$source_dir\" -p1 -f -i \"$reenable_patch\"")
        )
        let hostKeys = try #require(
            builder.range(of: "patch -d \"$source_dir\" -p1 -f -i \"$host_keys_patch\"")
        )
        #expect(reenable.lowerBound < hostKeys.lowerBound)
    }

    @Test("Runtime build applies the media-keys patch after host-keys")
    func mediaKeysAreBuilt() throws {
        let builder = try source(named: "build-qemu-gpu-runtime.sh")
        #expect(builder.contains(
            "media_keys_patch=\"$native_dir/patches/qemu-cocoa-media-keys.patch\""
        ))
        let hostKeys = try #require(
            builder.range(of: "patch -d \"$source_dir\" -p1 -f -i \"$host_keys_patch\"")
        )
        let mediaKeys = try #require(
            builder.range(of: "patch -d \"$source_dir\" -p1 -f -i \"$media_keys_patch\"")
        )
        #expect(hostKeys.lowerBound < mediaKeys.lowerBound)
    }

    private func source(named relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let macosDirectory = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macosDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
