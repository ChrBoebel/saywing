import Darwin
import Foundation
import Testing
@testable import OpenScreenReader

/// A scripted worker on real pipes: the real session, packet reader and player run against it.
@MainActor
final class ScriptedSpeechWorker {
    private let requests = Pipe(), audio = Pipe()
    private let reader: SpeechPacketReader
    private var exited = false
    private(set) var killed = false
    private(set) var receivedTexts: [String] = []
    private(set) var transport: SpeechWorkerTransport!
    fileprivate var script: Task<Void, Never>?

    init() {
        reader = SpeechPacketReader(handle: requests.fileHandleForReading)
        // Late packets from a test must not raise SIGPIPE once the session closed its end.
        _ = fcntl(audio.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(requests.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        transport = SpeechWorkerTransport(
            input: requests.fileHandleForWriting, output: audio.fileHandleForReading,
            pid: { 4_242 },
            terminate: { [weak self] in
                MainActor.assumeIsolated {
                    self?.killed = true
                    self?.exit()
                }
            })
    }

    /// The id of the next synthesis request.
    @discardableResult
    func nextRequest() async throws -> String {
        while let line = try await reader.nextLine() {
            guard line != Data("next".utf8) else { continue }
            let request = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            receivedTexts.append(try #require(request["text"] as? String))
            return try #require(request["id"] as? String)
        }
        throw CancellationError()
    }

    func send(_ packet: String) {
        guard !exited else { return }
        try? audio.fileHandleForWriting.write(contentsOf: Data((packet + "\n").utf8))
    }
    /// The way a worker that already exited refuses the parent's next write.
    func closeStandardInput() { try? requests.fileHandleForReading.close() }
    func transportWriteWithoutNewline(_ bytes: String) throws {
        try audio.fileHandleForWriting.write(contentsOf: Data(bytes.utf8))
    }
    func ready(_ id: String) { send(#"{"kind":"ready","sampleRate":44100,"id":"\#(id)","protocol":2}"#) }
    func audio(_ id: String, bytes: Int = 4_800) {
        let pcm = Data(repeating: 0, count: bytes).base64EncodedString()
        send(#"{"kind":"audio","sampleRate":44100,"pcm":"\#(pcm)","id":"\#(id)","protocol":2}"#)
    }
    func end(_ id: String) { send(#"{"kind":"end","id":"\#(id)","protocol":2}"#) }

    /// End of file, as the parent sees any exit or crash.
    func exit() {
        guard !exited else { return }
        exited = true
        try? audio.fileHandleForWriting.close()
    }
}

/// Hands out one script per launch, in order. A launch without a script stays silent.
@MainActor
final class ScriptedSpeechWorkers {
    private(set) var launched: [ScriptedSpeechWorker] = []
    private var scripts: [WorkerScript]
    var launchError: Error?
    init(_ scripts: [WorkerScript]) { self.scripts = scripts }

    func launch(_: SpeechRuntimeConfiguration) throws -> SpeechWorkerTransport {
        if let launchError { throw launchError }
        let worker = ScriptedSpeechWorker()
        launched.append(worker)
        if !scripts.isEmpty {
            let script = scripts.removeFirst()
            worker.script = Task { @MainActor in try? await script.run(worker) }
        }
        return worker.transport
    }

    func service() -> LocalSpeechService {
        LocalSpeechService(configuration: .init(root: URL(fileURLWithPath: "/nonexistent-speech-root"))) { [self] in
            try launch($0)
        }
    }

    func waitForLaunches(_ count: Int) async throws {
        for _ in 0..<1_000 where launched.count < count { try await Task.sleep(for: .milliseconds(2)) }
        #expect(launched.count >= count)
    }
}

struct WorkerScript {
    let run: @MainActor (ScriptedSpeechWorker) async throws -> Void
    static func custom(_ run: @escaping @MainActor (ScriptedSpeechWorker) async throws -> Void) -> Self { .init(run: run) }
    static func completes(bytes: Int = 4_800) -> Self {
        .custom { worker in
            let id = try await worker.nextRequest()
            worker.ready(id)
            worker.audio(id, bytes: bytes)
            worker.end(id)
        }
    }
    static func rejects(_ packet: String) -> Self {
        .custom { worker in
            try await worker.nextRequest()
            worker.send(packet)
            worker.exit()
        }
    }
    static var exitsBeforeReady: Self {
        .custom { worker in
            try await worker.nextRequest()
            worker.exit()
        }
    }
    static func crashesAfterAudio(bytes: Int = 4_800) -> Self {
        .custom { worker in
            let id = try await worker.nextRequest()
            worker.ready(id)
            worker.audio(id, bytes: bytes)
            worker.exit()
        }
    }
    /// Finishes the first text, then dies right after accepting the second.
    static var finishesOneTextThenCrashes: Self {
        .custom { worker in
            let first = try await worker.nextRequest()
            worker.ready(first)
            worker.audio(first)
            worker.end(first)
            let second = try await worker.nextRequest()
            worker.ready(second)
            worker.exit()
        }
    }
}

@Suite("Speech worker failures", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SpeechWorkerFailureTests {
    private func failure(of read: () async throws -> Void) async -> Error? {
        do { try await read(); return nil } catch { return error }
    }

    @Test(arguments: [
        ("load_failed", SpeechFailure.loadFailed),
        ("out_of_memory", SpeechFailure.outOfMemory),
        ("too_long", SpeechFailure.tooLong),
        ("invalid_request", SpeechFailure.invalidRequest),
    ])
    func errorCodesThatARetryCannotFixEndTheReadingAtOnce(code: String, expected: SpeechFailure) async {
        let workers = ScriptedSpeechWorkers([.rejects(#"{"kind":"error","code":"\#(code)"}"#)])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == expected)
        #expect(workers.launched.count == 1)
    }

    /// A packet from an earlier runtime has no code; an unknown code comes from a newer one.
    @Test(arguments: [#"{"kind":"error"}"#, #"{"kind":"error","code":"synthesis_failed"}"#, #"{"kind":"error","code":"from_the_future"}"#])
    func synthesisAndUncodedErrorsAreGenericAndRetriedOnce(packet: String) async {
        let workers = ScriptedSpeechWorkers([.rejects(packet), .rejects(packet)])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .failed)
        #expect(workers.launched.count == 2)
    }

    @Test func exitBeforeTheModelEverLoadedIsALoadFailureWithoutRetry() async {
        let workers = ScriptedSpeechWorkers([.exitsBeforeReady])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .loadFailed)
        #expect(workers.launched.count == 1)
    }

    @Test func truncatedPacketBeforeTheModelLoadedIsALoadFailure() async {
        let workers = ScriptedSpeechWorkers([.custom { worker in
            try await worker.nextRequest()
            try? worker.transportWriteWithoutNewline(#"{"kind":"re"#)
            worker.exit()
        }])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .loadFailed)
    }

    @Test func aCodedPacketSurvivesARefusedRequestWrite() async {
        let workers = ScriptedSpeechWorkers([.custom { worker in
            worker.send(#"{"kind":"error","code":"out_of_memory"}"#)
            worker.closeStandardInput()
            worker.exit()
        }])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .outOfMemory)
    }

    @Test func aWorkerThatCannotStartIsALoadFailure() async {
        let workers = ScriptedSpeechWorkers([])
        workers.launchError = SpeechFailure.loadFailed
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .loadFailed)
    }

    @Test func realLaunchMapsAMissingRuntimeToNotInstalled() {
        #expect(throws: SpeechFailure.notInstalled) {
            _ = try SpeechWorkerTransport.launch(.init(root: URL(fileURLWithPath: "/nonexistent-speech-root")))
        }
    }

    @Test func crashDuringSynthesisSurfacesAfterItsOneRetry() async {
        let workers = ScriptedSpeechWorkers([.crashesAfterAudio(), .crashesAfterAudio()])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .interrupted)
        #expect(workers.launched.count == 2, "Exactly one retry, no loop.")
        #expect(service.workerPID == nil)
        await service.waitForProducerToSettle()
        #expect(workers.launched.count == 2)
    }

    @Test func retryContinuesAfterWhatWasAlreadyDeliveredInsteadOfRepeatingIt() async throws {
        let workers = ScriptedSpeechWorkers([
            .crashesAfterAudio(bytes: 4_800),
            .custom { worker in
                // Other packet boundaries than the first attempt: only the byte position counts.
                let id = try await worker.nextRequest()
                worker.ready(id)
                worker.audio(id, bytes: 2_400)
                worker.audio(id, bytes: 4_800)
                worker.audio(id, bytes: 2_400)
                worker.end(id)
            },
        ])
        let service = workers.service()
        defer { service.stop() }
        try await service.read("Ein Text.") {}
        #expect(workers.launched.count == 2)
        #expect(service.playbackDiagnostics.frames == 2_400, "1,200 frames were heard, 1,200 follow; nothing twice.")
    }

    @Test func aFailedFollowUpIsRetriedWithAFreshWorkerAndPlaybackContinues() async throws {
        let workers = ScriptedSpeechWorkers([
            .finishesOneTextThenCrashes,
            .completes(bytes: 9_600),
        ])
        let service = workers.service()
        defer { service.stop() }
        service.prepareNext("Der nächste Text.")
        try await service.read("Der nächste Text.") {}
        #expect(workers.launched.count == 1)
        #expect(service.playbackDiagnostics.frames == 1_200)
        service.prepareNext("Noch ein Text.")
        try await workers.waitForLaunches(2)
        try await service.read("Noch ein Text.") {}
        #expect(workers.launched.count == 2, "Exactly one fresh worker.")
        #expect(workers.launched[1].receivedTexts == ["Noch ein Text."])
        #expect(service.playbackDiagnostics.frames == 2_400)
    }

    @Test func aSecondFailureOfThePassageSurfacesAtItsHandoffAndDoesNotLoop() async throws {
        let workers = ScriptedSpeechWorkers([
            .finishesOneTextThenCrashes,
            .crashesAfterAudio(),
        ])
        let service = workers.service()
        defer { service.stop() }
        try await service.read("Der erste Text.") {}
        service.prepareNext("Der zweite Text.")
        try await workers.waitForLaunches(2)
        await service.waitForProducerToSettle()
        let error = await failure { try await service.read("Der zweite Text.") {} }
        #expect(error as? SpeechFailure == .interrupted)
        #expect(workers.launched.count == 2)
        #expect(service.workerPID == nil)
        #expect(service.preparedAudioBytes == 0)
    }

    @Test func aRetryThatCannotLoadTheModelReportsTheLoadFailure() async {
        let workers = ScriptedSpeechWorkers([.crashesAfterAudio(), .exitsBeforeReady])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Ein Text.") {} }
        #expect(error as? SpeechFailure == .loadFailed)
        #expect(workers.launched.count == 2)
    }

    @Test func aWorkerThatDiedWhileIdleIsACrashNotALoadFailure() async throws {
        let workers = ScriptedSpeechWorkers([
            .custom { worker in
                let id = try await worker.nextRequest()
                worker.ready(id)
                worker.audio(id)
                worker.end(id)
                try await worker.nextRequest()
                worker.exit()
            },
            .completes(),
        ])
        let service = workers.service()
        defer { service.stop() }
        try await service.read("Der erste Text.") {}
        try await service.read("Der zweite Text.") {}
        #expect(workers.launched.count == 2)
    }

    @Test func stopDuringTheRetryEndsItAndLatePacketsNeverPlay() async throws {
        let retryIsWaiting = AsyncGate()
        var retryID = ""
        let workers = ScriptedSpeechWorkers([
            .crashesAfterAudio(),
            .custom { worker in
                retryID = try await worker.nextRequest()
                worker.ready(retryID)
                retryIsWaiting.open()
            },
        ])
        let service = workers.service()
        defer { service.stop() }
        let reading = Task { @MainActor in try await service.read("Ein Text.") {} }
        try await retryIsWaiting.wait()
        let framesBeforeStop = service.playbackDiagnostics.frames
        // In flight when Stop lands, and again after it, from both the dead and the stopped worker.
        // Longer than what the retry skips, so an accepted packet would be audible.
        workers.launched[1].audio(retryID, bytes: 48_000)
        service.stop()
        workers.launched[1].audio(retryID, bytes: 48_000)
        workers.launched[0].audio(retryID, bytes: 48_000)
        let error = await failure { try await reading.value }
        #expect(error is CancellationError)
        await service.waitForProducerToSettle()
        #expect(workers.launched.count == 2, "Stop must not start another worker.")
        #expect(workers.launched[1].killed)
        #expect(service.workerPID == nil)
        #expect(service.preparedAudioBytes == 0)
        #expect(service.playbackDiagnostics.frames == framesBeforeStop, "Nothing arrived after Stop.")
    }

    @Test func stopWhileTheFirstWorkerRunsNeverRetries() async throws {
        let waiting = AsyncGate()
        let workers = ScriptedSpeechWorkers([.custom { worker in
            let id = try await worker.nextRequest()
            worker.ready(id)
            waiting.open()
        }])
        let service = workers.service()
        defer { service.stop() }
        let reading = Task { @MainActor in try await service.read("Ein Text.") {} }
        try await waiting.wait()
        service.stop()
        let error = await failure { try await reading.value }
        #expect(error is CancellationError)
        await service.waitForProducerToSettle()
        #expect(workers.launched.count == 1, "Our own kill is not a crash.")
    }

    @Test func skippingAFailedPassageKeepsAFreshRetryBudgetForTheNext() async throws {
        let workers = ScriptedSpeechWorkers([.crashesAfterAudio(), .crashesAfterAudio(), .crashesAfterAudio(), .completes()])
        let service = workers.service()
        defer { service.stop() }
        let error = await failure { try await service.read("Der erste Text.") {} }
        #expect(error as? SpeechFailure == .interrupted)
        try await service.read("Der zweite Text.") {}
        #expect(workers.launched.count == 4, "The budget is per passage: one retry each, never more.")
    }

    @Test func messagesNameTheRealProblem() {
        for failure in [SpeechFailure.failed, .loadFailed, .outOfMemory, .interrupted, .timedOut, .invalidRequest] {
            #expect(failure.localizedDescription.range(of: "smaller", options: .caseInsensitive) == nil)
        }
        #expect(SpeechFailure.tooLong.localizedDescription.contains("smaller region"))
        #expect(SpeechFailure.loadFailed.localizedDescription == "The voice model could not be loaded. Reinstall Saywing to restore it.")
        #expect(SpeechFailure.outOfMemory.localizedDescription == "There wasn't enough memory for the voice. Close other apps and try again.")
        #expect(SpeechFailure.interrupted.localizedDescription == "Local speech stopped unexpectedly. Try again. No cloud or system voice was substituted.")
    }
}

/// A one-shot signal, so tests wait on a condition rather than a duration. An
/// unopened gate fails the test instead of hanging the run.
@MainActor
final class AsyncGate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async throws {
        for _ in 0..<2_500 where !isOpen { try await Task.sleep(for: .milliseconds(2)) }
        try #require(isOpen)
    }
}
