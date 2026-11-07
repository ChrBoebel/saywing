import Accelerate
import AppKit
import SwiftUI
import AVFoundation
import Foundation
import PDFKit
import Testing
@testable import OpenScreenReader

private func heard(_ speaker: MeetingSpeaker, _ start: TimeInterval, _ end: TimeInterval, _ text: String,
                   final: Bool = true) -> MeetingRecognition {
    MeetingRecognition(speaker: speaker, start: start, end: end, text: text, isFinal: final)
}

@Suite("Meeting transcript model")
struct MeetingTranscriptTests {
    @Test
    func volatileTextIsReplacedInPlaceAndClearedByTheFinalText() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.others, 0, 1, "Guten", final: false))
        transcript.apply(heard(.others, 0, 2, "Guten Morgen zu", final: false))
        #expect(transcript.entries.map(\.pending) == ["Guten Morgen zu"])
        transcript.apply(heard(.others, 0, 2.5, "Guten Morgen zusammen."))
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].text == "Guten Morgen zusammen.")
        #expect(transcript.entries[0].pending.isEmpty)
    }

    @Test
    func turnsFollowTimeAcrossBothSpeakersAndMergeConsecutiveSegments() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.others, 5, 7, "Und wie siehst du das?"))
        transcript.apply(heard(.me, 0, 2, "Kurzer Stand."))
        transcript.apply(heard(.me, 2.2, 4, "Alles grün."))
        transcript.apply(heard(.me, 8, 9, "Gut", final: false))
        #expect(transcript.entries.map(\.speaker) == [.me, .others, .me])
        #expect(transcript.entries[0].text == "Kurzer Stand. Alles grün.")
        #expect(transcript.entries[2].text.isEmpty)
        #expect(transcript.entries[2].pending == "Gut")
    }

    @Test
    func emptyResultsNeverCreateTurns() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.me, 0, 1, "  ", final: false))
        transcript.apply(heard(.me, 0, 1, ""))
        #expect(transcript.entries.isEmpty)
        #expect(transcript.isEmpty)
    }

    @Test
    func myTextInsideAnEchoSpanIsHiddenEvenWhenTheSpanArrivesLater() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.me, 10, 12, "Wir sehen uns morgen"))
        transcript.apply(heard(.me, 20, 22, "Das sage ich selbst"))
        #expect(transcript.entries.map(\.text) == ["Wir sehen uns morgen Das sage ich selbst"])
        transcript.addEcho(9.5...12.5)
        #expect(transcript.entries.map(\.text) == ["Das sage ich selbst"])
    }

    @Test
    func myTextThatRepeatsTheOthersAtTheSameMomentIsHidden() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.me, 30.4, 33, "dann plane ich den Prototypen"))
        transcript.apply(heard(.others, 30, 32.8, "Dann plane ich den ersten Prototypen."))
        transcript.apply(heard(.me, 31, 31.5, "ja"))
        transcript.apply(heard(.me, 50, 52, "dann plane ich den Prototypen"))
        // A short reply is kept; the same sentence later, without the others, is mine.
        #expect(transcript.entries.map(\.speaker) == [.others, .me])
        #expect(transcript.entries[1].text == "ja dann plane ich den Prototypen")
    }

    @Test
    func echoWordsLeaveAMixedSegmentWhileMyWordsStay() {
        var transcript = MeetingTranscript()
        let echo = ["Wir", "haben", "die", "Tests", "fertig."].enumerated().map {
            MeetingPiece(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.8)
        }
        let mine = ["Danke", ",", "bis", "Freitag."].enumerated().map {
            MeetingPiece(text: $0.element, start: 7 + Double($0.offset), end: 7.8 + Double($0.offset))
        }
        transcript.apply(MeetingRecognition(speaker: .me, start: 0, end: 10, text: "Wir haben die Tests fertig. Danke, bis Freitag.",
                                            isFinal: true, pieces: echo + mine))
        transcript.addEcho(0.1...5.8)
        #expect(transcript.entries.map(\.text) == ["Danke, bis Freitag."])
    }

    @Test
    func repeatedWordRunsLeaveAMixedSegmentWithoutTimings() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.others, 0, 5, "Wir haben die Tests fertig."))
        transcript.apply(heard(.me, 0, 10, "Wir haben die Tests fertig. Danke, dann plane ich Freitag."))
        let mine = transcript.entries.filter { $0.speaker == .me }.map(\.text)
        #expect(mine == ["Danke, dann plane ich Freitag."])
    }

    /// From a real call over laptop speakers (2026-10-21): the microphone heard the
    /// others through the room and the recogniser wrote it down roughly.
    @Test
    func roughlyHeardEchoOfTheOthersIsHiddenWhileMyOwnWordsStay() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.me, 4, 8, "Test Test Test. Reli, die dies ist"))
        transcript.apply(heard(.others, 27, 37, "Auf dem Oktoberfest hab ich auch schon erlebt, dass Leute sagen, Mai, du bist der kleine am ersten Dog Millionär. Wir haben einfach null Ahnung. Nein, er hat die Pommes genommen mit Ständer."))
        transcript.apply(heard(.me, 27, 33, "Auf demorfest nein, Dorf Millionär. Sender."))
        transcript.apply(heard(.others, 38, 53, "Wir brauchen. Nein, keine Insel, kein Strand machen Party auf dem Macker. Bot. Neues Gerät schon im Eimer, super. Bei der Wiesen gibt's im Prinzip sechs Kriterien. Lage, Lage, Lage, Wetter, Wetter, Wetter."))
        transcript.apply(heard(.me, 40, 42, "auf gibt es . Strand"))
        transcript.apply(heard(.me, 45, 47, "Nein, das Oktoberfest ist mir zu voll"))
        let mine = transcript.entries.filter { $0.speaker == .me }.map(\.text)
        #expect(mine == ["Test Test Test. Reli, die dies ist", "Nein, das Oktoberfest ist mir zu voll"])
    }

    @Test
    func echoSpansMergeWhenTheyOverlap() {
        var transcript = MeetingTranscript()
        transcript.addEcho(1...3)
        transcript.addEcho(2.5...4)
        transcript.addEcho(10...11)
        #expect(transcript.echoSpans == [1...4, 10...11])
    }

    @Test
    func exportListsSpeakerTimeAndTextWithoutHiddenEcho() {
        var transcript = MeetingTranscript()
        transcript.apply(heard(.me, 3, 5, "Kurzer Stand."))
        transcript.apply(heard(.others, 65, 70, "Danke."))
        transcript.apply(heard(.me, 66, 68, "Danke"))
        transcript.addEcho(65...70)
        #expect(transcript.exportText(title: "Meeting") == """
            # Meeting

            **Me** · 00:00:03
            Kurzer Stand.

            **Others** · 00:01:05
            Danke.

            """)
    }

    @Test
    func clockFormatsElapsedAndTimestamps() {
        #expect(MeetingClock.elapsed(59) == "0:59")
        #expect(MeetingClock.elapsed(3_725) == "1:02:05")
        #expect(MeetingClock.timestamp(65) == "00:01:05")
    }
}

@Suite("Meeting audio timeline")
struct MeetingTimelineTests {
    @Test
    func continuousChunksStayGaplessDespiteDeliveryJitter() {
        var timeline = MeetingTimeline()
        #expect(timeline.place(at: 0.30, duration: 0.1) == 0.30)
        #expect(abs(timeline.place(at: 0.43, duration: 0.1) - 0.40) < 1e-9)
        #expect(abs(timeline.place(at: 0.48, duration: 0.1) - 0.50) < 1e-9)
    }

    @Test
    func analyzerStampsAreWholeSamplesThatNeverOverlap() {
        var timeline = MeetingFrameTimeline(rate: 16_000)
        var previousEnd: Int64 = 0
        for (index, frames) in [1_600, 1_599, 1_601, 1_600, 1_598].enumerated() {
            let start = timeline.place(at: 100 + Double(index) * 0.1 + 0.0004, frames: frames)
            #expect(index == 0 || start == previousEnd)
            previousEnd = start + Int64(frames)
        }
        #expect(timeline.place(at: 200, frames: 10) == 3_200_000)
    }

    @Test
    func aRealGapJumpsAheadAndTimeNeverRunsBackwards() {
        var timeline = MeetingTimeline()
        _ = timeline.place(at: 1, duration: 0.1)
        #expect(timeline.place(at: 3, duration: 0.1) == 3)
        #expect(abs(timeline.place(at: 2, duration: 0.1) - 3.1) < 1e-9)
    }
}

/// Deterministic speech-like test signals: noise shaped by a 4 Hz syllable envelope.
private struct SignalSource {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func noise() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
    }
    mutating func speech(seconds: Double, rate: Double = 8_000, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * rate)).map { index in
            let envelope = Float(0.55 + 0.45 * sin(2 * Double.pi * 4 * Double(index) / rate))
            return noise() * level * envelope
        }
    }
}

private func delayed(_ signal: [Float], by seconds: Double, gain: Float, rate: Double = 8_000) -> [Float] {
    let shift = Int(seconds * rate)
    return (0..<signal.count).map { $0 >= shift ? signal[$0 - shift] * gain : 0 }
}

/// The scores of every analysis while feeding, for calibration.
private func scores(_ gate: EchoGate, system: [Float], mic: [Float], rate: Double = 8_000) -> [Float] {
    let chunk = Int(rate / 10)
    var found: [Float] = []
    for offset in stride(from: 0, to: min(system.count, mic.count), by: chunk) {
        let end = min(offset + chunk, system.count, mic.count)
        let before = gate.lastScore
        _ = gate.append(Array(system[offset..<end]), at: Double(offset) / rate, track: .others)
        _ = gate.append(Array(mic[offset..<end]), at: Double(offset) / rate, track: .me)
        if gate.lastScore != before { found.append(gate.lastScore) }
    }
    return found
}

/// Feeds both tracks in 100 ms chunks, as the audio callbacks would.
private func feed(_ gate: EchoGate, system: [Float], mic: [Float], from start: TimeInterval = 0,
                  rate: Double = 8_000) -> [ClosedRange<TimeInterval>] {
    let chunk = Int(rate / 10)
    var spans: [ClosedRange<TimeInterval>] = []
    for offset in stride(from: 0, to: min(system.count, mic.count), by: chunk) {
        let end = min(offset + chunk, system.count, mic.count)
        let time = start + Double(offset) / rate
        spans += gate.append(Array(system[offset..<end]), at: time, track: .others)
        spans += gate.append(Array(mic[offset..<end]), at: time, track: .me)
    }
    return spans
}

private func covered(_ spans: [ClosedRange<TimeInterval>], _ range: ClosedRange<TimeInterval>) -> Double {
    var transcript = MeetingTranscript()
    spans.forEach { transcript.addEcho($0) }
    let total = transcript.echoSpans.reduce(0.0) {
        $0 + max(0, min($1.upperBound, range.upperBound) - max($1.lowerBound, range.lowerBound))
    }
    return total / (range.upperBound - range.lowerBound)
}

@Suite("Meeting echo gate")
struct EchoGateTests {
    @Test
    func speakerEchoInTheMicrophoneIsFoundWithItsDelayFromTheStart() {
        var source = SignalSource(seed: 1)
        let system = source.speech(seconds: 8)
        var noise = SignalSource(seed: 2)
        let mic = zip(delayed(system, by: 0.12, gain: 0.3), noise.speech(seconds: 8, level: 0.004)).map { $0 + $1 }
        let gate = EchoGate()
        let spans = feed(gate, system: system, mic: mic)
        #expect(covered(spans, 0.5...8) > 0.9)
        #expect(spans.map(\.lowerBound).min() ?? 99 <= 0.5)
        #expect(abs((gate.lockedLag ?? 0) - 0.12) < 0.01)
    }

    @Test
    func myOwnVoiceWhileOthersSpeakIsNotAnEcho() {
        var others = SignalSource(seed: 3)
        var me = SignalSource(seed: 4)
        let spans = feed(EchoGate(), system: others.speech(seconds: 8), mic: me.speech(seconds: 8))
        #expect(spans.isEmpty)
    }

    @Test
    func silenceFromOtherAppsNeverMarksAnEcho() {
        var me = SignalSource(seed: 5)
        let spans = feed(EchoGate(), system: [Float](repeating: 0, count: 64_000), mic: me.speech(seconds: 8))
        #expect(spans.isEmpty)
    }

    @Test
    func aShortEchoAfterTheDelayIsKnownIsMarkedWithoutWaiting() {
        var source = SignalSource(seed: 6)
        let gate = EchoGate()
        let first = source.speech(seconds: 6)
        _ = feed(gate, system: first, mic: delayed(first, by: 0.08, gain: 0.25))
        let quiet = [Float](repeating: 0, count: 32_000)
        // Windows still overlapping the earlier echo may report it; nothing starts in the silence.
        #expect(feed(gate, system: quiet, mic: quiet, from: 6).allSatisfy { $0.lowerBound < 6 })
        let burst = source.speech(seconds: 0.6) + [Float](repeating: 0, count: 11_200)
        let spans = feed(gate, system: burst, mic: delayed(burst, by: 0.08, gain: 0.25), from: 10)
        // The microphone hears the burst 80 ms later.
        #expect(covered(spans, 10.08...10.68) > 0.9)
    }
}

/// A small room: the direct sound after `delay`, then reflections whose energy
/// falls by 60 dB over `reverb` seconds. Deterministic.
private func roomEcho(_ signal: [Float], delay: Double, gain: Float, reverb: Double, rate: Double = 8_000) -> [Float] {
    var source = SignalSource(seed: 99)
    let length = Int(reverb * rate)
    var response = [Float](repeating: 0, count: Int(delay * rate) + length)
    response[Int(delay * rate)] = gain
    for index in 1..<length {
        let decay = Float(pow(10, -3 * Double(index) / Double(length)))
        response[Int(delay * rate) + index] = source.noise() * gain * 0.35 * decay
    }
    // Laptop speakers carry little bass: a first-order high-pass near 200 Hz.
    var highPassed = [Float](repeating: 0, count: signal.count)
    let alpha: Float = 0.86
    for index in 1..<signal.count {
        highPassed[index] = alpha * (highPassed[index - 1] + signal[index] - signal[index - 1])
    }
    // vDSP.convolve gives y[n] = Σ s[n + L - 1 - k] · h[k]; leading zeros make it causal.
    return vDSP.convolve([Float](repeating: 0, count: response.count - 1) + highPassed, withKernel: response)
        .prefix(signal.count).map { $0 }
}

/// The installed German `say` voice whose name is `name` or starts with "`name` (".
/// Voice names are localized ("Eddy", "Eddy (German
/// (Germany))"), and `say` silently falls back to the default voice for an unknown
/// name, so tests resolve by locale instead of passing a display name.
private func germanVoice(_ name: String) -> String? {
    let list = Process()
    let pipe = Pipe()
    list.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    list.arguments = ["-v", "?"]
    list.standardOutput = pipe
    list.standardError = FileHandle.nullDevice
    guard (try? list.run()) != nil else { return nil }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    list.waitUntilExit()
    for line in output.split(separator: "\n") {
        guard let match = line.firstMatch(of: /^(.+?)\s+([a-z]{2,3}_[A-Z0-9]{2,3})\s+#/),
              match.2 == "de_DE" else { continue }
        let voice = String(match.1)
        if voice == name || voice.hasPrefix(name + " (") { return voice }
    }
    return nil
}

/// Anchors `Bundle(for:)` to the test bundle that carries the speech fixtures.
private final class SpeechFixtures {}

/// Real human speech at 8 kHz, as the echo gate sees it: committed public-domain
/// LibriVox recordings (see Fixtures/Speech/README.md), so every Mac and CI image
/// measures the same samples.
private func recorded(_ name: String) throws -> [Float] {
    let url = try #require(Bundle(for: SpeechFixtures.self).url(forResource: name, withExtension: "wav"),
                           "speech fixture \(name).wav is missing from the test bundle")
    let file = try AVAudioFile(forReading: url)
    #expect(file.processingFormat.sampleRate == 8_000)
    #expect(file.processingFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)
    let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    try #require(samples.count > 8_000)
    return samples
}

@Suite("Meeting echo in a room")
struct RoomEchoTests {
    /// The others: a woman reading continuously for about 19 seconds.
    private static let others = "others-elli"
    /// Me: a man, two different sentences of about four and five seconds.
    private static let mineOver = "mine-karlsson-1"
    private static let mineAfter = "mine-karlsson-2"

    /// The echo of real speech through laptop speakers and a room must be found.
    @Test(arguments: [(0.03, Float(0.25), 0.4), (0.15, Float(0.12), 0.6), (0.25, Float(0.08), 0.3), (0.05, Float(0.03), 0.4), (0.05, Float(0.015), 0.4), (0.05, Float(0.01), 0.8)])
    func roomEchoOfRealSpeechIsFound(delay: Double, gain: Float, reverb: Double) throws {
        let system = try recorded(Self.others)
        var noise = SignalSource(seed: 11)
        let mic = zip(roomEcho(system, delay: delay, gain: gain, reverb: reverb), noise.speech(seconds: Double(system.count) / 8_000, level: 0.003))
            .map { $0 + $1 }
        let gate = EchoGate()
        let spans = feed(gate, system: system, mic: mic)
        let length = Double(system.count) / 8_000
        let share = covered(spans, 1...length)
        print("room echo delay \(delay) gain \(gain) reverb \(reverb): covered \(share), lag \(gate.lockedLag.map { String($0) } ?? "none")")
        #expect(share > 0.7)
    }

    /// Calibration: real speech of two different people never correlates like an
    /// echo. The bound is the gate's own score floor, from both sides; the
    /// recordings are fixed, so the measured scores are the same on every Mac.
    @Test
    func unrelatedRealSpeechStaysFarBelowEchoScores() throws {
        let others = try recorded(Self.others)
        let mine = try recorded(Self.mineOver) + recorded(Self.mineAfter)
        let length = min(others.count, mine.count)
        let unrelated = scores(EchoGate(), system: Array(others.prefix(length)), mic: Array(mine.prefix(length)))
        let echo = scores(EchoGate(), system: others, mic: roomEcho(others, delay: 0.05, gain: 0.03, reverb: 0.6))
        let sortedEcho = echo.sorted()
        print("calibration unrelated max \(unrelated.max() ?? 0), echo median \(sortedEcho[sortedEcho.count / 2]) min \(sortedEcho.first ?? 0)")
        let floor = EchoGate.Configuration().scoreFloor
        #expect((unrelated.max() ?? 0) < floor)
        #expect((sortedEcho.first ?? 0) > floor)
    }

    /// A quiet, reverberant echo is still found while I talk over it now and then.
    @Test
    func aQuietEchoIsFoundEvenWhileITalkOverIt() throws {
        let system = try recorded(Self.others)
        let mine = try recorded(Self.mineOver)
        var mic = roomEcho(system, delay: 0.05, gain: 0.02, reverb: 0.8)
        let from = 4 * 8_000
        for index in mine.indices where from + index < mic.count { mic[from + index] += mine[index] * 0.5 }
        let spans = feed(EchoGate(), system: system, mic: mic)
        let share = covered(spans, 1...(Double(system.count) / 8_000))
        print("double talk over quiet echo: covered \(share)")
        #expect(share > 0.7)
    }

    /// My own sentence while the others are silent must stay mine, even in the
    /// same room right after their echo.
    @Test
    func myOwnSpeechAfterTheirEchoStaysMine() throws {
        let system = try recorded(Self.others)
        let mine = try recorded(Self.mineAfter)
        let pause = [Float](repeating: 0, count: 8_000)
        let systemTrack = system + pause + [Float](repeating: 0, count: mine.count)
        let micTrack = roomEcho(system, delay: 0.03, gain: 0.25, reverb: 0.4) + pause + mine
        let spans = feed(EchoGate(), system: systemTrack, mic: micTrack)
        let mineStart = Double(system.count + pause.count) / 8_000 + 0.6
        let share = covered(spans, mineStart...(Double(systemTrack.count) / 8_000))
        print("own speech after echo: covered \(share)")
        #expect(share < 0.1)
    }
}

@Suite("Meeting audio sources")
struct MeetingAudioTests {
    @Test
    func deinterleavedStereoBecomesOneMonoTrack() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channels = try #require(buffer.floatChannelData)
        for (index, (left, right)) in [(Float(1), Float(0)), (0.5, 0.5), (-1, 1)].enumerated() {
            channels[0][index] = left
            channels[1][index] = right
        }
        let mono = MeetingAudioMixdown.mono(buffer.audioBufferList, frames: 3, format: format.streamDescription.pointee)
        #expect(mono == [0.5, 0.5, 0])
    }

    @Test
    func interleavedTapAudioBecomesOneMonoTrack() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let samples = try #require(buffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self))
        for (index, value) in [Float(0.2), 0.4, -0.6, -0.2].enumerated() { samples[index] = value }
        let mono = try #require(MeetingAudioMixdown.mono(buffer.audioBufferList, frames: 2, format: format.streamDescription.pointee))
        #expect(mono.map { ($0 * 10).rounded() / 10 } == [0.3, -0.4])
    }

    @Test
    func integerAudioIsRejectedInsteadOfMisread() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        #expect(MeetingAudioMixdown.mono(buffer.audioBufferList, frames: 4, format: format.streamDescription.pointee) == nil)
    }

    @Test
    func hostTimeConvertsToSeconds() {
        let second = MeetingHostClock.hostTicks(forSeconds: 1)
        #expect(abs(MeetingHostClock.seconds(second * 3) - 3) < 1e-6)
    }
}

private final class RecognizerFake: MeetingRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [(speaker: MeetingSpeaker, time: TimeInterval, frames: Int)] = []
    var appended: [(speaker: MeetingSpeaker, time: TimeInterval, frames: Int)] { lock.withLock { _appended } }
    var startedLocale: Locale?
    var finished = false
    var cancelled = false
    var startError: Error?
    var onResult: (@Sendable (MeetingRecognition) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var finalOnFinish: MeetingRecognition?

    func start(locale: Locale, onResult: @escaping @Sendable (MeetingRecognition) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws {
        if let startError { throw startError }
        startedLocale = locale
        self.onResult = onResult
        self.onFailure = onFailure
    }
    func append(_ chunk: MeetingAudioChunk, at time: TimeInterval, speaker: MeetingSpeaker) {
        lock.withLock { _appended.append((speaker, time, chunk.samples.count)) }
    }
    func finish() async {
        finished = true
        if let finalOnFinish { onResult?(finalOnFinish) }
    }
    func cancel() async { cancelled = true }
}

@Suite("Meeting audio routing")
struct MeetingRouterTests {
    private let start: UInt64 = 1_000_000_000

    private func chunk(_ samples: [Float], rate: Double = 48_000, after seconds: TimeInterval) -> MeetingAudioChunk {
        MeetingAudioChunk(samples: samples, sampleRate: rate, hostTime: start + MeetingHostClock.hostTicks(forSeconds: seconds))
    }

    @Test
    func chunksLandOnTheMeetingTimelineAndReachTheRecognizer() {
        let recognizer = RecognizerFake()
        let router = MeetingAudioRouter(startHostTime: start, recognizer: recognizer, onEcho: { _ in })
        router.handle(chunk([Float](repeating: 0.1, count: 4_800), after: 1), from: .me)
        router.handle(chunk([Float](repeating: 0.1, count: 4_800), after: 1.11), from: .me)
        router.handle(chunk([Float](repeating: 0, count: 480), after: 0.5), from: .others)
        let times = recognizer.appended.map { ($0.speaker, ($0.time * 100).rounded() / 100) }
        #expect(times.map(\.0) == [.me, .me, .others])
        #expect(times.map(\.1) == [1, 1.1, 0.5])
    }

    @Test
    func echoAtTheDevicesSampleRateIsReportedAfterResampling() async {
        var source = SignalSource(seed: 7)
        let system = source.speech(seconds: 6, rate: 48_000)
        let mic = delayed(system, by: 0.1, gain: 0.3, rate: 48_000)
        let found = Spans()
        let router = MeetingAudioRouter(startHostTime: start, recognizer: RecognizerFake(), onEcho: { found.add($0) })
        for offset in stride(from: 0, to: system.count, by: 4_800) {
            let time = Double(offset) / 48_000
            router.handle(chunk(Array(system[offset..<offset + 4_800]), after: time), from: .others)
            router.handle(chunk(Array(mic[offset..<offset + 4_800]), after: time), from: .me)
        }
        router.drain()
        #expect(!found.all.isEmpty)
    }

    @Test
    func stoppedRoutingDropsLateAudio() {
        let recognizer = RecognizerFake()
        let router = MeetingAudioRouter(startHostTime: start, recognizer: recognizer, onEcho: { _ in })
        router.stop()
        router.handle(chunk([0.2, 0.2], after: 1), from: .me)
        #expect(recognizer.appended.isEmpty)
    }

    @Test
    func silenceAndSoundAreTrackedPerTrack() {
        let router = MeetingAudioRouter(startHostTime: start, recognizer: RecognizerFake(), onEcho: { _ in })
        router.handle(chunk([Float](repeating: 0, count: 4_800), after: 2), from: .others)
        router.handle(chunk([Float](repeating: 0.05, count: 4_800), after: 3), from: .me)
        let state = router.state
        #expect(state.lastSignal[.others] == nil)
        #expect(state.lastSound[.me] != nil)
        #expect(state.level[.me] ?? 0 > 0.04)
    }
}

private final class Spans: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [ClosedRange<TimeInterval>] = []
    func add(_ more: [ClosedRange<TimeInterval>]) { lock.withLock { spans += more } }
    var all: [ClosedRange<TimeInterval>] { lock.withLock { spans } }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MeetingRecognition] = []
    func add(_ item: MeetingRecognition) { lock.withLock { items.append(item) } }
    var all: [MeetingRecognition] { lock.withLock { items } }
}

/// Runs Apple's on-device recogniser for real when this Mac has it and German installed.
@Suite("Meeting recognition on this Mac", .serialized)
struct AppleMeetingRecognizerTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func germanSpeechLandsOnTheMeetingTimeline() async throws {
        guard #available(macOS 26, *) else { return }
        let provider = SystemMeetingRecognizerProvider()
        guard case let .available(locale) = await provider.availability(for: .german) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        guard let anna = germanVoice("Anna") else { return }
        say.arguments = ["-v", anna, "-o", url.path, "Guten Morgen zusammen. Kurzer Stand zum Projekt."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { return }
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate

        let recognizer = try #require(provider.makeRecognizer())
        let results = Results()
        try await recognizer.start(locale: locale, onResult: { results.add($0) }, onFailure: { _ in })
        let step = Int(rate / 10)
        for offset in stride(from: 0, to: samples.count, by: step) {
            let piece = Array(samples[offset..<min(offset + step, samples.count)])
            recognizer.append(MeetingAudioChunk(samples: piece, sampleRate: rate, hostTime: 0),
                              at: 100 + Double(offset) / rate, speaker: .others)
        }
        await recognizer.finish()
        let finals = results.all.filter(\.isFinal)
        let text = finals.map(\.text).joined(separator: " ")
        #expect(text.localizedCaseInsensitiveContains("Morgen"))
        #expect(finals.allSatisfy { $0.speaker == .others && $0.start >= 99.9 })
    }

    /// Real recogniser, real router and echo gate: the others' sentence reaches the
    /// microphone as a quiet echo, then I say something of my own.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func speakerEchoDisappearsFromMeWhileMyOwnSentenceStays() async throws {
        guard #available(macOS 26, *) else { return }
        let provider = SystemMeetingRecognizerProvider()
        guard case let .available(locale) = await provider.availability(for: .german) else { return }
        let others = try #require(try speech("Wir haben in dieser Woche die neue Funktion fertiggestellt und alle Tests laufen grün.", voice: "Anna"))
        let mine = try #require(try speech("Danke, dann plane ich den Prototypen für Freitag.", voice: "Eddy")
            ?? speech("Danke, dann plane ich den Prototypen für Freitag.", voice: "Anna"))
        let rate = 22_050.0
        let gap = [Float](repeating: 0, count: Int(rate))
        let systemTrack = others + gap + [Float](repeating: 0, count: mine.count)
        let echo = delayed(others, by: 0.09, gain: 0.3, rate: rate)
        let micTrack = echo + gap + mine

        let recognizer = try #require(provider.makeRecognizer())
        let results = Results()
        let spans = Spans()
        try await recognizer.start(locale: locale, onResult: { results.add($0) }, onFailure: { _ in })
        let start: UInt64 = 1_000_000_000
        let router = MeetingAudioRouter(startHostTime: start, recognizer: recognizer, onEcho: { spans.add($0) })
        let step = Int(rate / 10)
        for offset in stride(from: 0, to: systemTrack.count, by: step) {
            let end = min(offset + step, systemTrack.count)
            let host = start + MeetingHostClock.hostTicks(forSeconds: Double(offset) / rate)
            router.handle(MeetingAudioChunk(samples: Array(systemTrack[offset..<end]), sampleRate: rate, hostTime: host), from: .others)
            router.handle(MeetingAudioChunk(samples: Array(micTrack[offset..<end]), sampleRate: rate, hostTime: host), from: .me)
        }
        router.stop()
        await recognizer.finish()
        router.drain()

        var transcript = MeetingTranscript()
        results.all.forEach { transcript.apply($0) }
        spans.all.forEach { transcript.addEcho($0) }
        let me = transcript.entries.filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
        let them = transcript.entries.filter { $0.speaker == .others }.map(\.text).joined(separator: " ")
        // Recognition of the synthetic second voice varies; its first and last words are stable.
        #expect(them.localizedCaseInsensitiveContains("Tests"))
        #expect(me.localizedCaseInsensitiveContains("Danke"))
        #expect(me.localizedCaseInsensitiveContains("Freitag"))
        #expect(!me.localizedCaseInsensitiveContains("Woche"))
        #expect(!me.localizedCaseInsensitiveContains("Tests"))
    }

    /// End to end except the microphone hardware and the voice model: real speech of
    /// three synthetic voices on the others' track runs through the controller, the
    /// real recogniser, router and voice tracker. A diarizer that knows who spoke when
    /// stands in for the model, reporting live as audio arrives. Then a voice is named
    /// and the transcript is saved as PDF and read back.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func threeVoicesReachThePDFWithTheirNames() async throws {
        guard #available(macOS 26, *) else { return }
        let provider = SystemMeetingRecognizerProvider()
        guard case .available = await provider.availability(for: .german) else { return }
        let lines = [
            ("Anna", "Guten Morgen zusammen, ich fange mit dem Stand zum Projekt an."),
            ("Grandpa", "Danke. Haben wir das Budget für die neuen Server schon freigegeben?"),
            ("Eddy", "Dann schicke ich die Bestellung heute noch raus."),
        ]
        let rate = 22_050.0
        var track: [Float] = []
        var truth: [MeetingVoiceSpan] = []
        for (index, (voice, text)) in lines.enumerated() {
            guard let samples = try speech(text, voice: voice) else { return }
            let start = Double(track.count) / rate
            track += samples
            truth.append(MeetingVoiceSpan(voice: (index + 1) * 10, start: start, end: Double(track.count) / rate))
            track += [Float](repeating: 0, count: Int(rate * 0.8))
        }
        let microphone = SourceFake(), system = SourceFake(), clock = HostClockFake()
        let saved = SavedFiles()
        let diarizer = TruthDiarizer(truth)
        let controller = MeetingController(
            provider: provider, makeMicrophone: { microphone }, makeSystemAudio: { system },
            makeVoiceDiarizer: { diarizer }, language: { .german }, hostClock: { clock.ticks },
            pasteboard: NSPasteboard.withUniqueName(), notifications: NotificationCenter(),
            save: { export, name in saved.write(export, name) }, presentsWindow: false)
        await controller.open()
        controller.confirmConsent()
        await controller.waitUntilSettled()
        #expect(controller.phase == .live)
        #expect(controller.tellsVoicesApart)
        let start = clock.ticks
        let step = Int(rate / 10)
        for offset in stride(from: 0, to: track.count, by: step) {
            let end = min(offset + step, track.count)
            let host = start + MeetingHostClock.hostTicks(forSeconds: Double(offset) / rate)
            system.deliver?(MeetingAudioChunk(samples: Array(track[offset..<end]), sampleRate: rate, hostTime: host))
            microphone.deliver?(MeetingAudioChunk(samples: [Float](repeating: 0, count: end - offset), sampleRate: rate, hostTime: host))
        }
        controller.stop()
        await controller.waitUntilSettled()
        #expect(controller.phase == .finished)

        let entries = controller.transcript.entries
        #expect(entries.map(\.voice) == [10, 20, 30])
        #expect(entries.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(entries[0].text.localizedCaseInsensitiveContains("Morgen"))
        // The synthetic second voice is recognised loosely; its first word is stable.
        #expect(entries[1].text.localizedCaseInsensitiveContains("Danke"))
        #expect(entries[2].text.localizedCaseInsensitiveContains("Bestellung"))

        controller.renameVoice(20, to: "Ben")
        #expect(controller.save())
        let url = try #require(saved.urls.first)
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try #require(PDFDocument(url: url))
        let text = try #require(pdf.string)
        for expected in ["Speaker 1", "Ben", "Speaker 3", "Morgen", "Danke", "Bestellung"] {
            #expect(text.contains(expected), "PDF misses \(expected)")
        }
        #expect(text.range(of: "Speaker 1")!.lowerBound < text.range(of: "Ben")!.lowerBound)
        #expect(!text.contains("Speaker 2"))
    }

    private func speech(_ text: String, voice: String) throws -> [Float]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let voice = germanVoice(voice) else { return nil }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "--file-format=caff", "--data-format=LEF32@22050", "-o", url.path, text]
        say.standardError = FileHandle.nullDevice
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { return nil }
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 22_050,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

@MainActor
private final class SourceFake: MeetingAudioSource {
    var deliver: (@Sendable (MeetingAudioChunk) -> Void)?
    var starts = 0
    var stops = 0
    var failure: Error?
    var onInterruption: ((String) -> Void)?
    func start(deliver: @escaping @Sendable (MeetingAudioChunk) -> Void) throws {
        if let failure { throw failure }
        starts += 1
        self.deliver = deliver
    }
    func stop() { stops += 1; deliver = nil }
}

@MainActor
private final class ProviderFake: MeetingRecognizerProviding {
    var availability: MeetingAvailability = .available(Locale(identifier: "de-DE"))
    var recognizer = RecognizerFake()
    var requestedLanguage: DictationLanguage?
    func availability(for language: DictationLanguage) async -> MeetingAvailability {
        requestedLanguage = language
        return availability
    }
    func makeRecognizer() -> (any MeetingRecognizing)? { recognizer }
}

private final class HostClockFake: @unchecked Sendable {
    var seconds: TimeInterval = 10
    var ticks: UInt64 { MeetingHostClock.hostTicks(forSeconds: seconds) }
}

private final class MeetingSoundsFake: InterfaceSoundPlaying {
    var cues: [InterfaceCue] = []
    func play(_ cue: InterfaceCue) { cues.append(cue) }
    func stop() {}
}

@MainActor
private struct MeetingFixture {
    let controller: MeetingController
    let provider = ProviderFake()
    let microphone = SourceFake()
    let system = SourceFake()
    let clock = HostClockFake()
    let sounds = MeetingSoundsFake()
    let pasteboard = NSPasteboard.withUniqueName()
    let notifications = NotificationCenter()
    let confirmations = Confirmations()
    let access = MicrophoneAccessBox()
    var saved: [String] { savedBox.items }
    let savedBox = SavedBox()

    init(systemAvailable: Bool = true, diarizer: DiarizerFake? = nil) {
        let provider = provider, microphone = microphone, system = system, clock = clock, savedBox = savedBox
        let confirmations = confirmations, access = access
        controller = MeetingController(
            provider: provider,
            makeMicrophone: { microphone },
            makeSystemAudio: { systemAvailable ? system : nil },
            makeVoiceDiarizer: { diarizer },
            language: { .german },
            interfaceSounds: sounds,
            hostClock: { clock.ticks },
            pasteboard: pasteboard,
            notifications: notifications,
            save: { export, name in savedBox.items.append(export.markdown); savedBox.names.append(name); return true },
            confirmLosingUnsaved: { reason in confirmations.reasons.append(reason); return confirmations.answer },
            microphoneAccess: { access.requests += 1; return access.granted },
            presentsWindow: false)
    }

    func start() async {
        await controller.open()
        controller.confirmConsent()
        await controller.waitUntilSettled()
    }

    func hear(_ recognition: MeetingRecognition) async {
        provider.recognizer.onResult?(recognition)
        await controller.waitUntilSettled()
    }
}

@MainActor
private final class SavedBox {
    var items: [String] = []
    var names: [String] = []
}

@MainActor
private final class MicrophoneAccessBox {
    var granted = true
    var requests = 0
}

@MainActor
private final class Confirmations {
    var answer = false
    var reasons: [MeetingController.LossReason] = []
}

@Suite("Meeting transcript lifecycle", .serialized)
@MainActor
struct MeetingControllerTests {
    @Test
    func nothingRecordsBeforeConsentIsConfirmed() async {
        let fixture = MeetingFixture()
        await fixture.controller.open()
        #expect(fixture.controller.phase == .consent)
        #expect(fixture.microphone.starts == 0)
        #expect(fixture.system.starts == 0)
        #expect(fixture.provider.recognizer.startedLocale == nil)
        fixture.controller.discard()
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.microphone.starts == 0)
    }

    @Test
    func unavailableRecognitionSaysWhyAndOffersNoStart() async {
        let fixture = MeetingFixture()
        fixture.provider.availability = .languageMissing("Deutsch")
        await fixture.controller.open()
        guard case .unavailable = fixture.controller.phase else {
            Issue.record("expected unavailable, got \(fixture.controller.phase)")
            return
        }
        fixture.controller.confirmConsent()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.microphone.starts == 0)
    }

    @Test
    func consentStartsRecognitionThenBothSourcesWithTheDictationLanguage() async {
        let fixture = MeetingFixture()
        await fixture.start()
        #expect(fixture.controller.phase == .live)
        #expect(fixture.provider.requestedLanguage == .german)
        #expect(fixture.provider.recognizer.startedLocale?.identifier == "de-DE")
        #expect(fixture.microphone.starts == 1)
        #expect(fixture.system.starts == 1)
        #expect(fixture.sounds.cues == [.listening])
        #expect(fixture.controller.isRecording)
    }

    @Test
    func audioFromBothSourcesReachesTheRecognizer() async {
        let fixture = MeetingFixture()
        await fixture.start()
        fixture.microphone.deliver?(MeetingAudioChunk(samples: [0.1, 0.1], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.system.deliver?(MeetingAudioChunk(samples: [0.1, 0.1], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        #expect(fixture.provider.recognizer.appended.map(\.speaker) == [.me, .others])
    }

    @Test
    func resultsFillTheTranscriptAndStopKeepsIt() async {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.others, 1, 2, "Guten Morgen."))
        fixture.provider.recognizer.finalOnFinish = heard(.me, 3, 4, "Hallo.")
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.phase == .finished)
        #expect(fixture.microphone.stops >= 1)
        #expect(fixture.system.stops >= 1)
        #expect(fixture.provider.recognizer.finished)
        #expect(fixture.controller.transcript.entries.map(\.text) == ["Guten Morgen.", "Hallo."])
        #expect(fixture.sounds.cues == [.listening, .captured])
    }

    @Test
    func discardedTranscriptsIgnoreLateResults() async {
        let fixture = MeetingFixture()
        await fixture.start()
        fixture.controller.discard()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.provider.recognizer.cancelled)
        await fixture.hear(heard(.others, 1, 2, "Zu spaet."))
        #expect(fixture.controller.transcript.isEmpty)
        #expect(fixture.controller.phase == .idle)
    }

    @Test
    func copyAndSaveHappenOnlyOnRequest() async {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.others, 1, 2, "Guten Morgen."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.pasteboard.string(forType: .string) == nil)
        #expect(fixture.saved.isEmpty)
        fixture.controller.copy()
        #expect(fixture.pasteboard.string(forType: .string)?.contains("Guten Morgen.") == true)
        fixture.controller.save()
        #expect(fixture.saved.count == 1)
        #expect(fixture.controller.hasUnsavedText == false)
    }

    @Test
    func saveHandsTheVisibleTranscriptAndADatedNameWithoutExtension() async throws {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.others, 1, 2, "Guten Morgen."))
        fixture.clock.seconds += 42
        fixture.controller.tick()
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.export.duration == 42)
        #expect(fixture.controller.export.turns.map(\.text) == ["Guten Morgen."])
        fixture.controller.save()
        let name = try #require(fixture.savedBox.names.first)
        #expect(name.hasPrefix("Meeting transcript "))
        #expect(!name.contains("."))
    }

    @Test
    func aNewTranscriptNeverSilentlyReplacesAnUnsavedOne() async {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.others, 1, 2, "Wichtig."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        await fixture.controller.startNew()
        #expect(fixture.controller.phase == .finished)
        #expect(!fixture.controller.transcript.isEmpty)
    }

    @Test
    func discardingUnsavedTextAsksFirstAndSavedTextGoesAtOnce() async {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.others, 1, 2, "Wichtig."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        fixture.controller.requestDiscard()
        #expect(fixture.confirmations.reasons == [.discard])
        #expect(fixture.controller.phase == .finished)
        fixture.confirmations.answer = true
        fixture.controller.requestDiscard()
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.transcript.isEmpty)

        await fixture.start()
        await fixture.hear(heard(.others, 1, 2, "Auch wichtig."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        fixture.controller.copy()
        fixture.controller.requestDiscard()
        #expect(fixture.confirmations.reasons == [.discard, .discard])
        #expect(fixture.controller.phase == .idle)
    }

    @Test
    func sleepEndsTheRecordingButKeepsTheTranscript() async {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.me, 1, 2, "Bis gleich."))
        fixture.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.phase == .finished)
        #expect(fixture.controller.transcript.entries.map(\.text) == ["Bis gleich."])
    }

    @Test
    func theTimeLimitWarnsAndThenStops() async {
        let fixture = MeetingFixture()
        await fixture.start()
        // Keep talking, so only the time limit applies.
        let talk = { fixture.microphone.deliver?(MeetingAudioChunk(samples: [Float](repeating: 0.1, count: 160), sampleRate: 16_000, hostTime: fixture.clock.ticks)) }
        fixture.clock.seconds += 2 * 3600 - 299
        talk()
        fixture.controller.tick()
        #expect(fixture.controller.notice != nil)
        #expect(fixture.controller.phase == .live)
        fixture.clock.seconds += 300
        talk()
        fixture.controller.tick()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.phase == .finished)
    }

    @Test
    func tenSilentMinutesStopTheRecording() async {
        let fixture = MeetingFixture()
        await fixture.start()
        fixture.clock.seconds += 599
        fixture.controller.tick()
        #expect(fixture.controller.phase == .live)
        fixture.clock.seconds += 2
        fixture.controller.tick()
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.phase == .finished)
    }

    @Test
    func silentSystemAudioPointsToThePermission() async {
        let fixture = MeetingFixture()
        await fixture.start()
        fixture.clock.seconds += 21
        fixture.system.deliver?(MeetingAudioChunk(samples: [0, 0], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.controller.tick()
        #expect(fixture.controller.systemAudioMissing)
        fixture.system.deliver?(MeetingAudioChunk(samples: [0.2, 0.1], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.controller.tick()
        #expect(!fixture.controller.systemAudioMissing)
    }

    @Test
    func thePermissionHintEndsWithTheRecording() async {
        let fixture = MeetingFixture()
        await fixture.start()
        fixture.clock.seconds += 21
        fixture.microphone.deliver?(MeetingAudioChunk(samples: [0.1, 0.1], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.controller.tick()
        #expect(fixture.controller.systemAudioMissing)
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        #expect(!fixture.controller.systemAudioMissing)
    }

    @Test
    func aDeniedMicrophoneNeverGoesLive() async {
        let fixture = MeetingFixture()
        fixture.access.granted = false
        await fixture.start()
        #expect(fixture.access.requests == 1)
        #expect(fixture.controller.phase == .consent)
        #expect(!fixture.controller.isRecording)
        #expect(fixture.microphone.starts == 0)
        #expect(fixture.system.starts == 0)
        #expect(fixture.provider.recognizer.startedLocale == nil)
        #expect(fixture.controller.notice != nil)
    }

    @Test
    func aSilentMicrophonePointsToItsInput() async {
        let fixture = MeetingFixture()
        await fixture.start()
        fixture.clock.seconds += 21
        fixture.system.deliver?(MeetingAudioChunk(samples: [0.2, 0.1], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.microphone.deliver?(MeetingAudioChunk(samples: [0, 0], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.controller.tick()
        #expect(fixture.controller.microphoneMissing)
        #expect(!fixture.controller.systemAudioMissing)
        fixture.microphone.deliver?(MeetingAudioChunk(samples: [0.2, 0.1], sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.controller.tick()
        #expect(!fixture.controller.microphoneMissing)
    }

    @Test
    func aMicrophoneThatStopsByItselfLeavesOthersRunningWithANotice() async throws {
        let fixture = MeetingFixture()
        await fixture.start()
        let interruption = try #require(fixture.microphone.onInterruption)
        interruption("The input device changed.")
        #expect(fixture.controller.phase == .live)
        #expect(fixture.controller.notice?.contains("The input device changed.") == true)
        #expect(fixture.microphone.stops >= 1)
        fixture.clock.seconds += 21
        fixture.controller.tick()
        #expect(!fixture.controller.microphoneMissing, "The notice already says why; no second hint.")
    }

    @Test
    func aMicrophoneThatStopsWithoutSystemAudioEndsTheRecording() async throws {
        let fixture = MeetingFixture(systemAvailable: false)
        await fixture.start()
        let interruption = try #require(fixture.microphone.onInterruption)
        interruption("The input device changed.")
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.phase == .finished)
        #expect(fixture.controller.notice?.contains("The input device changed.") == true)
    }

    @Test
    func entriesFollowEveryChangeOfTheTranscript() {
        var transcript = MeetingTranscript()
        #expect(transcript.isEmpty)
        transcript.apply(heard(.me, 1, 2, "Eins zwei drei vier"))
        #expect(transcript.entries.map(\.text) == ["Eins zwei drei vier"])
        transcript.addEcho(1...2)
        #expect(transcript.isEmpty, "The cached entries are refreshed by the echo, too.")
    }

    @Test
    func withoutSystemAudioTheMicrophoneStillTranscribesWithANotice() async {
        let fixture = MeetingFixture(systemAvailable: false)
        await fixture.start()
        #expect(fixture.controller.phase == .live)
        #expect(fixture.microphone.starts == 1)
        #expect(fixture.controller.notice != nil)
    }

    @Test
    func aFailingMicrophoneEndsTheStartCleanly() async {
        let fixture = MeetingFixture()
        fixture.microphone.failure = MeetingError("Mic busy")
        await fixture.start()
        #expect(fixture.controller.phase == .consent)
        #expect(fixture.controller.notice == "Mic busy")
        #expect(fixture.provider.recognizer.cancelled)
        #expect(fixture.system.starts == 0 || fixture.system.stops >= 1)
    }
}

@Suite("Meeting voices in the transcript", .serialized)
@MainActor
struct MeetingVoiceControllerTests {
    private func othersSecond(_ fixture: MeetingFixture) {
        fixture.system.deliver?(MeetingAudioChunk(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 8_000,
                                                  hostTime: fixture.clock.ticks))
    }

    @Test
    func withoutAVoiceModelTheOthersStayOneSpeaker() async {
        let fixture = MeetingFixture()
        await fixture.start()
        #expect(!fixture.controller.tellsVoicesApart)
        othersSecond(fixture)
        await fixture.hear(heard(.others, 0.1, 0.9, "Hallo."))
        #expect(fixture.controller.transcript.entries.map(\.label) == ["Others"])
    }

    @Test
    func theOthersAudioReachesTheDiarizerAndNamesTheirTurns() async {
        let diarizer = DiarizerFake()
        let fixture = MeetingFixture(diarizer: diarizer)
        await fixture.start()
        #expect(fixture.controller.tellsVoicesApart)
        fixture.microphone.deliver?(MeetingAudioChunk(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 8_000,
                                                      hostTime: fixture.clock.ticks))
        othersSecond(fixture)
        await fixture.hear(heard(.others, 0.1, 0.9, "Hallo."))
        await fixture.hear(heard(.me, 1.2, 1.8, "Hi."))
        #expect(diarizer.fed == 1)
        #expect(fixture.controller.transcript.entries.map(\.label) == ["Speaker 1", "Me"])
    }

    @Test
    func stopFlushesTheLastVoicesAndDiscardIgnoresLateOnes() async {
        let diarizer = DiarizerFake()
        diarizer.voice = 4
        // The look-ahead flush reports a voice after the last chunk.
        diarizer.finalSpan = MeetingVoiceSpan(voice: 6, start: 1, end: 2)
        let fixture = MeetingFixture(diarizer: diarizer)
        await fixture.start()
        othersSecond(fixture)
        fixture.provider.recognizer.finalOnFinish = heard(.others, 1.1, 1.9, "Zum Schluss.")
        await fixture.hear(heard(.others, 0.0, 0.4, "Anfang."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        #expect(diarizer.finished)
        #expect(fixture.controller.transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2"])

        let late = DiarizerFake()
        let discarded = MeetingFixture(diarizer: late)
        await discarded.start()
        othersSecond(discarded)
        discarded.controller.discard()
        await discarded.controller.waitUntilSettled()
        #expect(discarded.controller.transcript.voiceSpans.isEmpty)
        #expect(!discarded.controller.tellsVoicesApart)
    }

    @Test
    func namesAndMergesReachTheExportAndCountAsUnsaved() async {
        let diarizer = DiarizerFake()
        let fixture = MeetingFixture(diarizer: diarizer)
        await fixture.start()
        othersSecond(fixture)
        await fixture.controller.waitUntilSettled()
        diarizer.voice = 1
        othersSecond(fixture)
        await fixture.hear(heard(.others, 0.1, 0.9, "Eins."))
        await fixture.hear(heard(.others, 1.1, 1.9, "Zwei."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        fixture.controller.copy()
        #expect(!fixture.controller.hasUnsavedText)
        fixture.controller.renameVoice(0, to: "Anna")
        #expect(fixture.controller.hasUnsavedText)
        #expect(fixture.controller.export.turns.map(\.speaker) == ["Anna", "Speaker 2"])
        fixture.controller.mergeVoice(1, into: 0)
        #expect(fixture.controller.export.turns.map(\.text) == ["Eins. Zwei."])
        #expect(fixture.controller.transcript.voices.map(\.label) == ["Anna"])
    }

    @Test
    func aMovedTurnReachesTheExportCountsAsUnsavedAndEndsWithTheTranscript() async throws {
        let diarizer = DiarizerFake()
        let fixture = MeetingFixture(diarizer: diarizer)
        await fixture.start()
        othersSecond(fixture)
        await fixture.hear(heard(.others, 0.1, 0.9, "Eins."))
        await fixture.hear(heard(.me, 1.1, 1.9, "Ja."))
        await fixture.controller.waitUntilSettled()
        othersSecond(fixture)
        await fixture.hear(heard(.others, 2.1, 2.9, "Zwei."))
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        // The model heard one voice; the second turn of the others was someone else.
        #expect(fixture.controller.export.turns.map(\.speaker) == ["Speaker 1", "Me", "Speaker 1"])
        fixture.controller.copy()
        let turn = try #require(fixture.controller.transcript.entries.last)
        fixture.controller.reassignTurnToNewPerson(turn)
        #expect(fixture.controller.hasUnsavedText)
        #expect(fixture.controller.export.turns.map(\.speaker) == ["Speaker 1", "Me", "Speaker 2"])
        fixture.controller.copy()
        fixture.controller.reassignTurn(try #require(fixture.controller.transcript.entries.last), to: 0)
        #expect(fixture.controller.hasUnsavedText)
        #expect(fixture.controller.export.turns.map(\.speaker) == ["Speaker 1", "Me", "Speaker 1"])
        // Corrections live only with this transcript.
        fixture.confirmations.answer = true
        await fixture.controller.startNew()
        #expect(fixture.controller.transcript == MeetingTranscript())
    }

    @Test
    func theFirstVoicesBringANoteThatTheyMayBeMixedUp() async {
        let diarizer = DiarizerFake()
        let fixture = MeetingFixture(diarizer: diarizer)
        await fixture.start()
        #expect(fixture.controller.voicesNote == nil)
        await fixture.hear(heard(.me, 0.1, 0.9, "Hallo."))
        #expect(fixture.controller.voicesNote == nil)
        othersSecond(fixture)
        await fixture.hear(heard(.others, 1.1, 1.9, "Hi."))
        let note = "Voices are told apart automatically and may be mixed up. Click a name to correct it."
        #expect(fixture.controller.voicesNote == note)
        #expect(fixture.controller.footerNote == note)
        // A warning is more urgent and takes the footer; the note stays for later.
        fixture.controller.stop("The transcript stopped after 2 hours.")
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.footerNote == "The transcript stopped after 2 hours.")
        #expect(fixture.controller.voicesNote == note)
        fixture.confirmations.answer = true
        await fixture.controller.startNew()
        #expect(fixture.controller.voicesNote == nil)
    }

    @Test
    func withoutAVoiceModelTheWindowSaysOnceThatVoicesAreNotToldApart() async {
        let fixture = MeetingFixture()
        await fixture.start()
        await fixture.hear(heard(.me, 0.1, 0.9, "Hallo."))
        #expect(fixture.controller.voicesNote == nil)
        await fixture.hear(heard(.others, 1.1, 1.9, "Hi."))
        #expect(fixture.controller.voicesNote == "The others' voices are not told apart in this transcript.")
        #expect(fixture.controller.notice == nil)
    }

    @Test
    func aFailingDiarizerLeavesTheTranscriptRunning() async {
        let diarizer = DiarizerFake()
        diarizer.failure = MeetingError("model gone")
        let fixture = MeetingFixture(diarizer: diarizer)
        await fixture.start()
        othersSecond(fixture)
        await fixture.controller.waitUntilSettled()
        #expect(fixture.controller.phase == .live)
        #expect(!fixture.controller.tellsVoicesApart)
        #expect(fixture.controller.notice?.contains("model gone") == true)
        await fixture.hear(heard(.others, 0.1, 0.9, "Weiter."))
        #expect(fixture.controller.transcript.entries.map(\.label) == ["Others"])
        // The failure notice already says it; no second note.
        #expect(fixture.controller.voicesNote == nil)
        #expect(fixture.controller.footerNote == fixture.controller.notice)
    }
}

private final class MeetingHotkeyFake: HotkeyManaging {
    var onPress: (() -> Void)?
    func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistration { .registered }
    func unregister() {}
}

@Suite("Meeting transcript in the app", .serialized)
@MainActor
struct MeetingAppTests {
    @Test
    func aRunningTranscriptShowsItsOwnMenuBarShapeAndHoldsUpdates() async {
        let fixture = MeetingFixture()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: MeetingHotkeyFake(),
                             meeting: fixture.controller)
        #expect(model.menuBarIndicator == .idle)
        #expect(model.canChangeShortcut)
        await fixture.start()
        #expect(model.menuBarIndicator == .recording)
        #expect(model.isBusyForUpdates)
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        #expect(model.menuBarIndicator == .idle)
        #expect(!model.isBusyForUpdates)
    }

    @Test
    func readingAndDictationLeaveARunningTranscriptAlone() async {
        let fixture = MeetingFixture()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: MeetingHotkeyFake(),
                             meeting: fixture.controller)
        await fixture.start()
        model.enqueueStopRequest()
        await model.waitForInteractionToSettle()
        #expect(fixture.controller.phase == .live)
        #expect(fixture.microphone.stops == 0)
    }
}

/// Opt-in design review: `TEST_RUNNER_OSR_MEETING_PREVIEW_DIR=/path xcodebuild …
/// -only-testing:OpenScreenReaderAppTests/MeetingPreviewTests test` renders the
/// transcript window in each state to PNGs. Nothing records; sources are fakes.
@Suite("Meeting window preview", .serialized)
@MainActor
struct MeetingPreviewTests {
    @Test
    func exportMeetingWindowPreview() async throws {
        guard let path = ProcessInfo.processInfo.environment["OSR_MEETING_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let diarizer = DiarizerFake()
        let fixture = MeetingFixture(diarizer: diarizer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MeetingView(controller: fixture.controller)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 560)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func capture(_ name: String) async throws {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(700))
                host.layoutSubtreeIfNeeded()
                host.display()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        fixture.provider.availability = .languageMissing("Deutsch")
        await fixture.controller.open()
        try await capture("1-unavailable")
        fixture.controller.discard()
        fixture.provider.availability = .available(Locale(identifier: "de-DE"))
        await fixture.controller.open()
        try await capture("2-consent")
        fixture.controller.confirmConsent()
        await fixture.controller.waitUntilSettled()
        // Two voices among the others, the first one second by second until 5 s.
        let voiceSecond = MeetingAudioChunk(samples: [Float](repeating: 0.05, count: 8_000), sampleRate: 8_000,
                                            hostTime: fixture.clock.ticks)
        for second in 0..<11 {
            diarizer.voice = second < 5 ? 0 : 1
            fixture.system.deliver?(voiceSecond)
            await fixture.controller.waitUntilSettled()
        }
        await fixture.hear(heard(.others, 1, 4, "Guten Morgen zusammen, kurzer Stand zum Projekt."))
        await fixture.hear(heard(.me, 5, 7, "Die Tests laufen alle grün."))
        await fixture.hear(heard(.others, 8, 10, "Dann plane ich den ersten Prototypen", final: false))
        fixture.clock.seconds += 75
        fixture.microphone.deliver?(MeetingAudioChunk(samples: [Float](repeating: 0.08, count: 1_600), sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.system.deliver?(MeetingAudioChunk(samples: [Float](repeating: 0, count: 1_600), sampleRate: 16_000, hostTime: fixture.clock.ticks))
        fixture.controller.tick()
        try await capture("3-live")
        fixture.provider.recognizer.finalOnFinish = heard(.others, 8, 10.5, "Dann plane ich den ersten Prototypen für Freitag.")
        fixture.controller.stop()
        await fixture.controller.waitUntilSettled()
        try await capture("4-finished")
        fixture.controller.renameVoice(0, to: "Anna")
        try await capture("4b-named")
        // The last turn was someone the model heard as Anna's second voice.
        if let last = fixture.controller.transcript.entries.last {
            fixture.controller.reassignTurnToNewPerson(last)
        }
        try await capture("4c-corrected")
        for format in MeetingExportFormat.allCases {
            try fixture.controller.export.data(as: format)
                .write(to: directory.appendingPathComponent(format.fileName(base: "5-export")))
        }
        // The four menu bar states side by side, as template images on light and dark bars.
        for (suffix, background) in [("light", NSColor(white: 0.93, alpha: 1)), ("dark", NSColor(white: 0.16, alpha: 1))] {
            let strip = NSImage(size: NSSize(width: 4 * 30 + 10, height: 30), flipped: false) { rect in
                background.setFill()
                rect.fill()
                for (index, indicator) in [AppModel.MenuBarIndicator.idle, .reading, .attention, .recording].enumerated() {
                    let icon = MenuBarIcon.image(for: indicator)
                    let tinted = NSImage(size: icon.size, flipped: false) { iconRect in
                        icon.draw(in: iconRect)
                        (suffix == "light" ? NSColor.black : NSColor.white).set()
                        iconRect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 8 + CGFloat(index) * 30, y: 4, width: 22, height: 22))
                }
                return true
            }
            let tiff = try #require(strip.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("6-menubar-\(suffix).png"))
        }
    }
}

/// Knows who spoke when and reports it as audio arrives, in its own clock, like a
/// live diarizer would; it stands in for the model in end-to-end tests.
private final class TruthDiarizer: MeetingVoiceDiarizing, @unchecked Sendable {
    private let truth: [MeetingVoiceSpan]
    private var fed: TimeInterval = 0
    init(_ truth: [MeetingVoiceSpan]) { self.truth = truth }

    func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan] {
        let (from, to) = (fed, fed + Double(samples.count) / sampleRate)
        fed = to
        return truth.compactMap { span in
            let start = max(span.start, from), end = min(span.end, to)
            return end > start ? MeetingVoiceSpan(voice: span.voice, start: start, end: end) : nil
        }
    }

    func finish() throws -> [MeetingVoiceSpan] { [] }
}

/// Writes saved exports as PDF into the temporary directory, as the panel would.
@MainActor
private final class SavedFiles {
    var urls: [URL] = []
    func write(_ export: MeetingExport, _ name: String) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(MeetingExportFormat.pdf.fileName(base: "\(name)-\(UUID())"))
        guard (try? export.data(as: .pdf).write(to: url)) != nil else { return false }
        urls.append(url)
        return true
    }
}
