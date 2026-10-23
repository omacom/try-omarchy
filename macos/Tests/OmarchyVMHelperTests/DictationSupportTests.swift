import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite("Dictation availability")
struct DictationSupportTests {
    @Test("Guest locales map to speech locales")
    func guestLocalesMapToSpeechLocales() {
        #expect(DictationLocale.speechIdentifier(guestLocale: "ja_JP.UTF-8") == "ja-JP")
        #expect(DictationLocale.speechIdentifier(guestLocale: "en_US.UTF-8") == "en-US")
        #expect(DictationLocale.speechIdentifier(guestLocale: "zh_TW") == "zh-TW")
        #expect(DictationLocale.speechIdentifier(guestLocale: "sr_RS@latin") == "sr-RS")
        for bad in ["", "C", "../x", "en-US", "en_us.UTF-8", "en_US.UTF-8\nx"] {
            #expect(DictationLocale.speechIdentifier(guestLocale: bad) == "en-US", "\(bad)")
        }
    }

    @Test("Availability follows the SDK the app was built with and the host")
    func availabilityFollowsTheBuildAndHost() {
        #if compiler(>=6.2)
        #expect(DictationSupport.isCompiledIn)
        #else
        #expect(!DictationSupport.isCompiledIn)
        #expect(!DictationSupport.isAvailable)
        #endif
        if !DictationSupport.isAvailable {
            guard case .unavailable = DictationSupport.makeEngine(guestLocale: "en_US.UTF-8").availability else {
                Issue.record("expected an unavailable engine")
                return
            }
        }
    }

    @Test("The unavailable engine reports its reason and never records")
    func unavailableEngineDoesNothing() {
        let engine = UnavailableDictation(reason: "x")
        #expect(engine.availability == .unavailable(reason: "x"))
        let called = Locked(false)
        engine.prepare()
        engine.start(session: 1, model: .speech) { _ in called.set(true) }
        engine.stop(session: 1)
        engine.cancel(session: 1)
        #expect(!called.value)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
