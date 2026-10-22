import Carbon

enum HostCapsLockInput {
    static let koreanInputSourcePrefix = "com.apple.inputmethod.Korean"

    static func mode(enabledInputSourceIDs: [String]) -> String {
        enabledInputSourceIDs.contains { $0.hasPrefix(koreanInputSourcePrefix) } ? "hangul" : ""
    }

    static func detect() -> String {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return ""
        }
        let identifiers = list.compactMap { source -> String? in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        return mode(enabledInputSourceIDs: identifiers)
    }
}
