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

/// Frames of 10 ms in which only `voice` speaks, or nobody.
private func frames(_ voice: Int?, seconds: Double, voices: Int = 8) -> [Float] {
    let count = Int((seconds * 100).rounded())
    var probabilities = [Float](repeating: 0.02, count: count * voices)
    if let voice { for frame in 0..<count { probabilities[frame * voices + voice] = 0.95 } }
    return probabilities
}

@Suite("Meeting voice frames")
struct MeetingVoiceFramesTests {
    @Test
    func eightVoicesAreToldApartInTheirOwnTime() throws {
        var voices = MeetingVoiceFrames(voices: 8, frameDuration: 0.01)
        var spans: [MeetingVoiceSpan] = []
        for voice in 0..<8 {
            spans += try voices.spans(frames(voice, seconds: 1.5) + frames(nil, seconds: 0.5), heard: Double(voice + 1) * 2, final: false)
        }
        spans += try voices.spans([], heard: 16, final: true)
        #expect(Set(spans.map(\.voice)) == Set(0..<8))
        for voice in 0..<8 {
            let own = spans.filter { $0.voice == voice }
            #expect(abs((own.map(\.start).min() ?? -1) - Double(voice) * 2) < 0.011)
            #expect(abs(own.reduce(0) { $0 + $1.end - $1.start } - 1.5) < 0.011, "voice \(voice): \(own)")
        }
    }

    /// The model hands over 0.72 s at a time; a monologue must get its voice while it
    /// lasts, but as one new stretch a second, not one per step.
    @Test
    func aVoiceStillSpeakingIsReportedOnceASecond() throws {
        var voices = MeetingVoiceFrames(voices: 8, frameDuration: 0.01)
        var spans: [MeetingVoiceSpan] = []
        for step in 1...10 {
            spans += try voices.spans(frames(3, seconds: 0.72), heard: 0.72 * Double(step), final: false)
        }
        #expect(spans.count >= 5 && spans.count < 10, "\(spans)")
        #expect(spans.allSatisfy { $0.voice == 3 })
        #expect(spans.dropLast().allSatisfy { $0.end - $0.start >= 1 })
        #expect(zip(spans, spans.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 })
        spans += try voices.spans([], heard: 7.2, final: true)
        #expect(spans.first?.start == 0)
        #expect(abs((spans.last?.end ?? 0) - 7.2) < 1e-9)
    }

    @Test
    func aBlipIsNoVoiceAndABreathIsNoChange() throws {
        var voices = MeetingVoiceFrames(voices: 8, frameDuration: 0.01)
        var spans = try voices.spans(frames(1, seconds: 0.1) + frames(nil, seconds: 2), heard: 2.1, final: false)
        spans += try voices.spans(frames(2, seconds: 1) + frames(nil, seconds: 0.3) + frames(2, seconds: 1), heard: 4.4, final: false)
        spans += try voices.spans([], heard: 4.4, final: true)
        #expect(spans.allSatisfy { $0.voice == 2 })
        #expect(abs(spans.reduce(0) { $0 + $1.end - $1.start } - 2.3) < 0.011)
    }

    /// Two hours of meeting must not leave two hours of frames in memory.
    @Test
    func nothingGrowsWithTheMeeting() throws {
        var voices = MeetingVoiceFrames(voices: 8, frameDuration: 0.01)
        for step in 0..<1_000 {
            _ = try voices.spans(frames(step / 4 % 8, seconds: 0.72), heard: 0.72 * Double(step + 1), final: false)
        }
        #expect(voices.retainedFrames == 0)
    }
}

/// A Diarization folder as scripts/bundle-diarization-model.py leaves it in the app,
/// with stand-in files.
private func diarizationFolder(preset: String = "fast", model: String = "Nemotron3Diarizer_fast.mlmodelc",
                               writing files: [String]? = nil) throws -> URL {
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = resources.appendingPathComponent("Diarization")
    let listed = ["\(model)/coremldata.bin", "\(model)/model.mil", "\(model)/weights/weight.bin", "learnable_sil_emb.bin"]
    let manifest: [String: Any] = [
        "bundled_preset": preset,
        "presets": [preset: ["subdirectory": "monolithic/v2", "model": model,
                             "files": listed.map { ["rfilename": $0.hasSuffix(".bin") && !$0.contains("/") ? $0 : "monolithic/v2/\($0)",
                                                    "size": 1, "verified_sha256": String(repeating: "0", count: 64)] }]],
    ]
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(MeetingVoiceModel.manifestName))
    for file in files ?? listed {
        let url = folder.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }
    return resources
}

@Suite("Meeting voice model in the bundle")
struct MeetingVoiceBundleTests {
    @Test
    func withoutAModelThereIsNoDiarizer() {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(MeetingVoiceModel.bundled(in: resources) == nil)
        #expect(MeetingVoiceModel.makeDiarizer(in: resources) == nil)
    }

    /// The manifest that came with the model says which model to load, and every file
    /// it lists must be there.
    @Test
    func theManifestNamesTheModelAndEveryFileMustBeThere() throws {
        let resources = try diarizationFolder()
        defer { try? FileManager.default.removeItem(at: resources) }
        let found = try #require(MeetingVoiceModel.bundled(in: resources))
        #expect(found.preset == "fast")
        #expect(found.model == "Nemotron3Diarizer_fast.mlmodelc")
        #expect(found.directory.lastPathComponent == "Diarization")
        for missing in ["Nemotron3Diarizer_fast.mlmodelc/weights/weight.bin", "learnable_sil_emb.bin"] {
            let partial = try diarizationFolder(writing: ["Nemotron3Diarizer_fast.mlmodelc/coremldata.bin",
                                                          "Nemotron3Diarizer_fast.mlmodelc/model.mil",
                                                          "Nemotron3Diarizer_fast.mlmodelc/weights/weight.bin",
                                                          "learnable_sil_emb.bin"].filter { $0 != missing })
            defer { try? FileManager.default.removeItem(at: partial) }
            #expect(MeetingVoiceModel.bundled(in: partial) == nil, "\(missing)")
        }
    }

    /// A preset this FluidAudio does not know, or one whose model file is another,
    /// is no model at all rather than a wrong one.
    @Test
    func aPresetThatDoesNotMatchTheRuntimeIsRefused() async throws {
        for (preset, model) in [("unknown", "Nemotron3Diarizer_fast.mlmodelc"), ("fast", "Nemotron3Diarizer_low.mlmodelc")] {
            let resources = try diarizationFolder(preset: preset, model: model)
            defer { try? FileManager.default.removeItem(at: resources) }
            await #expect(throws: (any Error).self) { try await MeetingVoiceModel.loadDiarizer(in: resources) }
        }
    }

    /// A broken model must not end the transcript and must not look like a working
    /// one: its load error reaches the window through the tracker's failure path.
    @Test
    func aBrokenModelReportsItsErrorOnceThroughTheTracker() throws {
        let resources = try diarizationFolder()
        defer { try? FileManager.default.removeItem(at: resources) }
        let diarizer = try #require(MeetingVoiceModel.makeDiarizer(in: resources))
        let failures = FailureBox()
        let tracker = MeetingVoiceTracker(diarizer: diarizer, onVoices: { _ in Issue.record("no voices expected") },
                                          onFailure: { failures.add($0) })
        let chunk = MeetingAudioChunk(samples: [Float](repeating: 0, count: 1_600), sampleRate: 16_000, hostTime: 0)
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
/// only when the test environment names that folder (or a folder of such folders,
/// one per preset):
/// `TEST_RUNNER_SAYWING_DIARIZATION_MODELS=<folder> xcodebuild test ...`
struct RealVoiceModel: CustomStringConvertible, Sendable {
    let preset: String
    /// The fetched folder, laid out like the app's Diarization folder.
    let folder: URL
    var description: String { preset }

    static let available: [RealVoiceModel] = {
        guard let root = ProcessInfo.processInfo.environment["SAYWING_DIARIZATION_MODELS"] else { return [] }
        let top = URL(fileURLWithPath: root)
        let folders = [top] + ((try? FileManager.default.contentsOfDirectory(at: top, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        return folders.compactMap { folder in
            let resources = Self.resources(for: folder)
            return MeetingVoiceModel.bundled(in: resources).map { RealVoiceModel(preset: $0.preset, folder: folder) }
        }
    }()

    /// A stable resources folder whose Diarization folder is the fetched one: CoreML
    /// keeps a compiled form per model location, which a new folder every run would
    /// pile up in the test host's caches.
    private static func resources(for folder: URL) -> URL {
        let name = folder.path.replacingOccurrences(of: "/", with: "_")
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("voice-model\(name)")
        let link = resources.appendingPathComponent("Diarization")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != folder.path {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        }
        return resources
    }

    var resources: URL { Self.resources(for: folder) }

    /// The model itself, loaded the way the app's preload loads it.
    func load() async throws -> any MeetingVoiceDiarizing {
        try await MeetingVoiceModel.loadDiarizer(in: resources)
    }

    /// Through the same lookup and factory as the app: the preload that stands in for
    /// the model while it loads.
    func makeDiarizer() throws -> any MeetingVoiceDiarizing {
        try #require(MeetingVoiceModel.makeDiarizer(in: resources))
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
/// at the middle of A's clip. The fixtures are 8 kHz; the adapter brings them to the model's 16 kHz.
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
    func twoRecordedReadersGetTheirOwnVoices(model: RealVoiceModel) async throws {
        let track = try recordedTrack()
        let before = footprintMB()
        let clock = ContinuousClock()
        let started = clock.now
        let diarizer = try await model.load()
        let load = clock.now - started
        let loaded = footprintMB()
        var spans: [MeetingVoiceSpan] = []
        var lags: [TimeInterval] = []
        var peak = loaded
        let feed = try clock.measure {
            for chunk in track.chunks(of: 0.02) {
                let new = try diarizer.append(chunk.samples, sampleRate: track.rate)
                let heard = chunk.time + 0.02
                lags += new.map { heard - $0.end }
                spans += new
                peak = max(peak, footprintMB())
            }
            spans += try diarizer.finish()
        }
        let score = VoiceScore(spans, track)
        let feedSeconds = Double(feed.components.seconds) + Double(feed.components.attoseconds) * 1e-18
        lags.sort()
        print("VOICE-MODEL recorded \(model.preset): \(score)")
        print(String(format: "VOICE-MODEL cost %@: load %@, real-time factor %.4f, footprint %.0f -> %.0f -> peak %.0f MB, %d spans, label lag median %.2f s max %.2f s",
                     model.preset, "\(load)", feedSeconds / track.duration, before, loaded, peak, spans.count,
                     lags.isEmpty ? .nan : lags[lags.count / 2], lags.last ?? .nan))
        #expect(score.separatesReaders, "\(model.preset): \(score)")
        #expect(score.share >= requiredShare, "\(model.preset): \(score)")
        #expect(feedSeconds / track.duration < 0.5, "must keep up with live audio next to two recognisers")
        #expect(spans.allSatisfy { $0.end <= track.duration + 0.001 })
    }

    /// The production path: the preload that loads the model while the transcript
    /// already runs, then 48 kHz chunks of 10 ms through the tracker's queue. Audio
    /// from before the model was ready gets its voices too.
    @Test(arguments: RealVoiceModel.available)
    func theLivePathAt48kHzSeparatesThemToo(model: RealVoiceModel) throws {
        let track = try recordedTrack().resampled(to: 48_000)
        let box = SpanBox()
        // Live audio arrives in real time; this test feeds it as fast as it can.
        let tracker = MeetingVoiceTracker(diarizer: try model.makeDiarizer(), backlogLimit: 3_600,
                                          onVoices: { box.add($0) }, onFailure: { box.fail($0) })
        for chunk in track.chunks(of: 0.01) {
            tracker.append(MeetingAudioChunk(samples: chunk.samples, sampleRate: track.rate, hostTime: 0), at: chunk.time)
        }
        tracker.finish()
        let score = VoiceScore(box.spans, track)
        print("VOICE-MODEL live-48k \(model.preset): \(score)")
        #expect(box.failures.isEmpty)
        #expect(score.separatesReaders, "\(model.preset): \(score)")
        #expect(score.share >= requiredShare, "\(model.preset): \(score)")
    }

    /// Three system voices, two turns each, generated at the rate a call delivers.
    /// Synthetic speech: it says little about real people, but it has wider bands
    /// than the 8 kHz recordings.
    @Test(arguments: RealVoiceModel.available)
    func threeSystemVoicesTakeTurns(model: RealVoiceModel) async throws {
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
        let diarizer = try await model.load()
        var spans: [MeetingVoiceSpan] = []
        for chunk in track.chunks(of: 0.01) { spans += try diarizer.append(chunk.samples, sampleRate: track.rate) }
        spans += try diarizer.finish()
        let score = VoiceScore(spans, track)
        print("VOICE-MODEL system-voices \(model.preset) \(voices): \(score)")
        #expect(score.separatesReaders, "\(model.preset): \(score)")
        #expect(score.share >= requiredShare, "\(model.preset): \(score)")
    }

    /// Loading may leave CoreML's compiled form of the model in the app's caches. The
    /// session itself adds nothing there, and nothing to FluidAudio's download cache
    /// or the temporary folder: no audio and no state about the voices.
    @Test(arguments: RealVoiceModel.available)
    func aSessionWritesNothingAfterLoadingTheModel(model: RealVoiceModel) async throws {
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
        let diarizer = try await model.load()
        let afterLoad = files(caches)
        for chunk in track.chunks(of: 0.02) { _ = try diarizer.append(chunk.samples, sampleRate: track.rate) }
        _ = try diarizer.finish()
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
