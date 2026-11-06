import Foundation
import PDFKit
import Testing
@testable import OpenScreenReader

private func others(_ start: TimeInterval, _ end: TimeInterval, _ text: String, final: Bool = true,
                    words: [(String, TimeInterval, TimeInterval)] = []) -> MeetingRecognition {
    MeetingRecognition(speaker: .others, start: start, end: end, text: text, isFinal: final,
                       pieces: words.map { MeetingPiece(text: $0.0, start: $0.1, end: $0.2) })
}

private func me(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> MeetingRecognition {
    MeetingRecognition(speaker: .me, start: start, end: end, text: text, isFinal: true)
}

private func voice(_ voice: Int, _ start: TimeInterval, _ end: TimeInterval) -> MeetingVoiceSpan {
    MeetingVoiceSpan(voice: voice, start: start, end: end)
}

@Suite("Meeting voices")
struct MeetingVoiceTests {
    @Test
    func withoutVoicesTheOthersStayOneSpeaker() {
        var transcript = MeetingTranscript()
        transcript.apply(others(0, 2, "Guten Morgen."))
        transcript.apply(me(3, 4, "Hallo."))
        #expect(transcript.entries.map(\.label) == ["Others", "Me"])
        #expect(transcript.entries.map(\.voice) == [nil, nil])
    }

    @Test
    func segmentsGoToTheVoiceThatSpokeMostDuringThem() {
        var transcript = MeetingTranscript()
        transcript.apply(others(0, 4, "Guten Morgen zusammen."))
        transcript.apply(others(5, 8, "Danke, hallo."))
        transcript.addVoice(voice(7, 0.2, 4.1))
        transcript.addVoice(voice(3, 4.9, 8.2))
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(transcript.entries.map(\.voice) == [7, 3])
    }

    @Test
    func aChangeOfVoiceInsideOneSegmentSplitsItAtTheWords() {
        var transcript = MeetingTranscript()
        transcript.apply(others(0, 6, "Ist das freigegeben? Ja, seit Dienstag.", words: [
            ("Ist", 0, 0.3), ("das", 0.3, 0.6), ("freigegeben", 0.6, 1.4), ("?", 1.4, 1.5),
            ("Ja", 3, 3.3), (",", 3.3, 3.35), ("seit", 3.4, 3.8), ("Dienstag", 3.8, 4.5), (".", 4.5, 4.55),
        ]))
        transcript.addVoice(voice(0, 0, 1.6))
        transcript.addVoice(voice(1, 2.9, 4.7))
        #expect(transcript.entries.map(\.text) == ["Ist das freigegeben?", "Ja, seit Dienstag."])
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2"])
    }

    @Test
    func wordsBetweenSpansStayWithTheirNeighbours() {
        var transcript = MeetingTranscript()
        transcript.apply(others(0, 4, "Das machen wir so.", words: [
            ("Das", 0, 0.3), ("machen", 0.3, 0.8), ("wir", 2.5, 2.8), ("so", 2.8, 3.2), (".", 3.2, 3.25),
        ]))
        // The diarizer lost the voice for a moment in the middle.
        transcript.addVoice(voice(4, 0, 0.9))
        transcript.addVoice(voice(4, 2.4, 3.4))
        #expect(transcript.entries.map(\.text) == ["Das machen wir so."])
        #expect(transcript.entries.map(\.voice) == [4])
    }

    @Test
    func consecutiveSegmentsOfOneVoiceFormOneTurnAndNumbersFollowFirstWords() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(9, 0, 2))
        transcript.addVoice(voice(2, 3, 5))
        transcript.addVoice(voice(2, 5.5, 7))
        transcript.addVoice(voice(9, 8, 10))
        transcript.apply(others(0, 2, "Eins."))
        transcript.apply(others(3, 5, "Zwei."))
        transcript.apply(others(5.5, 7, "Drei."))
        transcript.apply(others(8, 10, "Vier."))
        #expect(transcript.entries.map(\.text) == ["Eins.", "Zwei. Drei.", "Vier."])
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(transcript.voices.map(\.voice) == [9, 2])
    }

    @Test
    func voicesArrivingAfterTheTextStillAssignIt() {
        var transcript = MeetingTranscript()
        transcript.apply(others(0, 2, "Hallo", final: false))
        #expect(transcript.entries.map(\.label) == ["Others"])
        transcript.addVoice(voice(1, 0, 2))
        #expect(transcript.entries.map(\.label) == ["Speaker 1"])
        #expect(transcript.entries.map(\.pending) == ["Hallo"])
    }

    @Test
    func aNameReplacesTheNumberEverywhereAndAnEmptyNameRestoresIt() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(5, 0, 2))
        transcript.addVoice(voice(6, 3, 5))
        transcript.addVoice(voice(5, 6, 8))
        transcript.apply(others(0, 2, "A."))
        transcript.apply(others(3, 5, "B."))
        transcript.apply(others(6, 8, "C."))
        transcript.rename(voice: 5, to: "  Anna ")
        #expect(transcript.entries.map(\.label) == ["Anna", "Speaker 2", "Anna"])
        #expect(transcript.voices.map(\.label) == ["Anna", "Speaker 2"])
        transcript.rename(voice: 5, to: " ")
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test
    func mergingJoinsTurnsAndKeepsTheTargetsNameAndNumber() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 2))
        transcript.addVoice(voice(1, 3, 5))
        transcript.addVoice(voice(2, 6, 8))
        transcript.apply(others(0, 2, "A."))
        transcript.apply(others(3, 5, "B."))
        transcript.apply(others(6, 8, "C."))
        transcript.rename(voice: 0, to: "Anna")
        transcript.merge(voice: 1, into: 0)
        #expect(transcript.entries.map(\.text) == ["A. B.", "C."])
        #expect(transcript.entries.map(\.label) == ["Anna", "Speaker 3"])
        #expect(transcript.voices.map(\.voice) == [0, 2])
        // A voice merged into one that is merged later follows along.
        transcript.merge(voice: 0, into: 2)
        #expect(transcript.entries.map(\.label) == ["Speaker 3"])
        #expect(transcript.entries.map(\.text) == ["A. B. C."])
    }

    @Test
    func mergingIntoItselfOrInACircleChangesNothing() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 2))
        transcript.addVoice(voice(1, 3, 5))
        transcript.apply(others(0, 2, "A."))
        transcript.apply(others(3, 5, "B."))
        transcript.merge(voice: 0, into: 0)
        transcript.merge(voice: 0, into: 1)
        transcript.merge(voice: 1, into: 0)
        #expect(transcript.entries.map(\.text) == ["A. B."])
        #expect(transcript.entries.map(\.voice) == [1])
    }

    @Test
    func myOwnTextNeverTakesAVoice() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 5))
        transcript.apply(me(1, 2, "Ich rede."))
        #expect(transcript.entries.map(\.label) == ["Me"])
        #expect(transcript.voices.isEmpty)
    }

    @Test
    func exportUsesTheNames() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(3, 0, 2))
        transcript.apply(others(0, 2, "Hallo."))
        transcript.apply(me(3, 4, "Hi."))
        transcript.rename(voice: 3, to: "Ben")
        let export = MeetingExport(transcript: transcript, title: "T", duration: 4)
        #expect(export.turns.map(\.speaker) == ["Ben", "Me"])
        #expect(export.speakers == ["Ben", "Me"])
    }

    @Test
    func longSpansAreSplitSoLookupsStayLocal() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 95))
        #expect(transcript.voiceSpans.count == 4)
        #expect(transcript.voiceSpans.allSatisfy { $0.end - $0.start <= 30 })
        transcript.apply(others(80, 82, "Spaet im Monolog."))
        #expect(transcript.entries.map(\.voice) == [0])
    }
}

/// One turn the diarizer gave the wrong voice, moved by hand. The model often hears
/// two similar voices as one, and nothing after the model can split them.
@Suite("Meeting turn corrections")
struct MeetingTurnCorrectionTests {
    /// Speaker 1 says A and C, Speaker 2 says B.
    private func threeTurns() -> MeetingTranscript {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 2))
        transcript.addVoice(voice(1, 3, 5))
        transcript.addVoice(voice(0, 6, 8))
        transcript.apply(others(0, 2, "A."))
        transcript.apply(others(3, 5, "B."))
        transcript.apply(others(6, 8, "C."))
        return transcript
    }

    @Test
    func aTurnMovesToAnotherVoiceAndTheRestOfItsVoiceStays() {
        var transcript = threeTurns()
        transcript.reassign(transcript.entries[2], to: 1)
        #expect(transcript.entries.map(\.text) == ["A.", "B. C."])
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2"])
        // Moving the first words of a voice does not renumber anyone.
        transcript.reassign(transcript.entries[0], to: 1)
        #expect(transcript.entries.map(\.text) == ["A. B. C."])
        #expect(transcript.entries.map(\.label) == ["Speaker 2"])
        #expect(transcript.voices.map(\.label) == ["Speaker 2"])
    }

    @Test
    func onlyTheWordsOfTheTurnMoveWhenASegmentHoldsTwoVoices() {
        var transcript = MeetingTranscript()
        transcript.apply(others(0, 6, "Ist das freigegeben? Ja, seit Dienstag.", words: [
            ("Ist", 0, 0.3), ("das", 0.3, 0.6), ("freigegeben", 0.6, 1.4), ("?", 1.4, 1.5),
            ("Ja", 3, 3.3), (",", 3.3, 3.35), ("seit", 3.4, 3.8), ("Dienstag", 3.8, 4.5), (".", 4.5, 4.55),
        ]))
        transcript.addVoice(voice(0, 0, 1.6))
        transcript.addVoice(voice(1, 2.9, 4.7))
        // A turn knows where its words end, not only where they start.
        #expect(transcript.entries.map(\.start) == [0, 3])
        #expect(transcript.entries.map(\.end) == [1.5, 4.55])
        transcript.reassignToNewPerson(transcript.entries[0])
        #expect(transcript.entries.map(\.text) == ["Ist das freigegeben?", "Ja, seit Dienstag."])
        #expect(transcript.entries.map(\.label) == ["Speaker 3", "Speaker 2"])
        transcript.reassign(transcript.entries[1], to: transcript.entries[0].voice!)
        #expect(transcript.entries.map(\.text) == ["Ist das freigegeben? Ja, seit Dienstag."])
        #expect(transcript.entries.map(\.label) == ["Speaker 3"])
    }

    @Test
    func aNewPersonTakesTheNextFreeNumberAndKeepsIt() {
        var transcript = threeTurns()
        #expect(transcript.newPersonLabel == "Speaker 3")
        transcript.reassignToNewPerson(transcript.entries[2])
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(transcript.voices.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(transcript.newPersonLabel == "Speaker 4")
        // A voice the model hears later gets the next number, not the new person's.
        transcript.addVoice(voice(5, 9, 10))
        transcript.apply(others(9, 10, "D."))
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"])
        // The new person is a voice like the others: it can be named.
        let newPerson = transcript.entries[2].voice!
        transcript.rename(voice: newPerson, to: "Clara")
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Speaker 2", "Clara", "Speaker 4"])
        #expect(transcript.newPersonLabel == "Speaker 5")
    }

    @Test
    func aCorrectionWinsOverVoicesTheModelReportsLater() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 2))
        transcript.apply(others(0, 2, "Hallo zusammen."))
        transcript.reassignToNewPerson(transcript.entries[0])
        let corrected = transcript.entries[0].voice
        // The diarizer's look-ahead reports that stretch again, and a new one after it.
        transcript.addVoice(voice(0, 0, 2))
        transcript.addVoice(voice(3, 0.5, 1.8))
        transcript.addVoice(voice(0, 2.2, 4))
        transcript.apply(others(2.2, 4, "Ich fange an."))
        #expect(transcript.entries.map(\.voice) == [corrected, 0])
        #expect(transcript.entries.map(\.label) == ["Speaker 2", "Speaker 1"])
        // Text the recogniser finishes later inside the corrected stretch follows it too.
        transcript.apply(others(1.2, 1.9, "Kurz.", final: false))
        #expect(transcript.entries.first?.pending == "Kurz.")
        #expect(transcript.entries.first?.voice == corrected)
    }

    @Test
    func correctionsWorkWithMergesAndNames() {
        var transcript = MeetingTranscript()
        transcript.addVoice(voice(0, 0, 2))
        transcript.addVoice(voice(1, 3, 5))
        transcript.addVoice(voice(2, 6, 8))
        transcript.apply(others(0, 2, "A."))
        transcript.apply(others(3, 5, "B."))
        transcript.apply(others(6, 8, "C."))
        transcript.reassign(transcript.entries[2], to: 1)
        transcript.rename(voice: 1, to: "Ben")
        #expect(transcript.entries.map(\.label) == ["Speaker 1", "Ben"])
        #expect(transcript.entries.map(\.text) == ["A.", "B. C."])
        transcript.merge(voice: 1, into: 0)
        #expect(transcript.entries.map(\.text) == ["A. B. C."])
        #expect(transcript.entries.map(\.label) == ["Speaker 1"])
        // A new person can be joined with a voice, and a merged voice can be the target.
        transcript.reassignToNewPerson(transcript.entries[0])
        #expect(transcript.entries.map(\.label) == ["Speaker 4"])
        transcript.merge(voice: transcript.entries[0].voice!, into: 1)
        #expect(transcript.entries.map(\.label) == ["Speaker 1"])
    }

    @Test
    func myTurnsAndUnvoicedTurnsCannotBeMoved() {
        var transcript = MeetingTranscript()
        transcript.apply(me(0, 1, "Ich."))
        transcript.apply(others(2, 3, "Jemand."))
        let before = transcript
        transcript.reassignToNewPerson(transcript.entries[0])
        transcript.reassign(transcript.entries[1], to: 0)
        #expect(transcript == before)
    }

    @Test
    func correctionsReachEveryExportFormat() throws {
        var transcript = threeTurns()
        transcript.reassignToNewPerson(transcript.entries[2])
        transcript.rename(voice: transcript.entries[2].voice!, to: "Clara")
        transcript.apply(me(9, 10, "Danke."))
        let export = MeetingExport(transcript: transcript, title: "T", duration: 10)
        #expect(export.turns.map(\.speaker) == ["Speaker 1", "Speaker 2", "Clara", "Me"])
        #expect(export.speakers == ["Speaker 1", "Speaker 2", "Clara", "Me"])
        #expect(export.markdown.contains("**Clara** · 00:00:06\nC."))
        #expect(export.plainText.contains("Clara · 00:00:06\nC."))
        let text = try #require(PDFDocument(data: try export.data(as: .pdf))?.string)
        #expect(text.contains("Clara"))
        #expect(text.contains("C."))
    }
}

/// Reports a voice for each chunk it receives, in its own clock: seconds fed so far.
final class DiarizerFake: MeetingVoiceDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _fed: TimeInterval = 0
    private var _finished = false
    var gate: DispatchSemaphore?
    var failure: Error?
    var voice = 0
    var finalSpan: MeetingVoiceSpan?
    var fed: TimeInterval { lock.withLock { _fed } }
    var finished: Bool { lock.withLock { _finished } }

    func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan] {
        gate?.wait()
        if let failure { throw failure }
        let duration = Double(samples.count) / sampleRate
        let start = lock.withLock { () -> TimeInterval in
            defer { _fed += duration }
            return _fed
        }
        return [MeetingVoiceSpan(voice: voice, start: start, end: start + duration)]
    }

    func finish() throws -> [MeetingVoiceSpan] {
        lock.withLock { _finished = true }
        return finalSpan.map { [$0] } ?? []
    }
}

private final class VoiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _spans: [MeetingVoiceSpan] = []
    private var _failures: [String] = []
    var spans: [MeetingVoiceSpan] { lock.withLock { _spans } }
    var failures: [String] { lock.withLock { _failures } }
    func add(_ spans: [MeetingVoiceSpan]) { lock.withLock { _spans += spans } }
    func fail(_ message: String) { lock.withLock { _failures.append(message) } }
}

private func second(at hostSeconds: TimeInterval = 0, rate: Double = 8_000) -> MeetingAudioChunk {
    MeetingAudioChunk(samples: [Float](repeating: 0.1, count: Int(rate)), sampleRate: rate,
                      hostTime: MeetingHostClock.hostTicks(forSeconds: hostSeconds))
}

@Suite("Meeting voice tracker")
struct MeetingVoiceTrackerTests {
    private func tracker(_ diarizer: DiarizerFake, _ box: VoiceBox, backlog: TimeInterval = 5) -> MeetingVoiceTracker {
        MeetingVoiceTracker(diarizer: diarizer, backlogLimit: backlog,
                            onVoices: { box.add($0) }, onFailure: { box.fail($0) })
    }

    @Test
    func voicesLandOnTheMeetingTimelineAcrossAGap() {
        let diarizer = DiarizerFake(), box = VoiceBox()
        let tracker = tracker(diarizer, box)
        tracker.append(second(), at: 12)
        tracker.append(second(), at: 13)
        // Audio stalled for a while; the diarizer's clock does not know that.
        tracker.append(second(), at: 40)
        tracker.drain()
        #expect(box.spans == [
            MeetingVoiceSpan(voice: 0, start: 12, end: 13),
            MeetingVoiceSpan(voice: 0, start: 13, end: 14),
            MeetingVoiceSpan(voice: 0, start: 40, end: 41),
        ])
    }

    @Test
    func finishFlushesTheLastVoicesAndCancelSilencesLateOnes() {
        let diarizer = DiarizerFake(), box = VoiceBox()
        diarizer.finalSpan = MeetingVoiceSpan(voice: 2, start: 0.5, end: 1)
        let tracker = tracker(diarizer, box)
        tracker.append(second(), at: 3)
        tracker.finish()
        #expect(diarizer.finished)
        #expect(box.spans.last == MeetingVoiceSpan(voice: 2, start: 3.5, end: 4))
        tracker.append(second(), at: 4)
        tracker.drain()
        #expect(box.spans.count == 2)

        let other = DiarizerFake(), silenced = VoiceBox()
        let cancelled = self.tracker(other, silenced)
        other.gate = DispatchSemaphore(value: 0)
        cancelled.append(second(), at: 0)
        cancelled.cancel()
        other.gate?.signal()
        cancelled.drain()
        #expect(silenced.spans.isEmpty)
    }

    @Test
    func aSlowDiarizerDropsAudioInsteadOfHoardingIt() {
        let diarizer = DiarizerFake(), box = VoiceBox()
        diarizer.gate = DispatchSemaphore(value: 0)
        let tracker = tracker(diarizer, box, backlog: 3)
        for index in 0..<10 { tracker.append(second(), at: TimeInterval(index)) }
        for _ in 0..<10 { diarizer.gate?.signal() }
        tracker.drain()
        #expect(diarizer.fed == 3)
        // After the backlog cleared, audio flows again and lands at its own time.
        tracker.append(second(), at: 30)
        diarizer.gate?.signal()
        tracker.drain()
        #expect(box.spans.last == MeetingVoiceSpan(voice: 0, start: 30, end: 31))
    }

    @Test
    func aFailingDiarizerReportsOnceAndStops() {
        let diarizer = DiarizerFake(), box = VoiceBox()
        diarizer.failure = MeetingError("model gone")
        let tracker = tracker(diarizer, box)
        tracker.append(second(), at: 0)
        tracker.append(second(), at: 1)
        tracker.finish()
        #expect(box.failures == ["model gone"])
        #expect(box.spans.isEmpty)
    }

    /// The model and its state end with the transcript, even while the tracker itself
    /// stays reachable from the finished transcript's router.
    @Test
    func theDiarizerIsReleasedWhenTheTrackerEnds() {
        func stillAlive(after end: (MeetingVoiceTracker, DiarizerFake) -> Void) -> Bool {
            var diarizer: DiarizerFake? = DiarizerFake()
            weak var weakly = diarizer
            let tracker = self.tracker(diarizer!, VoiceBox())
            tracker.append(second(), at: 0)
            end(tracker, diarizer!)
            diarizer = nil
            tracker.drain()
            return withExtendedLifetime(tracker) { weakly != nil }
        }
        #expect(!stillAlive { tracker, _ in tracker.finish() })
        #expect(!stillAlive { tracker, _ in tracker.cancel() })
        #expect(!stillAlive { tracker, diarizer in
            diarizer.failure = MeetingError("model gone")
            tracker.append(second(), at: 1)
        })
    }
}

@Suite("Meeting voice model")
struct MeetingVoiceModelTests {
    @Test
    func theBundledModelIsFoundOnlyWithItsWeights() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: resources) }
        #expect(MeetingVoiceModel.bundled(in: resources) == nil)
        let model = resources.appendingPathComponent("Diarization/ls_eend_dih3_100ms.mlmodelc")
        try FileManager.default.createDirectory(at: model.appendingPathComponent("weights"), withIntermediateDirectories: true)
        #expect(MeetingVoiceModel.bundled(in: resources) == nil)
        try Data([0]).write(to: model.appendingPathComponent("weights/weight.bin"))
        #expect(MeetingVoiceModel.bundled(in: resources)?.lastPathComponent == "ls_eend_dih3_100ms.mlmodelc")
    }
}
