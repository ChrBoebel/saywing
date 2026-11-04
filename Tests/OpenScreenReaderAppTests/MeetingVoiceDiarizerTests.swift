import AVFoundation
import Foundation
import Testing
@testable import OpenScreenReader

private func segment(_ voice: Int, _ start: Int, _ end: Int) -> MeetingVoiceStretches.Segment {
    MeetingVoiceStretches.Segment(voice: voice, startFrame: start, endFrame: end)
}

@Suite("Meeting voice stretches")
struct MeetingVoiceStretchesTests {
    private func stretches(openStep: Int = 10) -> MeetingVoiceStretches {
        MeetingVoiceStretches(frameDuration: 0.1, openStep: openStep)
    }

    @Test
    func aFinishedSegmentIsReportedOnceInSeconds() {
        var stretches = stretches()
        #expect(stretches.spans(closed: [segment(3, 5, 20)], open: [], heard: 10)
            == [MeetingVoiceSpan(voice: 3, start: 0.5, end: 2)])
        #expect(stretches.spans(closed: [segment(3, 5, 20)], open: [], heard: 10).isEmpty)
    }

    /// A monologue must get its voice while it lasts, but not as a new span every
    /// 100 ms: each span costs the transcript a full re-derivation.
    @Test
    func aVoiceStillSpeakingIsReportedInSteps() {
        var stretches = stretches()
        #expect(stretches.spans(closed: [], open: [segment(0, 0, 5)], heard: 10).isEmpty)
        #expect(stretches.spans(closed: [], open: [segment(0, 0, 10)], heard: 10)
            == [MeetingVoiceSpan(voice: 0, start: 0, end: 1)])
        #expect(stretches.spans(closed: [], open: [segment(0, 0, 15)], heard: 10).isEmpty)
        #expect(stretches.spans(closed: [], open: [segment(0, 0, 20)], heard: 10)
            == [MeetingVoiceSpan(voice: 0, start: 1, end: 2)])
    }

    @Test
    func theEndOfASegmentIsReportedWithoutWaitingForTheStep() {
        var stretches = stretches()
        _ = stretches.spans(closed: [], open: [segment(0, 0, 10)], heard: 10)
        #expect(stretches.spans(closed: [segment(0, 0, 13)], open: [], heard: 10)
            == [MeetingVoiceSpan(voice: 0, start: 1, end: 1.3)])
    }

    @Test
    func voicesAreTrackedApartAndInTimeOrder() {
        var stretches = stretches()
        let spans = stretches.spans(closed: [segment(4, 20, 30), segment(1, 0, 10)], open: [], heard: 10)
        #expect(spans == [
            MeetingVoiceSpan(voice: 1, start: 0, end: 1),
            MeetingVoiceSpan(voice: 4, start: 2, end: 3),
        ])
        // An overlap of two speakers stays with both.
        #expect(stretches.spans(closed: [segment(1, 25, 35)], open: [], heard: 10)
            == [MeetingVoiceSpan(voice: 1, start: 2.5, end: 3.5)])
    }

    /// The flush at the end pads the audio with silence; no voice may reach past
    /// what was actually heard.
    @Test
    func noVoiceReachesPastTheAudioHeard() {
        var stretches = stretches()
        #expect(stretches.spans(closed: [segment(0, 0, 20)], open: [], heard: 1.5)
            == [MeetingVoiceSpan(voice: 0, start: 0, end: 1.5)])
        #expect(stretches.spans(closed: [segment(1, 16, 20)], open: [], heard: 1.5).isEmpty)
    }
}

private func tone(_ frequency: Double, seconds: Double, rate: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1)))
}

@Suite("Meeting voice audio")
struct MeetingVoiceAudioTests {
    private func convert(_ samples: [Float], rate: Double, chunk: Int) throws -> [Float] {
        var audio = try MeetingVoiceAudio(modelRate: 8_000)
        var output: [Float] = []
        for start in stride(from: 0, to: samples.count, by: chunk) {
            output += try audio.modelSamples(Array(samples[start..<min(start + chunk, samples.count)]), sampleRate: rate)
        }
        return output
    }

    @Test
    func audioAtTheModelRatePassesUnchanged() throws {
        let samples = tone(300, seconds: 0.1, rate: 8_000)
        #expect(try convert(samples, rate: 8_000, chunk: 37) == samples)
    }

    /// Converting each small chunk on its own, as `sourceSampleRate:` does, loses the
    /// filter state at every border and would drift against the meeting clock.
    @Test(arguments: [48_000.0, 44_100.0, 16_000.0])
    func smallChunksKeepTheirTimeAndContinuity(rate: Double) throws {
        let seconds = 2.0
        let output = try convert(tone(300, seconds: seconds, rate: rate), rate: rate, chunk: Int(rate / 100))
        // The filter may hold back a few milliseconds at the end, never more.
        #expect(abs(Double(output.count) / 8_000 - seconds) < 0.02)
        // A clean tone: every window has the tone's level, without clicks at borders.
        let body = Array(output[800..<(output.count - 800)])
        for start in stride(from: 0, to: body.count - 160, by: 160) {
            let level = rms(body[start..<(start + 160)])
            #expect(abs(level - 0.5 / 2.0.squareRoot()) < 0.01, "window at \(start): \(level)")
        }
    }

    @Test
    func aBurstStaysAtItsTime() throws {
        var samples = [Float](repeating: 0, count: 48_000 * 2)
        let burst = tone(300, seconds: 0.5, rate: 48_000)
        samples.replaceSubrange(48_000..<(48_000 + burst.count), with: burst)
        let output = try convert(samples, rate: 48_000, chunk: 480)
        let onset = try #require(output.firstIndex { abs($0) > 0.1 })
        #expect(abs(Double(onset) / 8_000 - 1) < 0.01)
    }

    @Test
    func aChangeOfSampleRateKeepsGoing() throws {
        var audio = try MeetingVoiceAudio(modelRate: 8_000)
        var count = 0
        for rate in [48_000.0, 44_100.0, 48_000.0] {
            for _ in 0..<100 {
                count += try audio.modelSamples(tone(300, seconds: 0.01, rate: rate), sampleRate: rate).count
            }
        }
        #expect(abs(Double(count) / 8_000 - 3) < 0.05)
    }
}

@Suite("Meeting voice model in the bundle")
struct MeetingVoiceBundleTests {
    private func temporaryResources() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test
    func withoutAModelThereIsNoDiarizer() {
        #expect(MeetingVoiceModel.makeDiarizer(in: temporaryResources()) == nil)
    }

    /// A broken model must not end the transcript and must not look like a working
    /// one: its load error reaches the window through the tracker's failure path.
    @Test
    func aBrokenModelReportsItsErrorOnceThroughTheTracker() throws {
        let resources = temporaryResources()
        defer { try? FileManager.default.removeItem(at: resources) }
        let model = resources.appendingPathComponent("Diarization/ls_eend_broken_100ms.mlmodelc")
        try FileManager.default.createDirectory(at: model.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data([0]).write(to: model.appendingPathComponent("weights/weight.bin"))
        let diarizer = try #require(MeetingVoiceModel.makeDiarizer(in: resources))
        let failures = FailureBox()
        let tracker = MeetingVoiceTracker(diarizer: diarizer, onVoices: { _ in Issue.record("no voices expected") },
                                          onFailure: { failures.add($0) })
        let chunk = MeetingAudioChunk(samples: [Float](repeating: 0, count: 800), sampleRate: 8_000, hostTime: 0)
        tracker.append(chunk, at: 0)
        tracker.append(chunk, at: 0.1)
        tracker.finish()
        #expect(failures.messages.count == 1)
        #expect(failures.messages.first?.isEmpty == false)
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var messages: [String] { lock.withLock { stored } }
    func add(_ message: String) { lock.withLock { stored.append(message) } }
}

// MARK: - Real model (opt-in)

/// A pinned model fetched with scripts/fetch-diarization-model.py. These tests run
/// only when the test environment names that folder:
/// `TEST_RUNNER_SAYWING_DIARIZATION_MODELS=<folder> xcodebuild test ...`
struct RealVoiceModel: CustomStringConvertible, Sendable {
    let variant: String
    let url: URL
    var description: String { variant }

    static let available: [RealVoiceModel] = {
        guard let root = ProcessInfo.processInfo.environment["SAYWING_DIARIZATION_MODELS"] else { return [] }
        return ["ami", "ch", "dih3"].compactMap { variant in
            let url = URL(fileURLWithPath: root)
                .appendingPathComponent("optimized/\(variant)/100ms/ls_eend_\(variant)_100ms.mlmodelc")
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("weights/weight.bin").path)
                ? RealVoiceModel(variant: variant, url: url) : nil
        }
    }()

    /// Through the same lookup and factory as the app, from a resources folder that
    /// holds only this model.
    func makeDiarizer() throws -> (diarizer: any MeetingVoiceDiarizing, resources: URL) {
        // A stable path: CoreML caches about 43 MB per model location, which a new
        // folder for every run would pile up in the test host's caches.
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("voice-model-\(variant)")
        try? FileManager.default.removeItem(at: resources)
        let folder = resources.appendingPathComponent("Diarization")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent(url.lastPathComponent), withDestinationURL: url)
        return (try #require(MeetingVoiceModel.makeDiarizer(in: resources)), resources)
    }
}

/// Anchors `Bundle(for:)` to the test bundle that carries the speech fixtures.
private final class VoiceFixtures {}

private func fixture(_ name: String) throws -> [Float] {
    let url = try #require(Bundle(for: VoiceFixtures.self).url(forResource: name, withExtension: "wav"))
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
}

/// A track with known turns: who speaks from when to when.
private struct VoiceTrack {
    var samples: [Float] = []
    var turns: [(reader: Int, start: TimeInterval, end: TimeInterval)] = []
    let rate: Double
    var duration: TimeInterval { Double(samples.count) / rate }

    mutating func add(_ part: [Float], reader: Int) {
        let start = duration
        samples += part
        turns.append((reader, start, duration))
    }

    /// Chunks as a live track delivers them.
    func chunks(of seconds: TimeInterval) -> [(time: TimeInterval, samples: [Float])] {
        let size = Int(rate * seconds)
        return stride(from: 0, to: samples.count, by: size).map {
            (Double($0) / rate, Array(samples[$0..<min($0 + size, samples.count)]))
        }
    }

    func resampled(to target: Double) throws -> VoiceTrack {
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let destination = try #require(AVAudioFormat(standardFormatWithSampleRate: target, channels: 1))
        let converter = try #require(AVAudioConverter(from: source, to: destination))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)))
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: AVAudioFrameCount(duration * target) + 1024))
        final class Fed: @unchecked Sendable { var done = false }
        let fed = Fed()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed.done { status.pointee = .endOfStream; return nil }
            fed.done = true
            status.pointee = .haveData
            return input
        }
        #expect(error == nil)
        var copy = VoiceTrack(rate: target)
        copy.turns = turns
        copy.samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        return copy
    }
}

/// Reader A, reader B, reader A: two LibriVox readers of the committed fixtures, cut
/// at the middle of A's clip. The fixtures are 8 kHz, which is also the model's rate.
private func recordedTrack() throws -> VoiceTrack {
    let female = try fixture("others-elli")
    var track = VoiceTrack(rate: 8_000)
    track.add(Array(female[..<(female.count / 2)]), reader: 0)
    track.add(try fixture("mine-karlsson-1") + fixture("mine-karlsson-2"), reader: 1)
    track.add(Array(female[(female.count / 2)...]), reader: 0)
    return track
}

/// How well spans match known turns. Readers and voices pair up one to one, largest
/// shared time first; all other time is wrong. Two readers heard as one voice lose
/// the second reader's time, and a reader who returns under a new voice loses that.
private struct VoiceScore: CustomStringConvertible {
    let voiceOfReader: [Int: Int]
    let correct: TimeInterval
    let attributed: TimeInterval
    let duration: TimeInterval
    let perTurn: [[Int: TimeInterval]]
    var share: Double { attributed > 0 ? correct / attributed : 0 }
    var coverage: Double { attributed / duration }
    let readers: Int
    var separatesReaders: Bool { voiceOfReader.count == readers }

    init(_ spans: [MeetingVoiceSpan], _ track: VoiceTrack) {
        duration = track.duration
        var seconds = track.turns.map { _ in [Int: TimeInterval]() }
        for span in spans {
            for (index, turn) in track.turns.enumerated() {
                let shared = min(span.end, turn.end) - max(span.start, turn.start)
                if shared > 0 { seconds[index][span.voice, default: 0] += shared }
            }
        }
        perTurn = seconds
        var byReader: [Int: [Int: TimeInterval]] = [:]
        for (index, turn) in track.turns.enumerated() {
            byReader[turn.reader, default: [:]].merge(seconds[index], uniquingKeysWith: +)
        }
        readers = Set(track.turns.map(\.reader)).count
        var voices: [Int: Int] = [:]
        var taken = Set<Int>()
        let pairs = byReader.flatMap { reader, times in times.map { (reader: reader, voice: $0.key, seconds: $0.value) } }
        for pair in pairs.sorted(by: { ($0.seconds, $1.reader, $1.voice) > ($1.seconds, $0.reader, $0.voice) })
        where voices[pair.reader] == nil && !taken.contains(pair.voice) {
            voices[pair.reader] = pair.voice
            taken.insert(pair.voice)
        }
        voiceOfReader = voices
        var correct = 0.0
        for (index, turn) in track.turns.enumerated() {
            if let voice = voiceOfReader[turn.reader] { correct += seconds[index][voice] ?? 0 }
        }
        self.correct = correct
        attributed = spans.reduce(0) { $0 + $1.end - $1.start }
    }

    var description: String {
        let turns = perTurn.map { times in
            times.sorted { $0.key < $1.key }.map { "v\($0.key)=\(String(format: "%.1f", $0.value))s" }.joined(separator: " ")
        }
        return String(format: "correct %.1f%% of %.1fs attributed, coverage %.1f%% of %.1fs, voices %@, turns [%@]",
                      share * 100, attributed, coverage * 100, duration, "\(voiceOfReader.sorted { $0.key < $1.key })",
                      turns.joined(separator: " | "))
    }
}

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

private final class SpanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MeetingVoiceSpan] = []
    private var storedFailures: [String] = []
    var spans: [MeetingVoiceSpan] { lock.withLock { stored } }
    var failures: [String] { lock.withLock { storedFailures } }
    func add(_ spans: [MeetingVoiceSpan]) { lock.withLock { stored += spans } }
    func fail(_ message: String) { lock.withLock { storedFailures.append(message) } }
}

/// The installed `say` voices of a locale; which ones exist differs between Macs.
private func systemVoices(_ locale: String) throws -> [String] {
    let list = Process(), pipe = Pipe()
    list.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    list.arguments = ["-v", "?"]
    list.standardOutput = pipe
    try list.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    list.waitUntilExit()
    return output.split(separator: "\n").compactMap { line in
        guard let match = line.firstMatch(of: /^(.+?)\s+([a-z]{2,3}_[A-Z0-9]{2,3})\s+#/), match.2 == locale else { return nil }
        return String(match.1)
    }
}

private func systemSpeech(_ text: String, voice: String, rate: Int) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", voice, "--file-format=caff", "--data-format=LEF32@\(rate)", "-o", url.path, text]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0)
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
}

/// The bar was set before the first measurement and is not tuned to it.
private let requiredShare = 0.8

@Suite("Meeting voices with the real model", .serialized,
       .enabled(if: !RealVoiceModel.available.isEmpty, "Needs TEST_RUNNER_SAYWING_DIARIZATION_MODELS"))
struct RealVoiceModelTests {
    /// Feeds the adapter directly and measures it: load time, speed, memory, how late
    /// a label comes, and what ends up on disk.
    @Test(arguments: RealVoiceModel.available)
    func twoRecordedReadersGetTheirOwnVoices(model: RealVoiceModel) throws {
        let track = try recordedTrack()
        let before = footprintMB()
        let clock = ContinuousClock()
        var made: (diarizer: any MeetingVoiceDiarizing, resources: URL)!
        let load = try clock.measure { made = try model.makeDiarizer() }
        defer { try? FileManager.default.removeItem(at: made.resources) }
        let loaded = footprintMB()
        var spans: [MeetingVoiceSpan] = []
        var lags: [TimeInterval] = []
        var peak = loaded
        let feed = try clock.measure {
            for chunk in track.chunks(of: 0.02) {
                let new = try made.diarizer.append(chunk.samples, sampleRate: track.rate)
                let heard = chunk.time + 0.02
                lags += new.map { heard - $0.end }
                spans += new
                peak = max(peak, footprintMB())
            }
            spans += try made.diarizer.finish()
        }
        let score = VoiceScore(spans, track)
        let feedSeconds = Double(feed.components.seconds) + Double(feed.components.attoseconds) * 1e-18
        lags.sort()
        print("VOICE-MODEL recorded \(model.variant): \(score)")
        print(String(format: "VOICE-MODEL cost %@: load %@, real-time factor %.4f, footprint %.0f -> %.0f -> peak %.0f MB, %d spans, label lag median %.2f s max %.2f s",
                     model.variant, "\(load)", feedSeconds / track.duration, before, loaded, peak, spans.count,
                     lags.isEmpty ? .nan : lags[lags.count / 2], lags.last ?? .nan))
        #expect(score.separatesReaders, "\(model.variant): \(score)")
        #expect(score.share >= requiredShare, "\(model.variant): \(score)")
        #expect(feedSeconds / track.duration < 0.5, "must keep up with live audio next to two recognisers")
        #expect(spans.allSatisfy { $0.end <= track.duration + 0.001 })
    }

    /// The production path: 48 kHz chunks of 10 ms through the tracker's queue.
    @Test(arguments: RealVoiceModel.available)
    func theLivePathAt48kHzSeparatesThemToo(model: RealVoiceModel) throws {
        let track = try recordedTrack().resampled(to: 48_000)
        let made = try model.makeDiarizer()
        defer { try? FileManager.default.removeItem(at: made.resources) }
        let box = SpanBox()
        // Live audio arrives in real time; this test feeds it as fast as it can.
        let tracker = MeetingVoiceTracker(diarizer: made.diarizer, backlogLimit: 3_600,
                                          onVoices: { box.add($0) }, onFailure: { box.fail($0) })
        for chunk in track.chunks(of: 0.01) {
            tracker.append(MeetingAudioChunk(samples: chunk.samples, sampleRate: track.rate, hostTime: 0), at: chunk.time)
        }
        tracker.finish()
        let score = VoiceScore(box.spans, track)
        print("VOICE-MODEL live-48k \(model.variant): \(score)")
        #expect(box.failures.isEmpty)
        #expect(score.separatesReaders, "\(model.variant): \(score)")
        #expect(score.share >= requiredShare, "\(model.variant): \(score)")
    }

    /// Three system voices, two turns each, generated at the rate a call delivers.
    /// Synthetic speech: it says little about real people, but it has wider bands
    /// than the recordings before the model's own 8 kHz input.
    @Test(arguments: RealVoiceModel.available)
    func threeSystemVoicesTakeTurns(model: RealVoiceModel) throws {
        let rate = 48_000
        let voices = Array(try systemVoices("de_DE").filter { !$0.contains("Eloquence") }.prefix(3))
        try #require(voices.count == 3, "needs three installed German voices, found \(voices)")
        let lines = [
            "Guten Morgen zusammen, ich fange heute mit dem Stand zum Projekt an und nenne die offenen Punkte.",
            "Danke dafür. Haben wir das Budget für die neuen Server inzwischen freigegeben oder fehlt noch etwas?",
            "Nach meinem Stand fehlt nur noch die Unterschrift, die Bestellung kann danach sofort hinausgehen.",
            "Gut, dann schreibe ich das so ins Protokoll und frage in der nächsten Woche noch einmal nach.",
            "Bitte nimm auch die Lieferzeit auf, denn der Umzug im Rechenzentrum hängt direkt davon ab.",
            "Das mache ich gerne, und ich schicke euch am Nachmittag die Zusammenfassung mit allen Terminen.",
        ]
        var track = VoiceTrack(rate: Double(rate))
        for (index, line) in lines.enumerated() {
            track.add(try systemSpeech(line, voice: voices[index % voices.count], rate: rate), reader: index % voices.count)
            track.samples += [Float](repeating: 0, count: rate / 2)
        }
        let made = try model.makeDiarizer()
        defer { try? FileManager.default.removeItem(at: made.resources) }
        var spans: [MeetingVoiceSpan] = []
        for chunk in track.chunks(of: 0.01) { spans += try made.diarizer.append(chunk.samples, sampleRate: track.rate) }
        spans += try made.diarizer.finish()
        let score = VoiceScore(spans, track)
        print("VOICE-MODEL system-voices \(model.variant) \(voices): \(score)")
        #expect(score.separatesReaders, "\(model.variant): \(score)")
        #expect(score.share >= requiredShare, "\(model.variant): \(score)")
    }

    /// Loading may leave CoreML's compiled form of the model in the app's caches. The
    /// session itself adds nothing there, and nothing to FluidAudio's download cache
    /// or the temporary folder: no audio and no state about the voices.
    @Test(arguments: RealVoiceModel.available)
    func aSessionWritesNothingAfterLoadingTheModel(model: RealVoiceModel) throws {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "none")
        func files(_ root: URL) -> Set<String> {
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
            return Set(walker.compactMap { ($0 as? URL)?.path })
        }
        let temporary = manager.temporaryDirectory
        let beforeLoad = [support.appendingPathComponent("FluidAudio"), temporary].map(files)
        let track = try recordedTrack()
        let made = try model.makeDiarizer()
        defer { try? manager.removeItem(at: made.resources) }
        let afterLoad = files(caches)
        for chunk in track.chunks(of: 0.02) { _ = try made.diarizer.append(chunk.samples, sampleRate: track.rate) }
        _ = try made.diarizer.finish()
        let cached = files(caches).subtracting(afterLoad)
        let downloads = files(support.appendingPathComponent("FluidAudio")).subtracting(beforeLoad[0])
        // The temporary folder is shared with the user's other processes, so only audio
        // counts there. A per-process trace of file writes remains a gate of ADR 0008.
        let audio = files(temporary).subtracting(beforeLoad[1])
            .filter { path in [".wav", ".caf", ".aif", ".aiff", ".pcm", ".m4a"].contains { path.hasSuffix($0) } }
        #expect(cached.isEmpty, "The session added to the caches: \(cached)")
        #expect(downloads.isEmpty, "FluidAudio's download cache must stay untouched: \(downloads)")
        #expect(audio.isEmpty, "Audio in the temporary folder: \(audio)")
    }
}
