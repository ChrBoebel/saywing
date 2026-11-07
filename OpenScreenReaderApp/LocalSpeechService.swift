import AVFoundation
import Darwin
import Foundation
import NaturalLanguage

enum SpeechSpeed {
    static let preferenceKey = "speechPlaybackRate.v1"
    static let presets: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static func validated(_ value: Double) -> Double { value.isFinite ? min(2, max(0.75, value)) : 1 }
    static func label(_ value: Double) -> String { String(format: "%g×", value) }
}

/// Explicit local development installation, never a downloader or fallback.
struct SpeechRuntimeConfiguration: Sendable {
    let root: URL
    var bundled = false
    let sampleRate = 44_100
    let modelName = "Supertonic 3 · M1"
    var runtime: URL { root.appendingPathComponent("SupertonicRuntime") }
    var executable: URL { runtime.appendingPathComponent(bundled ? "python/bin/python3" : "venv/bin/python3") }
    var script: URL { runtime.appendingPathComponent("worker.py") }
    var model: URL { root.appendingPathComponent("DevelopmentModels/supertonic-3-3cadd1ee") }
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
            && [script, runtime.appendingPathComponent("installation-receipt.json"),
                runtime.appendingPathComponent("model-manifest.json"),
                runtime.appendingPathComponent("upstream/helper.py"),
                model.appendingPathComponent("onnx/vocoder.onnx")]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func language(for text: String) -> String {
        // German/English MVP: ambiguous short text uses the product's German default.
        NLLanguageRecognizer.dominantLanguage(for: text) == .english ? "en" : "de"
    }
}

@MainActor
protocol SpeechReading: AnyObject {
    func setPaused(_ paused: Bool)
    var playbackRate: Double { get set }
    /// Ephemeral normalized level at the playback clock, never queued-ahead PCM.
    var playbackLevel: Double { get }
    /// Returns only after the last audio buffer has played.
    func read(_ text: String, onPlayback: @escaping @MainActor () -> Void) async throws
    /// Prepare only the next text, without producing audible output.
    func prepareNext(_ text: String?)
    /// End/skip the current reading, preserving the prepared successor.
    func stopCurrent()
    /// Must silence playback immediately, without awaiting synthesis.
    func stop()
}

extension SpeechReading {
    func setPaused(_ paused: Bool) {}
    var playbackLevel: Double { 0 }
    func prepareNext(_ text: String?) {}
    func stopCurrent() { stop() }
}

enum SpeechFailure: Error, LocalizedError {
    case notInstalled, tooLong, failed, outputChanged, loadFailed, outOfMemory, interrupted, timedOut, invalidRequest
    var errorDescription: String? {
        switch self {
        case .outputChanged: String(localized: "The audio output changed, so reading stopped. Start it again to hear it on the new output.")
        case .notInstalled: Self.notInstalledDescription
        case .tooLong: String(localized: "Saywing reads up to 8,000 characters at a time. Select a smaller region.")
        case .failed, .invalidRequest: String(localized: "Local speech could not finish. Try again. No cloud or system voice was substituted.")
        case .loadFailed: String(localized: "The voice model could not be loaded. Reinstall Saywing to restore it.")
        case .outOfMemory: String(localized: "There wasn't enough memory for the voice. Close other apps and try again.")
        case .interrupted: String(localized: "Local speech stopped unexpectedly. Try again. No cloud or system voice was substituted.")
        case .timedOut: String(localized: "Local speech timed out. Try again. No cloud or system voice was substituted.")
        }
    }

    /// A worker's error packet. Earlier runtimes send no code, which stays generic.
    init(workerCode code: String?) {
        switch code {
        case "load_failed": self = .loadFailed
        case "out_of_memory": self = .outOfMemory
        case "too_long": self = .tooLong
        case "invalid_request": self = .invalidRequest
        default: self = .failed
        }
    }

    /// What a new worker process can plausibly fix. Damaged files, missing memory
    /// and a refused request would only fail again after another model load.
    var isTransient: Bool {
        switch self {
        case .failed, .interrupted, .timedOut: true
        case .notInstalled, .tooLong, .outputChanged, .loadFailed, .outOfMemory, .invalidRequest: false
        }
    }

    /// Trying again cannot restore what is missing from this copy of the app.
    var needsReinstall: Bool { self == .loadFailed || self == .notInstalled }

    private static var notInstalledDescription: String {
        #if DEBUG
        return String(localized: "The local Supertonic development runtime is not installed. No text was sent to a server.")
        #else
        // Release builds run only the bundled runtime, so a missing one means a damaged app copy.
        return String(localized: "The local speech runtime is missing from this copy of Saywing. Reinstall Saywing to restore it. No text was sent to a server.")
        #endif
    }
}

/// Single-producer/single-consumer RAM channel. No unbounded AsyncStream backlog.
@MainActor
final class SpeechPreparationBuffer {
    let capacityBytes: Int
    private(set) var bufferedBytes = 0
    private var packets: [Data] = []
    private var ended = false
    private var failure: Error?
    private var producer: CheckedContinuation<Void, Never>?
    private var consumer: CheckedContinuation<Void, Never>?

    init(capacityBytes: Int) { self.capacityBytes = capacityBytes }

    func send(_ packet: Data) async throws {
        guard !packet.isEmpty, packet.count <= capacityBytes else { throw SpeechFailure.failed }
        while bufferedBytes + packet.count > capacityBytes, !ended {
            await withCheckedContinuation { producer = $0 }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !ended else { throw CancellationError() }
        packets.append(packet)
        bufferedBytes += packet.count
        let waiting = consumer; consumer = nil; waiting?.resume()
    }

    func next() async throws -> Data? {
        while packets.isEmpty, !ended {
            await withCheckedContinuation { consumer = $0 }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        bufferedBytes -= packet.count
        let waiting = producer; producer = nil; waiting?.resume()
        return packet
    }

    func finish(_ error: Error? = nil) {
        ended = true
        failure = error
        if error != nil { packets.removeAll(); bufferedBytes = 0 }
        let p = producer, c = consumer
        producer = nil; consumer = nil
        p?.resume(); c?.resume()
    }

    func cancel() { finish(CancellationError()) }
}

@MainActor
private final class SpeechJob {
    let id = UUID().uuidString
    let text: String
    let buffer: SpeechPreparationBuffer
    var task: Task<Void, Never>?
    /// PCM already handed to the buffer. A retry continues after it, so nothing is heard twice.
    var deliveredBytes = 0
    init(text: String, sampleRate: Int) {
        self.text = text
        buffer = SpeechPreparationBuffer(capacityBytes: sampleRate * 8 * 4)
    }
    func cancel() { task?.cancel(); buffer.cancel() }
}

/// One model process per reading session. Only one synthesis runs at a time.
@MainActor
final class LocalSpeechService: SpeechReading {
    func setPaused(_ paused: Bool) { playback.setPaused(paused) }
    private let configuration: SpeechRuntimeConfiguration
    private let playback: SpeechAudioPlayer
    private var current: SpeechJob?
    private var prepared: SpeechJob?
    private var producing: SpeechJob?
    private var session: SpeechWorkerSession?
    private var idleTask: Task<Void, Never>?
    private var readGeneration: UInt64 = 0
    private let launchWorker: @MainActor (SpeechRuntimeConfiguration) throws -> SpeechWorkerTransport
    private var lastProducer: Task<Void, Never>?
    private(set) var workerLaunchCount = 0
    var preparedAudioBytes: Int { prepared?.buffer.bufferedBytes ?? 0 }
    var workerPID: Int32? { session?.pid }
    var playbackDiagnostics: SpeechAudioPlayer.Diagnostics { playback.diagnostics }
    var playbackLevel: Double { playback.playbackLevel }
    var playbackRate: Double {
        get { playback.playbackRate }
        set { playback.playbackRate = newValue }
    }

    static var developmentRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenScreenReader")
    }
    static var installationSummary: String {
        let config = installedConfiguration
        guard config.isInstalled else { return String(localized: "Not installed") }
        guard config.bundled else { return String(localized: "Installed for local development") }
        #if DEBUG
        return String(localized: "Bundled · offline development preview")
        #else
        return String(localized: "Bundled · works offline")
        #endif
    }
    static var installedConfiguration: SpeechRuntimeConfiguration {
        let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("Speech")
        if let root = bundledRoot, FileManager.default.fileExists(atPath: root.path) {
            // A damaged bundle must fail visibly, never fall back to this Mac's development runtime.
            return .init(root: root, bundled: true)
        }
        #if DEBUG
        // Only development builds may run the explicit local installation in Application Support.
        return .init(root: developmentRoot)
        #else
        // Release builds never run code from a user-writable folder; without the bundle they fail closed.
        return .init(root: bundledRoot ?? URL(fileURLWithPath: "/nonexistent/Speech"), bundled: true)
        #endif
    }
    init(configuration: SpeechRuntimeConfiguration = LocalSpeechService.installedConfiguration,
         launchWorker: @escaping @MainActor (SpeechRuntimeConfiguration) throws -> SpeechWorkerTransport = { try SpeechWorkerTransport.launch($0) }) {
        self.configuration = configuration
        self.launchWorker = launchWorker
        playback = SpeechAudioPlayer(sampleRate: configuration.sampleRate)
    }
    isolated deinit { stop() }

    func prepareNext(_ text: String?) {
        guard prepared?.text != text else { return }
        discardPrepared()
        guard let text, !text.isEmpty, text.count <= 8_000, text.utf8.count <= 48_000 else { return }
        idleTask?.cancel()
        prepared = SpeechJob(text: text, sampleRate: configuration.sampleRate)
        startPreparedIfPossible()
    }

    func read(_ text: String, onPlayback: @escaping @MainActor () -> Void) async throws {
        guard !text.isEmpty, text.count <= 8_000, text.utf8.count <= 48_000 else { throw SpeechFailure.tooLong }
        stopCurrent()
        idleTask?.cancel()
        let isPreparedHandoff = prepared?.text == text
        let job: SpeechJob
        if let next = prepared, next.text == text {
            job = next
            prepared = nil
        } else {
            discardPrepared()
            job = SpeechJob(text: text, sampleRate: configuration.sampleRate)
        }
        current = job
        playback.reset()
        let token = readGeneration
        start(job)
        try await withTaskCancellationHandler {
            do {
                // A brief, cancellable separation between independent passages.
                if isPreparedHandoff { try await Task.sleep(for: .milliseconds(120)) }
                while let packet = try await job.buffer.next() {
                    guard token == readGeneration else { throw CancellationError() }
                    try await playback.enqueue(packet, onPlayback: onPlayback)
                }
                try await playback.finish(onPlayback: onPlayback)
                try Task.checkCancellation()
                guard token == readGeneration else { throw CancellationError() }
                current = nil
                playback.stop()
                armIdleExpiry()
            } catch {
                if token == readGeneration {
                    if error is CancellationError { stopCurrent() }
                    else { stop() }
                }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.readGeneration == token else { return }
                self.stopCurrent()
            }
        }
    }

    /// Exactly one retry per passage, always with a new worker on new pipes, so nothing
    /// the old process still wrote can arrive. The buffer stays open: whatever waits for
    /// this passage keeps waiting and continues at the same position. This relies on the
    /// worker's per-text seed producing the same audio again.
    private func produce(_ job: SpeechJob) async throws {
        var mayRetry = true
        while true {
            try Task.checkCancellation()
            guard producing === job else { throw CancellationError() }
            if session == nil {
                session = SpeechWorkerSession(transport: try launchWorker(configuration), sampleRate: configuration.sampleRate)
                workerLaunchCount += 1
            }
            guard let session else { throw SpeechFailure.failed }
            var alreadyDelivered = job.deliveredBytes
            do {
                try await session.synthesize(job.text, id: job.id) { pcm in
                    guard pcm.count > alreadyDelivered else {
                        alreadyDelivered -= pcm.count
                        return
                    }
                    let fresh = Data(pcm.dropFirst(alreadyDelivered))
                    alreadyDelivered = 0
                    try await job.buffer.send(fresh)
                    job.deliveredBytes += fresh.count
                }
                return
            } catch {
                // Stop, Esc and a skip end the job themselves; their kill is not a crash.
                guard !(error is CancellationError), !Task.isCancelled, producing === job else { throw CancellationError() }
                guard mayRetry, (error as? SpeechFailure)?.isTransient == true else { throw error }
                mayRetry = false
                session.stop()
                self.session = nil
            }
        }
    }

    private func startPreparedIfPossible() {
        guard producing == nil, let prepared, prepared.task == nil else { return }
        start(prepared)
    }

    private func start(_ job: SpeechJob) {
        guard job.task == nil, producing == nil else { return }
        idleTask?.cancel()
        producing = job
        job.task = Task { @MainActor [weak self, job] in
            guard let self else { job.buffer.cancel(); return }
            do {
                try await self.produce(job)
                try Task.checkCancellation()
                guard self.producing === job else { throw CancellationError() }
                job.buffer.finish()
                self.producing = nil
                self.startPreparedIfPossible()
            } catch {
                job.buffer.finish(error is CancellationError ? CancellationError() : ((error as? SpeechFailure) ?? .failed))
                if self.producing === job {
                    self.producing = nil
                    self.session?.stop()
                    self.session = nil
                }
            }
        }
        lastProducer = job.task
    }

    /// Returns once the most recent synthesis job has ended, however it ended.
    func waitForProducerToSettle() async { await lastProducer?.value }

    func stopCurrent() {
        readGeneration &+= 1
        playback.stop()
        let old = current
        current = nil
        old?.cancel()
        if let old, producing === old {
            // Skipping unfinished synthesis requires hard termination; a completed
            // current text never kills the process preparing its successor.
            producing = nil
            session?.stop()
            session = nil
        }
        startPreparedIfPossible()
        armIdleExpiry()
    }

    private func discardPrepared() {
        guard let old = prepared else { return }
        prepared = nil
        old.cancel()
        if producing === old {
            producing = nil
            session?.stop()
            session = nil
        }
    }

    private func armIdleExpiry() {
        idleTask?.cancel()
        guard current == nil, prepared == nil, producing == nil else { return }
        let token = readGeneration
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readGeneration == token,
                  self.current == nil, self.prepared == nil, self.producing == nil else { return }
            self.session?.stop()
            self.session = nil
        }
    }

    func stop() {
        readGeneration &+= 1
        idleTask?.cancel()
        idleTask = nil
        playback.stop()
        current?.cancel()
        prepared?.cancel()
        current = nil; prepared = nil; producing = nil
        session?.stop()
        session = nil
    }
}

/// The pipes to one worker and how to end it. The app launches a sandboxed process;
/// tests put a scripted peer on real pipes behind the same session and packet reader.
struct SpeechWorkerTransport {
    let input: FileHandle
    let output: FileHandle
    let pid: () -> Int32?
    let terminate: () -> Void

    @MainActor
    static func launch(_ configuration: SpeechRuntimeConfiguration) throws -> SpeechWorkerTransport {
        guard configuration.isInstalled else { throw SpeechFailure.notInstalled }
        guard let sandbox = WorkerSandbox.arguments(resources: configuration.root, modelRoot: nil,
                                                    python: configuration.executable) else { throw SpeechFailure.notInstalled }
        let worker = Process()
        let requests = Pipe(), audio = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        worker.arguments = sandbox + ["-I", "-B", configuration.script.path, "--model", configuration.model.path, "--session"]
        worker.environment = ["PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"]
        worker.currentDirectoryURL = configuration.executable.deletingLastPathComponent()
        worker.standardInput = requests
        worker.standardOutput = audio
        worker.standardError = FileHandle.nullDevice
        let transport = SpeechWorkerTransport(
            input: requests.fileHandleForWriting, output: audio.fileHandleForReading,
            pid: { worker.isRunning ? worker.processIdentifier : nil },
            terminate: { if worker.isRunning { kill(worker.processIdentifier, SIGKILL) } })
        do {
            guard fcntl(transport.input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw SpeechFailure.loadFailed }
            try worker.run()
            try requests.fileHandleForReading.close()
            try audio.fileHandleForWriting.close()
        } catch {
            transport.terminate()
            try? transport.input.close()
            try? transport.output.close()
            throw SpeechFailure.loadFailed
        }
        return transport
    }
}

/// Versioned request IDs plus one in-flight producer isolate stale worker packets.
@MainActor
private final class SpeechWorkerSession {
    private struct Packet: Decodable {
        let kind: String
        let id: String?
        let `protocol`: Int?
        let sampleRate: Int?
        let pcm: Data?
        let code: String?
    }
    private struct Request: Encodable { let text: String; let language: String; let id: String }
    private let transport: SpeechWorkerTransport
    private var input: FileHandle { transport.input }
    private let reader: SpeechPacketReader
    private let sampleRate: Int
    private var stopped = false
    private var timedOut = false
    private var packetGeneration: UInt64 = 0
    /// The worker sends its first `ready` only after the verified model has loaded.
    private var modelLoaded = false
    private var workerLost: SpeechFailure { modelLoaded ? .interrupted : .loadFailed }
    var pid: Int32? { stopped ? nil : transport.pid() }

    init(transport: SpeechWorkerTransport, sampleRate: Int) {
        self.transport = transport
        self.sampleRate = sampleRate
        reader = SpeechPacketReader(handle: transport.output)
    }
    isolated deinit { stop() }

    func synthesize(_ text: String, id: String, accept: (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        var request = try JSONEncoder().encode(Request(text: text,
            language: SpeechRuntimeConfiguration.language(for: text), id: id))
        request.append(10)
        let writer = input
        // A worker that is already gone refuses the write. Its last packet or the end of
        // its output, read below, says why, so the write's own error adds nothing.
        _ = try? await Task.detached { try writer.write(contentsOf: request) }.value
        var ready = false, receivedAudio = false
        while true {
            let waitLimit: Duration = receivedAudio ? .seconds(30) : .seconds(90)
            packetGeneration &+= 1
            let token = packetGeneration
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: waitLimit) } catch { return }
                guard !Task.isCancelled, let self, self.packetGeneration == token else { return }
                self.timedOut = true
                self.stop()
            }
            let line: Data?
            do { line = try await reader.nextLine() }
            catch {
                deadline.cancel()
                packetGeneration &+= 1
                if timedOut { throw SpeechFailure.timedOut }
                if stopped { throw CancellationError() }
                throw error as? SpeechFailure == .interrupted ? workerLost : error
            }
            deadline.cancel()
            packetGeneration &+= 1
            if timedOut { throw SpeechFailure.timedOut }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            guard let line else { throw workerLost }
            guard let packet = try? JSONDecoder().decode(Packet.self, from: line) else { throw SpeechFailure.failed }
            // Every error ends its worker and comes without an id: the pipe belongs to this one worker.
            if packet.kind == "error" { throw SpeechFailure(workerCode: packet.code) }
            guard packet.id == id, packet.protocol == 2 else { throw SpeechFailure.failed }
            switch packet.kind {
            case "ready":
                guard !ready, packet.sampleRate == sampleRate else { throw SpeechFailure.failed }
                ready = true
                modelLoaded = true
            case "audio":
                guard ready, packet.sampleRate == sampleRate, let pcm = packet.pcm,
                      !pcm.isEmpty, pcm.count <= 96_000, pcm.count % 4 == 0 else { throw SpeechFailure.failed }
                try await accept(pcm)
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                receivedAudio = true
                // As with the request: a refused acknowledgement is explained by what is read next.
                _ = try? input.write(contentsOf: Data("next\n".utf8))
            case "end":
                guard ready, receivedAudio else { throw SpeechFailure.failed }
                return
            default: throw SpeechFailure.failed
            }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        packetGeneration &+= 1
        transport.terminate()
        try? transport.input.close()
        // Not the output: the reader may be reading it right now.
        reader.close()
    }
}

/// Framing runs on the reader's own serial queue, never on Swift's cooperative
/// pool: a pipe read can block for the full synthesis deadline (up to 90 s), and a
/// blocked cooperative thread would starve unrelated async work. Bounded blocks
/// avoid an actor hop for every byte of base64 audio. Killing the owned worker
/// unblocks a pending pipe read. Only one consumer calls nextLine at a time.
/// The reader owns closing its handle: Foundation raises an Objective-C exception,
/// which Swift cannot catch, when a closed FileHandle is asked for its descriptor.
final class SpeechPacketReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "Saywing.speech.packet-reader", qos: .userInitiated)
    // Touched only on `queue`.
    private var pending = Data()
    private var closed = false
    init(handle: FileHandle) { self.handle = handle }

    /// Closes the handle after any pending read has returned; later reads return nil.
    /// Kill the writer first, so a blocked read ends at the end of its output.
    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            pending.removeAll()
            try? handle.close()
        }
    }

    func nextLine() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try readLine() }) }
        }
    }

    private func readLine() throws -> Data? {
        dispatchPrecondition(condition: .onQueue(queue))
        while true {
            guard !closed else { return nil }
            if let newline = pending.firstIndex(of: 10) {
                guard pending.distance(from: pending.startIndex, to: newline) <= 140_000 else {
                    throw SpeechFailure.failed
                }
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                return line
            }
            guard pending.count <= 140_000 else { throw SpeechFailure.failed }
            // FileHandle.read(upToCount:) may try to fill the requested length.
            // A short ready packet must return immediately: the peer can be
            // waiting for our acknowledgement before producing more bytes.
            var block = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(handle.fileDescriptor, &block, block.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SpeechFailure.failed }
            guard count > 0 else {
                // A line cut off by the end of the output: the worker died writing it.
                guard pending.isEmpty else { throw SpeechFailure.interrupted }
                return nil
            }
            pending.append(contentsOf: block.prefix(count))
        }
    }
}

/// Twenty-millisecond scalar windows. No PCM is retained by this envelope.
struct PlaybackEnvelope {
    private struct Window { let start: Int64; let end: Int64; let level: Double }
    private var windows: [Window] = []
    var count: Int { windows.count }

    mutating func append(_ samples: UnsafeBufferPointer<Float>, startingAt start: Int64, sampleRate: Int) {
        let hop = max(1, sampleRate / 50)
        for offset in stride(from: 0, to: samples.count, by: hop) {
            let end = min(samples.count, offset + hop)
            var energy = 0.0
            for index in offset..<end { energy += Double(samples[index]) * Double(samples[index]) }
            let rms = sqrt(energy / Double(end - offset))
            let level = rms < 0.002 ? 0 : min(1, sqrt(rms) * 1.8)
            windows.append(Window(start: start + Int64(offset), end: start + Int64(end), level: level))
        }
    }
    mutating func level(at frame: Int64) -> Double {
        windows.removeAll { $0.end <= frame }
        guard let first = windows.first, frame >= first.start else { return 0 }
        return first.level
    }
    mutating func reset() { windows.removeAll(keepingCapacity: false) }
}

/// A bounded look-ahead queue: request the next packet after scheduling, not
/// after playing. A short pre-roll absorbs transport/generation jitter.
@MainActor
final class SpeechAudioPlayer {
    private(set) var isPaused = false
    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused { player.pause() }
        else if queuedFrames > 0 { player.play() }
        else if draining {
            let completion = waiter
            waiter = nil
            completion?.resume()
        }
    }
    struct Diagnostics {
        var frames = 0
        var underruns = 0
        var missingFrames = 0
        var maximumQueuedFrames = 0
    }
    private(set) var diagnostics = Diagnostics()
    private(set) var queuedFrames = 0
    let sampleRate: Int
    // Preserve at least one second of wall-clock look-ahead at faster rates.
    // Eight source seconds retain four seconds of look-ahead at 2×. The worker
    // synthesizes whole sentences, so two seconds was insufficient at boundaries.
    // Fixed at every rate so a live slowdown cannot invalidate the memory budget.
    var prebufferFrames: Int {
        let rate = max(1, playbackRate)
        #if arch(x86_64)
        // Intel sentence synthesis needs more startup headroom at faster rates.
        // At 2×, accumulate six source seconds (three playback seconds), still
        // below the fixed eight-second cap. Short texts drain via finish().
        let headroom = 1 + 2 * (rate - 1)
        #else
        let headroom = 1.0
        #endif
        return Int(ceil(Double(sampleRate) * rate * headroom))
    }
    var capacityFrames: Int { sampleRate * 8 }
    /// Internal so tests can stop it the way an output change does.
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    var playbackRate: Double {
        get { Double(timePitch.rate) }
        set { timePitch.rate = Float(SpeechSpeed.validated(newValue)) }
    }
    var pitchCents: Float { timePitch.pitch }
    private var scheduledEnd: AVAudioFramePosition = 0
    private var generation: UInt64 = 0
    private var waiter: CheckedContinuation<Void, Error>?
    private var draining = false
    private var envelope = PlaybackEnvelope()
    /// The engine was started for the current reading and not stopped since.
    private var engineActive = false
    /// The output device changed under a reading. Its scheduled audio is gone, so the
    /// reading fails visibly instead of continuing with a silent gap; `reset` clears it.
    private(set) var outputChanged = false
    private var configurationObserver: NSObjectProtocol?
    var playbackLevel: Double {
        guard player.isPlaying,
              let time = player.lastRenderTime.flatMap({ player.playerTime(forNodeTime: $0) }) else { return 0 }
        return envelope.level(at: time.sampleTime)
    }

    init(sampleRate: Int = 24_000) {
        self.sampleRate = sampleRate
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.pitch = 0
        // AVAudioEngine stops itself when the output hardware changes (headphones,
        // AirPlay, a display's speakers). Its scheduled buffers never finish then.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.outputConfigurationChanged() } }
    }
    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        stop()
    }

    func reset() {
        stop()
        outputChanged = false
        diagnostics = Diagnostics()
        scheduledEnd = 0
    }

    /// Ends the current reading with `SpeechFailure.outputChanged`: queued frames are
    /// dropped and a waiting producer or drain is released at once, so the reading
    /// never stalls into the speech timeout.
    func outputConfigurationChanged() {
        // A change the engine survived (still running) lost nothing; an idle player has nothing to end.
        guard !engine.isRunning, engineActive || queuedFrames > 0 || waiter != nil else { return }
        generation &+= 1
        outputChanged = true
        isPaused = false
        player.stop()
        engine.stop()
        engine.reset()
        engineActive = false
        envelope.reset()
        queuedFrames = 0
        draining = false
        let completion = waiter
        waiter = nil
        completion?.resume(throwing: SpeechFailure.outputChanged)
    }

    func enqueue(_ data: Data, onPlayback: @escaping @MainActor () -> Void) async throws {
        guard !data.isEmpty, data.count <= 96_000, data.count % 4 == 0 else { throw SpeechFailure.failed }
        if outputChanged { throw SpeechFailure.outputChanged }
        let current = generation
        let frameCount = data.count / 4
        while queuedFrames + frameCount > capacityFrames {
            try await waitForProgress()
            guard generation == current else { throw outputChanged ? SpeechFailure.outputChanged : CancellationError() }
        }
        try Task.checkCancellation()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 4)),
              let samples = buffer.floatChannelData?[0] else { throw SpeechFailure.failed }
        buffer.frameLength = buffer.frameCapacity
        try data.withUnsafeBytes { bytes in
            for index in 0..<Int(buffer.frameLength) {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                guard value.isFinite else { throw SpeechFailure.failed }
                samples[index] = min(1, max(-1, value))
            }
        }
        if !engine.isRunning {
            // Stopped by itself mid-reading: the output changed before its notice arrived.
            // Restarting here would continue after a silent gap with stale frame counts.
            if engineActive {
                outputConfigurationChanged()
                throw SpeechFailure.outputChanged
            }
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            try engine.start()
            engineActive = true
        }
        let rendered = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
        if scheduledEnd > 0, rendered > scheduledEnd + AVAudioFramePosition(sampleRate / 50) {
            diagnostics.underruns += 1
            diagnostics.missingFrames += Int(rendered - scheduledEnd)
        }
        let startFrame = max(scheduledEnd, rendered)
        _ = envelope.level(at: rendered)
        envelope.append(UnsafeBufferPointer(start: samples, count: frameCount), startingAt: startFrame, sampleRate: sampleRate)
        scheduledEnd = startFrame + AVAudioFramePosition(buffer.frameLength)
        diagnostics.frames += frameCount
        queuedFrames += frameCount
        diagnostics.maximumQueuedFrames = max(diagnostics.maximumQueuedFrames, queuedFrames)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.queuedFrames -= frameCount
                if !self.draining || self.queuedFrames == 0 {
                    let completion = self.waiter
                    self.waiter = nil
                    completion?.resume()
                }
            }
        }
        if !isPaused, !player.isPlaying, queuedFrames >= prebufferFrames { player.play() }
        if player.isPlaying { onPlayback() }
    }

    func finish(onPlayback: @escaping @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        if outputChanged { throw SpeechFailure.outputChanged }
        let current = generation
        if !isPaused, queuedFrames > 0, !player.isPlaying {
            player.play()
            onPlayback()
        }
        guard generation == current else { throw CancellationError() }
        draining = true
        defer { if generation == current { draining = false } }
        while queuedFrames > 0 || isPaused { try await waitForProgress() }
        guard generation == current else { throw outputChanged ? SpeechFailure.outputChanged : CancellationError() }
    }

    private func waitForProgress() async throws {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func stop() {
        generation &+= 1
        isPaused = false
        player.stop()
        engine.stop()
        engine.reset()
        engineActive = false
        envelope.reset()
        queuedFrames = 0
        draining = false
        let completion = waiter
        waiter = nil
        completion?.resume(throwing: CancellationError())
    }
}
