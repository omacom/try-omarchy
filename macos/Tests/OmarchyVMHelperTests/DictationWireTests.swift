import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite("Dictation wire protocol")
struct DictationWireTests {
    private func command(_ line: String) -> DictationGuestCommand? {
        DictationGuestCommand.decode(Data(line.utf8))
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test("Every guest command decodes")
    func decodesEveryGuestCommand() {
        #expect(command(#"{"type":"hello","version":1}"#) == .hello(version: 1))
        #expect(command(#"{"type":"start","session":12,"model":"dictation"}"#) == .start(session: 12, model: .dictation))
        #expect(command(#"{"type":"start","session":12,"model":"other"}"#) == .start(session: 12, model: .speech))
        #expect(command(#"{"type":"start","session":3}"#) == .start(session: 3, model: .speech))
        #expect(command(#"{"type":"stop","session":12}"#) == .stop(session: 12))
        #expect(command(#"{"type":"cancel","session":12}"#) == .cancel(session: 12))
        #expect(command(#"{"type":"ping","id":5}"#) == .ping(id: 5))
    }

    @Test("Malformed or unknown commands are ignored")
    func rejectsMalformedCommands() {
        for line in [
            #"nope"#,
            #"[]"#,
            #"{"type":"start"}"#,
            #"{"type":"start","session":true}"#,
            #"{"type":"start","session":-1}"#,
            #"{"type":"start","session":1.5}"#,
            #"{"type":"stop","session":"1"}"#,
            #"{"type":"hello"}"#,
            #"{"type":"launch","session":1}"#,
        ] {
            #expect(command(line) == nil, "\(line)")
        }
    }

    @Test("Host messages are sorted JSON lines")
    func encodesHostMessages() {
        #expect(text(DictationHostMessage.hello(.available(models: [.speech, .dictation], locale: "en-US")))
            == #"{"available":true,"locale":"en-US","models":["speech","dictation"],"type":"hello","version":1}"# + "\n")
        #expect(text(DictationHostMessage.hello(.unavailable(reason: "requires macOS 26")))
            == #"{"available":false,"reason":"requires macOS 26","type":"hello","version":1}"# + "\n")
        #expect(text(DictationHostMessage.event(.final(text: "Hi.", milliseconds: 141), session: 12))
            == #"{"ms":141,"session":12,"text":"Hi.","type":"final"}"# + "\n")
        #expect(text(DictationHostMessage.event(.level(0.5), session: 2))
            == #"{"session":2,"type":"level","v":0.5}"# + "\n")
        #expect(text(DictationHostMessage.event(.error("microphone: off"), session: 2))
            == #"{"message":"microphone: off","session":2,"type":"error"}"# + "\n")
        #expect(text(DictationHostMessage.event(.recording, session: 2)) == #"{"session":2,"type":"recording"}"# + "\n")
        #expect(text(DictationHostMessage.event(.partial("so far"), session: 2))
            == #"{"session":2,"text":"so far","type":"partial"}"# + "\n")
        #expect(text(DictationHostMessage.event(.processing, session: 2)) == #"{"session":2,"type":"processing"}"# + "\n")
        #expect(text(DictationHostMessage.event(.cancelled, session: 2)) == #"{"session":2,"type":"cancelled"}"# + "\n")
        #expect(text(DictationHostMessage.pong(id: 5, liveSession: nil)) == #"{"id":5,"type":"pong"}"# + "\n")
        #expect(text(DictationHostMessage.pong(id: 5, liveSession: 12)) == #"{"id":5,"session":12,"type":"pong"}"# + "\n")
    }

    @Test("Final, cancelled and error end a session")
    func terminalEvents() {
        #expect(DictationEvent.final(text: "", milliseconds: 0).isTerminal)
        #expect(DictationEvent.cancelled.isTerminal)
        #expect(DictationEvent.error("x").isTerminal)
        #expect(!DictationEvent.recording.isTerminal)
        #expect(!DictationEvent.level(0.1).isTerminal)
        #expect(!DictationEvent.partial("a").isTerminal)
        #expect(!DictationEvent.processing.isTerminal)
    }

    @Test("Only dictation selects the dictation model")
    func modelFromWire() {
        #expect(DictationModel(wire: "dictation") == .dictation)
        #expect(DictationModel(wire: "speech") == .speech)
        #expect(DictationModel(wire: nil) == .speech)
        #expect(DictationModel(wire: "DICTATION") == .speech)
    }
}
