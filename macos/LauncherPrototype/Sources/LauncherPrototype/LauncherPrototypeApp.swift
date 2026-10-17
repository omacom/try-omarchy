import AppKit
import SwiftUI

@main
struct LauncherPrototypeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: PrototypeAppDelegate
    @State private var model = LauncherModel()

    var body: some Scene {
        Window("Try Omarchy", id: "launcher") {
            LauncherView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 600)
        .commands { PreviewCommands(model: model) }

        Window("Try Omarchy Updates", id: "updates") {
            UpdatesView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowResizability(.contentSize)
    }
}

final class PrototypeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable; make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = Self.renderIcon()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor private static func renderIcon() -> NSImage? {
        let renderer = ImageRenderer(content: OmarchyAppTile(size: 820).padding(102))
        renderer.scale = 1
        return renderer.nsImage
    }
}

/// A menu for reviewing every launcher state without a real VM.
struct PreviewCommands: Commands {
    @Bindable var model: LauncherModel

    var body: some Commands {
        CommandMenu("Preview") {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(PreviewAppearance.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Configuration", selection: Binding(
                get: { model.preset },
                set: { model.applyPreset($0) }
            )) {
                ForEach(PreviewPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("VM State", selection: $model.previewRunState) {
                ForEach(PreviewRunState.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Picker("Microphone", selection: $model.microphone) {
                ForEach(PermissionState.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Camera", selection: $model.camera) {
                ForEach(PermissionState.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Simulate VM Move") { model.moveStorage() }
        }
    }
}
