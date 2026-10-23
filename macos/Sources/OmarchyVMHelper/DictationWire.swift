import Foundation

/// The two recognisers the guest can ask for. Anything but "dictation" is
/// the general SpeechTranscriber.
enum DictationModel: String, Equatable, Sendable {
    case speech
    case dictation

    init(wire: String?) {
        self = wire == Self.dictation.rawValue ? .dictation : .speech
    }
}

enum DictationAvailability: Equatable, Sendable {
    case available(models: [DictationModel], locale: String)
    case unavailable(reason: String)
}

/// One line from the guest on dev.tryomarchy.dictation. Sessions are
/// numbered by the guest; the host only echoes the numbers back.
enum DictationGuestCommand: Equatable {
    case hello(version: Int)
    case start(session: Int, model: DictationModel)
    case stop(session: Int)
    case cancel(session: Int)
    case ping(id: Int)

    /// Returns nil for anything this host does not understand, so a newer
    /// guest's additions and a misbehaving guest's junk are both ignored.
    static func decode(_ line: Data) -> DictationGuestCommand? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "hello":
            return integer(object["version"]).map { .hello(version: $0) }
        case "start":
            return integer(object["session"]).map {
                .start(session: $0, model: DictationModel(wire: object["model"] as? String))
            }
        case "stop":
            return integer(object["session"]).map { .stop(session: $0) }
        case "cancel":
            return integer(object["session"]).map { .cancel(session: $0) }
        case "ping":
            return integer(object["id"]).map { .ping(id: $0) }
        default:
            return nil
        }
    }

    /// A non-negative whole JSON number; JSON booleans also arrive as
    /// NSNumber and are refused.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double >= 0, double <= Double(Int32.max), double.rounded() == double else {
            return nil
        }
        return Int(double)
    }
}

/// What a recogniser reports for one session. The bridge adds the session id.
enum DictationEvent: Equatable, Sendable {
    case recording
    case level(Double)
    case partial(String)
    case processing
    case final(text: String, milliseconds: Double)
    case cancelled
    case error(String)

    /// Nothing more is sent for a session after one of these.
    var isTerminal: Bool {
        switch self {
        case .final, .cancelled, .error: true
        case .recording, .level, .partial, .processing: false
        }
    }
}

enum DictationHostMessage {
    static let protocolVersion = 1

    static func hello(_ availability: DictationAvailability) -> Data {
        var object: [String: Any] = ["type": "hello", "version": protocolVersion]
        switch availability {
        case let .available(models, locale):
            object["available"] = true
            object["models"] = models.map(\.rawValue)
            object["locale"] = locale
        case let .unavailable(reason):
            object["available"] = false
            object["reason"] = reason
        }
        return line(object)
    }

    static func event(_ event: DictationEvent, session: Int) -> Data {
        var object: [String: Any] = ["session": session]
        switch event {
        case .recording:
            object["type"] = "recording"
        case let .level(value):
            object["type"] = "level"
            object["v"] = value
        case let .partial(text):
            object["type"] = "partial"
            object["text"] = text
        case .processing:
            object["type"] = "processing"
        case let .final(text, milliseconds):
            object["type"] = "final"
            object["text"] = text
            object["ms"] = milliseconds
        case .cancelled:
            object["type"] = "cancelled"
        case let .error(message):
            object["type"] = "error"
            object["message"] = message
        }
        return line(object)
    }

    /// `session` is present only while one is live.
    static func pong(id: Int, liveSession: Int?) -> Data {
        var object: [String: Any] = ["type": "pong", "id": id]
        if let liveSession { object["session"] = liveSession }
        return line(object)
    }

    private static func line(_ object: [String: Any]) -> Data {
        // Every value above is a string, number, bool or string array.
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}
