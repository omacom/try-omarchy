import Foundation

/// Apple dictation needs SpeechAnalyzer: the macOS 26 SDK to build it and
/// macOS 26 to run it. Anything else ships without the feature: no port, no
/// helper and no Settings row (docs/host-dictation.md).
enum DictationSupport {
    /// Xcode 26 ships Swift 6.2 with the macOS 26 SDK; Xcode 16 builds (CI's
    /// macos-15 job) leave the recogniser out.
    static var isCompiledIn: Bool {
        #if compiler(>=6.2)
        return true
        #else
        return false
        #endif
    }

    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    static func makeEngine(guestLocale: String) -> DictationEngine {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return AppleSpeechDictation(localeIdentifier: DictationLocale.speechIdentifier(guestLocale: guestLocale))
        }
        return UnavailableDictation(reason: "requires macOS 26")
        #else
        return UnavailableDictation(reason: "built without the macOS 26 SDK")
        #endif
    }
}

/// A recogniser that fails mid-session must end it then: the microphone keeps
/// sending levels, so the guest's silence timeout never fires.
enum RecognitionFailure {
    static func watch<Value: Sendable>(_ task: Task<Value, Error>, report: @escaping @Sendable (String) -> Void) {
        Task {
            if case let .failure(error) = await task.result { report(error.localizedDescription) }
        }
    }
}

enum DictationLocale {
    static let fallback = "en-US"

    /// The guest's POSIX locale (ja_JP.UTF-8, sr_RS@latin) as the BCP 47
    /// language and region the recogniser takes (ja-JP, sr-RS). Anything
    /// else is the fallback.
    static func speechIdentifier(guestLocale: String) -> String {
        var name = Substring(guestLocale)
        if let at = name.firstIndex(of: "@") {
            guard isASCII(name[name.index(after: at)...], allowing: lowercase + uppercase + digits) else { return fallback }
            name = name[..<at]
        }
        if let dot = name.firstIndex(of: ".") {
            guard isASCII(name[name.index(after: dot)...], allowing: lowercase + uppercase + digits + "-") else { return fallback }
            name = name[..<dot]
        }
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (2...3).contains(parts[0].count), isASCII(parts[0], allowing: lowercase),
              parts[1].count == 2, isASCII(parts[1], allowing: uppercase) else {
            return fallback
        }
        return "\(parts[0])-\(parts[1])"
    }

    private static let lowercase = "abcdefghijklmnopqrstuvwxyz"
    private static let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let digits = "0123456789"

    private static func isASCII(_ text: Substring, allowing characters: String) -> Bool {
        !text.isEmpty && text.allSatisfy { characters.contains($0) }
    }
}

/// Answers every guest with the reason dictation can't run here.
final class UnavailableDictation: DictationEngine {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    var availability: DictationAvailability { .unavailable(reason: reason) }
    func prepare() {}
    func start(session: Int, model: DictationModel, events: @escaping @Sendable (DictationEvent) -> Void) {}
    func stop(session: Int) {}
    func cancel(session: Int) {}
}
