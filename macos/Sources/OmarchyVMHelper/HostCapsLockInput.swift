import Carbon

enum HostCapsLockInput {
    static let koreanInputSourcePrefix = "com.apple.inputmethod.Korean"

    struct Source {
        let id: String
        let isInputMode: Bool
        let isASCIICapable: Bool
    }

    /// `hangul` when Korean is the Mac's only input method that cannot type ASCII,
    /// `input-method` when there are others, nothing without one.
    static func mode(enabledInputSources: [Source]) -> String {
        let inputMethods = enabledInputSources.filter { $0.isInputMode && !$0.isASCIICapable }
        if inputMethods.isEmpty {
            return ""
        }
        return inputMethods.allSatisfy { $0.id.hasPrefix(koreanInputSourcePrefix) } ? "hangul" : "input-method"
    }

    static func detect() -> String {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return ""
        }
        let sources = list.compactMap { source -> Source? in
            guard let id = property(source, kTISPropertyInputSourceID) as? String else { return nil }
            return Source(id: id,
                          isInputMode: property(source, kTISPropertyInputSourceType) as? String == kTISTypeKeyboardInputMode as String,
                          isASCIICapable: property(source, kTISPropertyInputSourceIsASCIICapable) as? Bool ?? true)
        }
        return mode(enabledInputSources: sources)
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
