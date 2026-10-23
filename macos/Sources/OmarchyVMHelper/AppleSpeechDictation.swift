// Built only with the macOS 26 SDK (Xcode 26); see DictationSupport.
#if compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

/// Push-to-talk recognition of the Mac microphone with Apple's on-device
/// SpeechAnalyzer. The microphone runs only while a session is live, and every
/// command runs on one queue in arrival order, so a stop can never overtake the
/// start it belongs to however long that start takes to set up.
@available(macOS 26, *)
final class AppleSpeechDictation: DictationEngine, @unchecked Sendable {
    /// Audio kept after the stop: people let go of the key on the last
    /// syllable, and cutting the microphone right then clips it.
    static let tailMilliseconds: UInt64 = 120
    static let levelInterval = 0.08
    static let microphoneDenied = "Allow microphone access for Try Omarchy in System Settings"
    static let downloadingAssets = "Downloading Apple speech assets; try again in a moment"
    /// No session records longer than the guest client waits for one.
    static let maximumSessionSeconds: UInt64 = 600

    private enum Command {
        case prepare
        case start(Int, DictationModel, @Sendable (DictationEvent) -> Void)
        case stop(Int)
        case cancel(Int)
        case microphoneChanged
        case timeLimit(Int)
        case recognitionFailed(Int, String)
        case assetsInstalled(DictationModel)
    }

    private struct Session {
        let id: Int
        let events: @Sendable (DictationEvent) -> Void
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let collector: Task<String, Error>
    }

    private let commands: AsyncStream<Command>.Continuation
    private let localeLock = NSLock()
    private var locale: Locale
    // Touched only by the command task.
    private let engine = AVAudioEngine()
    private var session: Session?
    private var warmedUp: Set<DictationModel> = []
    private var installing: Set<DictationModel> = []
    private var configurationObserver: NSObjectProtocol?

    init(localeIdentifier: String) {
        locale = Locale(identifier: localeIdentifier)
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.commands.yield(.microphoneChanged)
        }
        let requested = locale
        Task { [weak self] in
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
                ?? Locale(identifier: DictationLocale.fallback)
            self?.setLocale(resolved)
            for await command in stream {
                guard let self else { return }
                await self.handle(command)
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        commands.finish()
    }

    var availability: DictationAvailability {
        localeLock.lock()
        defer { localeLock.unlock() }
        return .available(models: [.speech, .dictation], locale: locale.identifier(.bcp47))
    }

    func prepare() { commands.yield(.prepare) }

    func start(session: Int, model: DictationModel, events: @escaping @Sendable (DictationEvent) -> Void) {
        commands.yield(.start(session, model, events))
    }

    func stop(session: Int) { commands.yield(.stop(session)) }
    func cancel(session: Int) { commands.yield(.cancel(session)) }

    private func setLocale(_ value: Locale) {
        localeLock.lock()
        locale = value
        localeLock.unlock()
    }

    private var currentLocale: Locale {
        localeLock.lock()
        defer { localeLock.unlock() }
        return locale
    }

    private func handle(_ command: Command) async {
        switch command {
        case .prepare:
            await warmUp()
        case let .start(id, model, events):
            await start(id, model, events)
        case let .stop(id):
            if session?.id == id { await finish() }
        case let .cancel(id):
            if session?.id == id { await end(with: .cancelled) }
        case .microphoneChanged:
            if session != nil { await end(with: .error("microphone changed")) }
        case let .timeLimit(id):
            if session?.id == id { await end(with: .error("recording stopped after 10 minutes")) }
        case let .recognitionFailed(id, message):
            if session?.id == id { await end(with: .error(message)) }
        case let .assetsInstalled(model):
            installing.remove(model)
        }
    }

    // MARK: - recognisers

    private func makeModule(_ model: DictationModel) -> any SpeechModule {
        let locale = currentLocale
        switch model {
        case .dictation:
            return DictationTranscriber(locale: locale, contentHints: [.shortForm],
                                        transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults, .frequentFinalization],
                                        attributeOptions: [])
        case .speech:
            // The progressive preset reports volatile (in-progress) results too.
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
    }

    /// Collects the finalised text. `onPartial` hears the text so far
    /// (finalised plus the current volatile guess) whenever it changes.
    private func collect(_ module: any SpeechModule, onPartial: (@Sendable (String) -> Void)? = nil) -> Task<String, Error> {
        func run<S: AsyncSequence>(_ results: S, _ split: @escaping (S.Element) -> (String, Bool)) -> Task<String, Error> {
            Task {
                var final = ""
                var last = ""
                for try await result in results {
                    let (text, isFinal) = split(result)
                    let now = final + text
                    if isFinal { final += text }
                    if let onPartial, now != last {
                        last = now
                        onPartial(now)
                    }
                }
                return final
            }
        }
        if let transcriber = module as? SpeechTranscriber {
            return run(transcriber.results) { (String($0.text.characters), $0.isFinal) }
        }
        let transcriber = module as! DictationTranscriber
        return run(transcriber.results) { (String($0.text.characters), $0.isFinal) }
    }

    private func assetsInstalled(_ module: any SpeechModule) async -> Bool {
        await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Starts one download per model; the next start after it finishes works.
    private func beginInstall(_ model: DictationModel) {
        guard !installing.contains(model) else { return }
        installing.insert(model)
        let module = makeModule(model)
        Task { [weak self] in
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                fputs("[dictation-bridge] speech asset download for \(model.rawValue) failed: \(error)\n", stderr)
            }
            self?.commands.yield(.assetsInstalled(model))
        }
    }

    /// The first session after a launch otherwise pays for loading the model
    /// (and once returned an empty final): spend that on half a second of
    /// silence through each installed recogniser instead. Starts queue behind
    /// this. Nothing is downloaded here.
    private func warmUp() async {
        for model in [DictationModel.speech, .dictation] where !warmedUp.contains(model) {
            let module = makeModule(model)
            guard await assetsInstalled(module),
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 2))
            else { continue }
            buffer.frameLength = buffer.frameCapacity
            do {
                let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let analyzer = SpeechAnalyzer(modules: [module])
                let collector = collect(module)
                try await analyzer.start(inputSequence: stream)
                input.yield(AnalyzerInput(buffer: buffer))
                input.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                _ = try await collector.value
                warmedUp.insert(model)
            } catch {
                fputs("[dictation-bridge] warm-up of \(model.rawValue) failed: \(error)\n", stderr)
            }
        }
        // A cold engine took ~0.4 s to report recording, a warm one ~0.1 s.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            _ = engine.inputNode
            engine.prepare()
        }
    }

    // MARK: - sessions

    private func start(_ id: Int, _ model: DictationModel, _ events: @escaping @Sendable (DictationEvent) -> Void) async {
        if session != nil { await end(with: .cancelled) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            events(.error(Self.microphoneDenied))
            return
        }
        let module = makeModule(model)
        guard await assetsInstalled(module) else {
            beginInstall(model)
            events(.error(Self.downloadingAssets))
            return
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            events(.error("no audio format for \(model.rawValue)"))
            return
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        // The microphone goes first: audio from the key press queues in the
        // stream while the analyzer is still setting up.
        do {
            try startMicrophone(into: input, format: format, events: events)
        } catch {
            events(.error("microphone: \(error.localizedDescription)"))
            return
        }
        events(.recording)
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [module])
        let collector = collect(module) { text in
            events(.partial(text.trimmingCharacters(in: .whitespaces)))
        }
        session = Session(id: id, events: events, analyzer: analyzer, input: input, collector: collector)
        RecognitionFailure.watch(collector) { [weak self] message in
            self?.commands.yield(.recognitionFailed(id, message))
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maximumSessionSeconds * 1_000_000_000)
            self?.commands.yield(.timeLimit(id))
        }
        fputs("[dictation-bridge] session \(id) started (\(model.rawValue))\n", stderr)
    }

    private func finish() async {
        guard let current = session else { return }
        session = nil
        current.events(.processing)
        try? await Task.sleep(nanoseconds: Self.tailMilliseconds * 1_000_000)
        stopMicrophone()
        // Timed from the end of the audio: the recogniser's own finishing time.
        let started = Self.milliseconds()
        current.input.finish()
        do {
            try await current.analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await current.collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Self.milliseconds() - started
            current.events(.final(text: text, milliseconds: elapsed.rounded()))
            fputs("[dictation-bridge] session \(current.id) final in \(Int(elapsed)) ms, \(text.count) characters\n", stderr)
        } catch {
            current.events(.error(error.localizedDescription))
        }
    }

    private func end(with event: DictationEvent) async {
        guard let current = session else { return }
        session = nil
        stopMicrophone()
        current.input.finish()
        await current.analyzer.cancelAndFinishNow()
        current.events(event)
    }

    // MARK: - microphone

    private func startMicrophone(into input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat,
                                 events: @escaping @Sendable (DictationEvent) -> Void) throws {
        let node = engine.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw HelperError.io("no input device (\(inputFormat))")
        }
        var lastLevel = 0.0
        node.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            // RMS of channel 0 on a 60 dB scale, as the guest's bars expect.
            if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += channels[0][index] * channels[0][index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let now = Self.milliseconds() / 1000
                if now - lastLevel >= Self.levelInterval {
                    lastLevel = now
                    let decibels = 20 * log10(max(Double(rms), 1e-6))
                    events(.level(min(max((decibels + 60) / 60, 0), 1)))
                }
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            throw error
        }
    }

    private func stopMicrophone() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func milliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e6
    }
}
#endif
