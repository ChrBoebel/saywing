import AppKit
import AVFoundation
import CoreGraphics
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import OpenScreenReader

@Suite("Speech transport and buffering", .serialized)
@MainActor
struct SpeechBufferingTests {
    @Test
    func stoppingBeforePreparationTaskStartsCannotLaunchAWorkerLater() async throws {
        let service = LocalSpeechService()
        defer { service.stop() }
        service.prepareNext("Ein kurzer öffentlicher Testsatz.")
        service.stop()
        try await Task.sleep(for: .milliseconds(40))
        #expect(service.workerLaunchCount == 0)
        #expect(service.workerPID == nil)
        #expect(service.preparedAudioBytes == 0)
    }

    @Test
    func preparationBufferIsBoundedAndCancellationReleasesBothSides() async throws {
        let buffer = SpeechPreparationBuffer(capacityBytes: 8)
        try await buffer.send(Data(repeating: 1, count: 8))
        var sent = false
        let producer = Task { try await buffer.send(Data(repeating: 2, count: 4)); sent = true }
        await Task.yield()
        #expect(buffer.bufferedBytes == 8)
        #expect(!sent)
        #expect(try await buffer.next()?.count == 8)
        try await producer.value
        #expect(buffer.bufferedBytes == 4)
        buffer.cancel()
        #expect(buffer.bufferedBytes == 0)
        do { _ = try await buffer.next(); Issue.record("Cancelled buffer accepted consumer") }
        catch { #expect(error is CancellationError) }
        let full = SpeechPreparationBuffer(capacityBytes: 8)
        try await full.send(Data(repeating: 1, count: 8))
        let blockedProducer = Task { try await full.send(Data(repeating: 1, count: 4)) }
        await Task.yield()
        full.cancel()
        do { try await blockedProducer.value; Issue.record("Cancelled producer survived") }
        catch { #expect(error is CancellationError) }
        #expect(full.bufferedBytes == 0)
        let empty = SpeechPreparationBuffer(capacityBytes: 8)
        let consumer = Task { try await empty.next() }
        await Task.yield()
        empty.cancel()
        do { _ = try await consumer.value; Issue.record("Cancelled consumer survived") }
        catch { #expect(error is CancellationError) }
    }

    @Test
    func playbackSpeedIsBoundedAndSurvivesResetWithoutPitchShift() {
        let player = SpeechAudioPlayer(sampleRate: 44_100)
        player.playbackRate = 1.5
        #expect(player.playbackRate == 1.5)
        #if arch(x86_64)
        #expect(player.prebufferFrames == 132_300)
        #else
        #expect(player.prebufferFrames == 66_150)
        #endif
        #expect(player.pitchCents == 0)
        player.reset()
        #expect(player.playbackRate == 1.5)
        player.playbackRate = 99
        #expect(player.playbackRate == 2)
        player.playbackRate = 0
        #expect(player.playbackRate == 0.75)
        player.playbackRate = .nan
        #expect(player.playbackRate == 1)
        player.stop()
    }

    @Test
    func envelopeFollowsRenderedFramesAndDropsOldLevels() {
        var envelope = PlaybackEnvelope()
        let samples: [Float] = Array(repeating: 0.25, count: 480) + Array(repeating: 0, count: 480)
        samples.withUnsafeBufferPointer { envelope.append($0, startingAt: 2_400, sampleRate: 24_000) }
        #expect(envelope.level(at: 0) == 0)
        #expect(envelope.level(at: 2_400) > 0.5)
        #expect(envelope.level(at: 2_880) == 0)
        #expect(envelope.level(at: 3_360) == 0)
        #expect(envelope.count == 0)
    }

    @Test
    func supertonicIsTheOnlyDefaultAndUsesItsNativeSampleRate() {
        let runtime = SpeechRuntimeConfiguration(root: URL(fileURLWithPath: "/missing-runtime"))
        #expect(runtime.sampleRate == 44_100)
        #expect(runtime.modelName == "Supertonic 3 · M1")
        #expect(runtime.executable.path.contains("SupertonicRuntime/venv/bin/python3"))
        #expect(runtime.model.path.hasSuffix("supertonic-3-3cadd1ee"))
        #expect(!runtime.isInstalled)
        #expect(SpeechRuntimeConfiguration.language(for: "Dies ist ein deutscher Beispielsatz.") == "de")
        #expect(SpeechRuntimeConfiguration.language(for: "This is an English sentence about reading books.") == "en")
    }

    @Test
    func nativeSupertonicRateKeepsEightSourceSecondsOfBufferCapacity() async throws {
        let player = SpeechAudioPlayer(sampleRate: 44_100)
        defer { player.stop() }
        #expect(player.capacityFrames == 352_800)
        #expect(player.prebufferFrames == 44_100)
        try await player.enqueue(Data(repeating: 0, count: 9_600)) {}
        try await player.finish {}
        #expect(player.diagnostics.frames == 2_400)
        #expect(player.queuedFrames == 0)
    }

    @Test
    func outputChangeEndsTheReadingAtOnceAndDropsQueuedAudio() async throws {
        let player = SpeechAudioPlayer(sampleRate: 44_100)
        defer { player.stop() }
        player.setPaused(true)
        for _ in 0..<3 { try await player.enqueue(Data(repeating: 0, count: 96_000)) {} }
        #expect(player.queuedFrames == 72_000)
        let drain = Task { try await player.finish {} }
        try await Task.sleep(for: .milliseconds(40))
        // A change the engine survived loses nothing and ends nothing.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: player.engine)
        try await Task.sleep(for: .milliseconds(40))
        #expect(player.queuedFrames == 72_000)
        #expect(!player.outputChanged)
        // A real output change stops the engine first.
        player.engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: player.engine)
        do { try await drain.value; Issue.record("The drain outlived the output change") }
        catch { #expect(error as? SpeechFailure == .outputChanged) }
        #expect(player.queuedFrames == 0)
        do { try await player.enqueue(Data(repeating: 0, count: 9_600)) {}; Issue.record("Audio was queued for the old output") }
        catch { #expect(error as? SpeechFailure == .outputChanged) }
        player.reset()
        #expect(!player.outputChanged)
        try await player.enqueue(Data(repeating: 0, count: 9_600)) {}
        try await player.finish {}
        #expect(player.queuedFrames == 0)
    }

    @Test
    func engineStoppedBeforeTheNoticeIsNotSilentlyRestarted() async throws {
        let player = SpeechAudioPlayer(sampleRate: 44_100)
        defer { player.stop() }
        player.setPaused(true)
        try await player.enqueue(Data(repeating: 0, count: 96_000)) {}
        player.engine.stop()
        do { try await player.enqueue(Data(repeating: 0, count: 96_000)) {}; Issue.record("Engine restarted after a gap") }
        catch { #expect(error as? SpeechFailure == .outputChanged) }
        #expect(player.queuedFrames == 0)
        #expect(!player.engine.isRunning)
    }

    @Test
    func blockedPacketReadsLeaveTheCooperativePoolFree() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let pipes = (0..<count).map { _ in Pipe() }
        defer { pipes.forEach { try? $0.fileHandleForWriting.close(); try? $0.fileHandleForReading.close() } }
        let readers = pipes.map { SpeechPacketReader(handle: $0.fileHandleForReading) }
        let pending = readers.map { reader in Task.detached { try await reader.nextLine() } }
        try await Task.sleep(for: .milliseconds(100))
        let probe = PoolProbe()
        Task.detached { await MainActor.run { probe.ran = true } }
        for _ in 0..<200 where !probe.ran { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.ran, "Blocking pipe reads starved Swift's cooperative thread pool.")
        pipes.forEach { try? $0.fileHandleForWriting.close() }
        for task in pending { #expect(try await task.value == nil) }
    }

    @Test
    func shortPacketReturnsBeforeWriterCloses() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let reader = SpeechPacketReader(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        var hadToCloseWriter = false
        let deadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            hadToCloseWriter = true
            try? pipe.fileHandleForWriting.close()
        }
        defer { deadline.cancel() }
        let line = try await reader.nextLine()
        #expect(line == Data("ready".utf8))
        #expect(!hadToCloseWriter)
    }

    @Test
    func framingPreservesMultiplePacketsAndRejectsTruncatedTail() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let reader = SpeechPacketReader(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\nsecond\ntail".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(try await reader.nextLine() == Data("first".utf8))
        #expect(try await reader.nextLine() == Data("second".utf8))
        do { _ = try await reader.nextLine(); Issue.record("Truncated packet accepted") }
        catch { #expect(error is SpeechFailure) }
    }

    @Test
    func oversizedPacketIsRejected() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let reader = SpeechPacketReader(handle: pipe.fileHandleForReading)
        let writer = Task.detached {
            try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 140_001))
            try pipe.fileHandleForWriting.close()
        }
        do { _ = try await reader.nextLine(); Issue.record("Oversized packet accepted") }
        catch { #expect(error is SpeechFailure) }
        try await writer.value
    }

    @Test
    func prebufferQueuesAheadAndShortTailStillDrains() async throws {
        let player = SpeechAudioPlayer()
        defer { player.stop() }
        var started = false
        for _ in 0..<3 {
            try await player.enqueue(Data(repeating: 0, count: 28_800)) { started = true }
        }
        #expect(!started)
        #expect(player.queuedFrames == 21_600)
        try await player.enqueue(Data(repeating: 0, count: 28_800)) { started = true }
        #expect(started)
        #expect(player.queuedFrames == 28_800)
        try await player.finish { started = true }
        #expect(player.queuedFrames == 0)
        #expect(player.diagnostics.underruns == 0)
        player.reset()
        started = false
        try await player.enqueue(Data(repeating: 0, count: 9_600)) { started = true }
        #expect(!started)
        try await player.finish { started = true }
        #expect(started)
        #expect(player.queuedFrames == 0)
        #expect(player.diagnostics.frames == 2_400)
    }

    @Test
    func fullQueueBlocksProducerAndCancellationReleasesIt() async throws {
        let player = SpeechAudioPlayer()
        defer { player.stop() }
        let producer = Task { @MainActor in
            for _ in 0..<20 { try await player.enqueue(Data(repeating: 0, count: 96_000)) {} }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while player.queuedFrames < player.capacityFrames, .now < deadline { await Task.yield() }
        #expect(player.queuedFrames == player.capacityFrames)
        #expect(player.diagnostics.maximumQueuedFrames <= player.capacityFrames)
        player.stop()
        do { try await producer.value; Issue.record("Cancelled producer completed successfully") }
        catch { #expect(error is CancellationError) }
        #expect(player.queuedFrames == 0)
        player.reset()
        try await player.enqueue(Data(repeating: 0, count: 9_600)) {}
        try await player.finish {}
        #expect(player.queuedFrames == 0)
        #expect(player.diagnostics.frames == 2_400)
    }
}

@Suite("Primary interaction")
@MainActor
struct InteractionTests {
    @Test
    func regionSelectionUsesNonactivatingPanelsAndRemovesThemOnCancel() throws {
        let controller = RegionSelectionOverlayController()
        let existing = Set(NSApp.windows.map(\.windowNumber))
        controller.start(onSelection: { _ in }, onCancel: { _ in })
        defer { controller.cancel() }
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        #expect(panels.count == NSScreen.screens.count)
        #expect(!panels.isEmpty)
        for window in panels {
            let panel = try #require(window as? NSPanel)
            #expect(panel.styleMask.contains(.nonactivatingPanel))
            #expect(!panel.hidesOnDeactivate)
            #expect(panel.canBecomeKey)
            #expect(!panel.canBecomeMain)
        }
        controller.cancel()
        #expect(panels.allSatisfy { !$0.isVisible })
    }

    @Test
    func explicitStopWhileIdleNeverStartsSelection() async {
        let f = QueueFixture()
        f.model.enqueueStopRequest()
        await f.model.waitForInteractionToSettle()
        #expect(f.selection.startCount == 0)
        #expect(f.model.status == .ready)
    }
    @Test
    func pausedPlayerDoesNotAutoStartAndStopReleasesDrain() async throws {
        let player = SpeechAudioPlayer(sampleRate: 44_100)
        player.setPaused(true)
        var callbacks = 0
        for _ in 0..<3 { try await player.enqueue(Data(repeating: 0, count: 96_000)) { callbacks += 1 } }
        #expect(player.isPaused)
        #expect(callbacks == 0)
        let drain = Task { try await player.finish { callbacks += 1 } }
        try await Task.sleep(for: .milliseconds(80))
        #expect(player.queuedFrames == 72_000)
        player.stop()
        do { try await drain.value; Issue.record("Stopped drain returned successfully") }
        catch is CancellationError {}
        #expect(!player.isPaused)
        #expect(player.queuedFrames == 0)
    }

    @Test
    func queueEditingUsesStableIDsAndRefreshesPreparation() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        await f.model.waitForInteractionToSettle()
        f.model.togglePause()
        #expect(f.model.isPaused && f.speech.isPaused)
        for text in ["Second", "Third", "Fourth"] {
            f.ocr.result = OCRResult(lines: [text])
            f.model.enqueueAddRequest()
            await f.model.waitForInteractionToSettle()
            f.selection.complete(Self.ocrRegion)
            await f.model.waitForQueueInputToSettle()
        }
        let entries = f.model.queueEntries
        f.model.moveQueueEntry(entries[2].id, offset: -1)
        f.model.removeQueueEntry(entries[0].id)
        #expect(f.model.queueEntries.map(\.preview) == ["Fourth", "Third"])
        #expect(f.speech.preparedText == "Fourth")
        f.model.removeQueueEntry(entries[0].id)
        #expect(f.model.queuedTextCount == 2)
        f.model.playQueueEntry(entries[1].id)
        await f.model.waitForInteractionToSettle()
        try await f.speech.waitForReads(2)
        #expect(f.speech.texts.last == "Third")
        #expect(!f.model.isPaused)
        #expect(f.model.queueEntries.map(\.preview) == ["Fourth"])
        await f.model.handleReadRequest()
        #expect(f.model.queueEntries.isEmpty)
    }
    @Test
    func repeatedPrimaryShortcutQueuesWithoutStoppingAndIgnoresDuplicateSelection() async throws {
        let f = QueueFixture()
        f.hotkey.onPress?()
        await f.model.waitForInteractionToSettle()
        f.hotkey.onPress?()
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .selecting)
        #expect(f.selection.startCount == 1)
        guard f.model.status == .selecting else { return }
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        f.hotkey.onPress?()
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .speaking)
        #expect(f.model.isAddingToQueue)
        #expect(f.selection.startCount == 2)
        guard f.model.isAddingToQueue else { return }
        f.hotkey.onPress?()
        await f.model.waitForInteractionToSettle()
        #expect(f.selection.startCount == 2)
        f.ocr.result = OCRResult(lines: ["Danach vorlesen"])
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForQueueInputToSettle()
        #expect(f.model.queuedTextCount == 1)
        #expect(f.speech.texts.count == 1)
        f.speech.finishFirst()
        try await f.speech.waitForReads(2)
        #expect(f.speech.texts.last == "Danach vorlesen")
        f.escape.onEscape?()
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .stopped)
        #expect(f.model.queuedTextCount == 0)
    }

    @Test
    func onlyEscapeEndingTheAddedSelectionStopsReading() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        for reason in [SelectionCancelReason.invalidSelection, .displaysChanged] {
            f.model.enqueueAddRequest()
            await f.model.waitForInteractionToSettle()
            #expect(f.model.isAddingToQueue)
            f.selection.end(reason)
            await f.model.waitForInteractionToSettle()
            #expect(f.model.status == .speaking, "\(reason) must not interrupt playback.")
            #expect(f.model.isReadingActive)
            #expect(!f.model.isAddingToQueue)
            #expect(f.model.queueNotice != nil)
            #expect(f.speech.texts.count == 1)
        }
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.end(.escape)
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .stopped)
        #expect(!f.model.isReadingActive)
    }

    @Test
    func endingTheFirstSelectionByItselfStillCancelsIt() async {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        #expect(f.model.status == .selecting)
        f.selection.end(.invalidSelection)
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .stopped)
        #expect(!f.model.isReadingActive)
    }

    @Test
    func queueEmptiedWhileAdvancingEndsTheReadingCleanly() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        f.ocr.result = OCRResult(lines: ["Gleich entfernt"])
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForQueueInputToSettle()
        let id = try #require(f.model.queueEntries.first?.id)
        // Settings removes the entry after the coordinator released the finished
        // text, before the queue advances.
        let model = f.model
        f.speech.onStopCurrent = { model.removeQueueEntry(id) }
        f.speech.finishFirst()
        await f.model.waitForSpeechToSettle()
        await f.model.waitForInteractionToSettle()
        #expect(f.model.queuedTextCount == 0)
        #expect(f.model.status == .ready)
        #expect(!f.model.isReadingActive)
        #expect(f.speech.texts == ["Hello world"])
    }

    @Test
    func quittingStopsTheSpeechWorker() async {
        let center = NotificationCenter()
        let speech = SpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            speechService: speech, appNotifications: center)
        #expect(!speech.stopped)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        for _ in 0..<100 where !speech.stopped { await Task.yield() }
        #expect(speech.stopped)
        _ = model
    }

    @Test
    func speedPreferencePersistsAndReachesTheProviderImmediately() throws {
        let suite = "com.christopherbobel.OpenScreenReader.speed-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = QueueSpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            speechService: speech, preferences: defaults)
        #expect(model.playbackRate == 1)
        model.setPlaybackRate(1.75)
        #expect(speech.playbackRate == 1.75)
        let next = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            speechService: QueueSpeechFake(), preferences: defaults)
        #expect(next.playbackRate == 1.75)
    }

    @Test
    func queueShortcutCannotReplaceStopAndFailedRegistrationKeepsPrevious() async {
        let queueHotkey = HotkeyManagerFake(registrationResult: .registered)
        let store = MemoryShortcutStore()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            queueHotkeyManager: queueHotkey, queueShortcutStore: store)
        model.enqueueQueueShortcutChange(.default)
        await model.waitForInteractionToSettle()
        #expect(model.queueShortcutConfiguration == .queueDefault)
        #expect(store.saved == nil)
        let custom = ShortcutConfiguration(key: "J", modifiers: UInt32(cmdKey | shiftKey | optionKey))
        model.enqueueQueueShortcutChange(custom)
        await model.waitForInteractionToSettle()
        #expect(store.saved == custom)
        queueHotkey.registrationResult = .conflict
        model.enqueueQueueShortcutChange(.queueDefault)
        await model.waitForInteractionToSettle()
        #expect(model.queueShortcutConfiguration == custom)
        #expect(store.saved == custom)
        model.enqueueShortcutChange(custom)
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == .default)
    }

    @Test
    func queueRejectsEmptyAndOversizedTextsAndStopsAtFive() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        for text in ["", String(repeating: "a", count: 8_001)] {
            f.ocr.result = OCRResult(lines: [text])
            f.model.enqueueAddRequest()
            await f.model.waitForInteractionToSettle()
            f.selection.complete(Self.ocrRegion)
            await f.model.waitForQueueInputToSettle()
            #expect(f.model.queuedTextCount == 0)
            #expect(f.model.status == .speaking)
            #expect(!f.model.isAddingToQueue)
        }
        for index in 0..<5 {
            f.ocr.result = OCRResult(lines: ["Text \(index)"])
            f.model.enqueueAddRequest()
            await f.model.waitForInteractionToSettle()
            f.selection.complete(Self.ocrRegion)
            await f.model.waitForQueueInputToSettle()
        }
        #expect(f.model.queuedTextCount == 5)
        let starts = f.selection.startCount
        f.hotkey.onPress?()
        await f.model.waitForInteractionToSettle()
        #expect(f.selection.startCount == starts)
        #expect(f.model.queuedTextCount == 5)
        #expect(f.model.status == .speaking)
        #expect(!f.model.canAddToQueue)
        await f.model.handleReadRequest()
        #expect(f.model.queuedTextCount == 0)
    }

    @Test
    func queuedTextsReadInOrderAndStopClearsAllWaitingText() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        for text in ["Zweiter Text", "Dritter Text"] {
            f.ocr.result = OCRResult(lines: [text])
            f.model.enqueueAddRequest()
            await f.model.waitForInteractionToSettle()
            f.selection.complete(Self.ocrRegion)
            await f.model.waitForQueueInputToSettle()
        }
        #expect(f.model.queuedTextCount == 2)
        #expect(f.speech.preparedText == "Zweiter Text", "Only the next FIFO entry is prepared.")
        #expect(f.speech.texts.count == 1, "Adding text must not stop or restart speech.")
        f.speech.finishFirst()
        try await f.speech.waitForReads(2)
        #expect(f.speech.texts == ["Hello world", "Zweiter Text"])
        #expect(f.model.queuedTextCount == 1)
        await f.model.waitForInteractionToSettle()
        #expect(f.speech.preparedText == "Dritter Text")
        await f.model.handleReadRequest()
        #expect(f.model.queuedTextCount == 0)
        #expect(!f.model.isAddingToQueue)
        #expect(f.model.status == .stopped)
        #expect(!f.escape.isActive)
        #expect(f.speech.preparedText == nil)
    }

    @Test
    func completionWaitsForPendingOCRAndSkipCannotCancelTheNextText() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        f.ocr.suspend = true
        f.ocr.result = OCRResult(lines: ["Danach"])
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.ocr.waitUntilStarted()
        f.speech.finishFirst()
        await f.model.waitForSpeechToSettle()
        #expect(f.model.status == .waiting)
        #expect(f.escape.isActive)
        f.ocr.resume()
        await f.model.waitForQueueInputToSettle()
        try await f.speech.waitForReads(2)
        f.ocr.suspend = false
        f.ocr.result = OCRResult(lines: ["Übersprungen zum nächsten"])
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForQueueInputToSettle()
        f.model.enqueueSkipRequest()
        await f.model.waitForInteractionToSettle()
        try await f.speech.waitForReads(3)
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .speaking)
        #expect(f.speech.texts.last == "Übersprungen zum nächsten")
        await f.model.handleReadRequest()
    }

    @Test
    func escapeDiscardsLateQueueOCRAndDoesNotRestartReading() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        f.ocr.suspend = true
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.ocr.waitUntilStarted()
        f.escape.onEscape?()
        await f.model.waitForInteractionToSettle()
        f.ocr.resume()
        await f.model.waitForQueueInputToSettle()
        #expect(f.model.status == .stopped)
        #expect(f.model.queuedTextCount == 0)
        #expect(f.speech.texts.count == 1)
    }

    @Test
    func queueCaptureTimeoutDoesNotInterruptSpeechOrAcceptItsLateResult() async throws {
        let timer = AsyncStream<Void>.makeStream()
        defer { timer.continuation.finish() }
        let f = QueueFixture(waitForQueueTimeout: { _ in
            for await _ in timer.stream { return }
            throw CancellationError()
        })
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        f.capture.suspend = true
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.capture.waitUntilStarted()
        timer.continuation.yield()
        // Wait for the observable timeout, not a wall-clock scheduling assumption.
        for _ in 0..<1000 {
            await Task.yield()
            await f.model.waitForInteractionToSettle()
            if !f.model.isAddingToQueue { break }
        }
        #expect(!f.model.isAddingToQueue)
        #expect(f.model.status == .speaking)
        f.capture.resume()
        await f.model.waitForQueueInputToSettle()
        #expect(f.model.queuedTextCount == 0)
        #expect(f.ocr.calls == 1)
        await f.model.handleReadRequest()
    }

    @Test
    func escapeStillStopsAfterAdvancingToAQueuedText() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        let escapeFromSessionStart = f.escape.onEscape
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForQueueInputToSettle()
        f.speech.finishFirst()
        try await f.speech.waitForReads(2)
        escapeFromSessionStart?()
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .stopped)
        #expect(f.model.queuedTextCount == 0)
        await f.model.handleReadRequest()
        escapeFromSessionStart?()
        await f.model.waitForInteractionToSettle()
        #expect(f.model.status == .selecting, "An old session's Escape callback must not stop a new session.")
        await f.model.handleReadRequest()
    }

    @Test
    func positionPreviewDoesNotCaptureRecognizeSpeakOrReplaceAnActiveOperation() async {
        let selection = RegionSelectionControllerFake()
        let capture = CaptureFake()
        let ocr = OCRFake()
        let speech = SpeechFake()
        let escape = EscapeFake()
        let panel = ReadingPanelFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: capture, escapeMonitor: escape,
            ocrService: ocr, speechService: speech, readingPanel: panel)
        model.previewReadingPanelPosition()
        #expect(panel.state == .positioning)
        #expect(panel.onStop == nil)
        #expect(model.status == .ready)
        #expect(selection.startCount == 0 && capture.calls == 0 && ocr.calls == 0)
        #expect(speech.receivedText == nil && !escape.isActive)
        await model.handleReadRequest()
        #expect(panel.state == nil)
        model.previewReadingPanelPosition()
        #expect(panel.state == nil, "Preview cannot replace selection or an active pipeline.")
        #expect(selection.startCount == 1)
        await model.handleReadRequest()
    }

    @Test
    func readingPanelStaysHiddenUntilCaptureFinishesAndStopsOnlyItsOwnOperation() async {
        let selection = RegionSelectionControllerFake()
        let capture = CaptureFake()
        capture.suspend = true
        let ocr = OCRFake()
        ocr.suspend = true
        let panel = ReadingPanelFake()
        let sounds = InterfaceSoundsFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: capture, escapeMonitor: EscapeFake(),
            ocrService: ocr, readingPanel: panel, interfaceSounds: sounds)
        await model.handleReadRequest()
        #expect(panel.state == nil)
        selection.complete(Self.ocrRegion)
        await capture.waitUntilStarted()
        #expect(model.status == .capturing)
        #expect(panel.state == nil)
        #expect(sounds.cues.isEmpty)
        capture.resume()
        await ocr.waitUntilStarted()
        #expect(panel.state == .recognizing)
        #expect(panel.origin == Self.ocrRegion.rectInScreenPoints, "The first visible state carries the captured frame.")
        #expect(sounds.cues.isEmpty, "The opening cue belongs to the control's landing, not the pipeline.")
        #expect(panel.displayID == Self.ocrRegion.displayID)
        let oldStop = panel.onStop
        oldStop?()
        await model.waitForInteractionToSettle()
        #expect(model.status == .stopped)
        #expect(panel.state == .stopped)
        #expect(sounds.isStopped)
        await model.handleReadRequest()
        #expect(panel.state == nil)
        oldStop?()
        ocr.resume()
        await model.waitForCaptureToSettle()
        await model.waitForInteractionToSettle()
        #expect(model.status == .selecting)
        #expect(panel.state == nil)
        await model.handleReadRequest()
    }

    @Test(arguments: [false, true])
    func readingPanelStopsLoadingAndPlayback(playing: Bool) async {
        let selection = RegionSelectionControllerFake()
        let speech = SpeechFake()
        speech.suspend = true
        speech.emitPlayback = playing
        let panel = ReadingPanelFake()
        let sounds = InterfaceSoundsFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: OCRFake(), speechService: speech, readingPanel: panel, interfaceSounds: sounds)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await speech.waitUntilStarted()
        await model.waitForInteractionToSettle()
        #expect(panel.state == (playing ? .speaking : .preparing))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(panel.level == (playing ? 0.65 : 0))
        #expect(sounds.cues.isEmpty)
        #expect(panel.origin == nil, "Later states never re-open from the frame.")
        if playing { #expect(sounds.isStopped) }
        panel.onStop?()
        await model.waitForInteractionToSettle()
        #expect(speech.stopped)
        #expect(sounds.isStopped)
        #expect(model.status == .stopped)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(panel.level == 0)
        #expect(panel.state == .stopped)
        speech.resume()
        await model.waitForSpeechToSettle()
        #expect(panel.state == .stopped)
    }

    @Test(arguments: ["complete", "empty", "failure"])
    func readingPanelReportsTerminalResultsWithoutRetainingContent(outcome: String) async {
        let selection = RegionSelectionControllerFake()
        let ocr = OCRFake()
        let speech = SpeechFake()
        if outcome == "empty" { ocr.result = OCRResult(lines: []) }
        speech.shouldFail = outcome == "failure"
        let panel = ReadingPanelFake()
        let sounds = InterfaceSoundsFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: ocr, speechService: speech, readingPanel: panel, interfaceSounds: sounds)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await model.waitForSpeechToSettle()
        let expected: ReadingPanelState = outcome == "empty" ? .noText : outcome == "failure" ? .failed : .finished
        #expect(panel.state == expected)
        #expect(panel.onStop == nil)
        #expect(sounds.cues == (outcome == "complete" ? [.completion] : [.attention]))
    }

    @Test
    func customShortcutPersistsAndConflictKeepsPreviousBinding() async {
        let store = MemoryShortcutStore()
        let hotkey = HotkeyManagerFake(registrationResult: .registered)
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store, hotkeyManager: hotkey)
        let custom = ShortcutConfiguration(key: "J", modifiers: UInt32(cmdKey | shiftKey))
        model.enqueueShortcutChange(custom)
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == custom)
        #expect(store.saved == custom)
        #expect(hotkey.registeredShortcut == custom.resolvedShortcut())
        hotkey.registrationResult = .conflict
        model.enqueueShortcutChange(.default)
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == custom)
        #expect(hotkey.registeredShortcut == custom.resolvedShortcut())
        #expect(model.hotkeyRegistration == .registered)
        #expect(store.saved == custom)
        #expect(model.shortcutNotice?.contains("already in use") == true)
        let restored = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store,
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered))
        #expect(restored.shortcutConfiguration == custom)
        hotkey.registrationResult = .registered
        model.enqueueShortcutChange(.default)
        await model.waitForInteractionToSettle()
        #expect(store.saved == .default)
    }

    @Test
    func recordedKeystrokesBecomeShortcutConfigurations() {
        let option = ShortcutConfiguration.recorded(character: "j", flags: [.option])
        #expect(option == ShortcutConfiguration(key: "J", modifiers: UInt32(optionKey)))
        #expect(option?.isValid == true)
        let all = ShortcutConfiguration.recorded(character: "7", flags: [.command, .shift, .control, .option, .capsLock])
        #expect(all == ShortcutConfiguration(key: "7", modifiers: UInt32(cmdKey | shiftKey | controlKey | optionKey)))
        #expect(ShortcutConfiguration.recorded(character: " ", flags: [.control])?.key == "Space")
        // Shift alone is recorded, so the field can explain why it is not enough.
        #expect(ShortcutConfiguration.recorded(character: "y", flags: [.shift])?.isValid == false)
        #expect(ShortcutConfiguration.recorded(character: "ß", flags: [.option]) == nil)
        #expect(ShortcutConfiguration.recorded(character: "\u{1b}", flags: [.command]) == nil)
    }

    @Test
    func recordingAShortcutSuspendsBothGlobalShortcuts() async {
        let hotkey = HotkeyManagerFake(registrationResult: .registered)
        let queue = HotkeyManagerFake(registrationResult: .registered)
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: hotkey,
                             queueHotkeyManager: queue, queueShortcutStore: MemoryShortcutStore())
        #expect(hotkey.registeredShortcut == ShortcutConfiguration.default.resolvedShortcut())
        model.setRecordingShortcut(true)
        #expect(hotkey.registeredShortcut == nil)
        #expect(queue.registeredShortcut == nil)
        model.setRecordingShortcut(false)
        #expect(hotkey.registeredShortcut == ShortcutConfiguration.default.resolvedShortcut())
        #expect(queue.registeredShortcut == ShortcutConfiguration.queueDefault.resolvedShortcut())
        model.setRecordingShortcut(true)
        let custom = ShortcutConfiguration(key: "J", modifiers: UInt32(optionKey))
        model.enqueueShortcutChange(custom)
        await model.waitForInteractionToSettle()
        model.setRecordingShortcut(false)
        #expect(hotkey.registeredShortcut == custom.resolvedShortcut())
    }

    @Test
    func shortcutCannotChangeDuringSelectionAndInvalidSettingsAreRejected() async {
        let store = MemoryShortcutStore()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store,
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: RegionSelectionControllerFake())
        model.enqueueShortcutChange(ShortcutConfiguration(key: "Y", modifiers: 0))
        await model.waitForInteractionToSettle()
        #expect(store.saved == nil)
        await model.handleReadRequest()
        model.enqueueShortcutChange(ShortcutConfiguration(key: "J", modifiers: UInt32(cmdKey | shiftKey)))
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == .default)
        #expect(store.saved == nil)
        #expect(model.status == .selecting)
        await model.handleReadRequest()
        #expect(model.status == .stopped)
    }

    @Test
    func shortcutSettingsValidateAndPersistOnlyConfiguration() throws {
        let suite = "com.christopherbobel.OpenScreenReader.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsShortcutStore(defaults: defaults)
        let custom = ShortcutConfiguration(key: "R", modifiers: UInt32(controlKey | optionKey))
        #expect(custom.displayName == "⌃⌥R")
        #expect(custom.isValid)
        #expect(!ShortcutConfiguration(key: "Escape", modifiers: UInt32(cmdKey)).isValid)
        #expect(!ShortcutConfiguration(key: "Y", modifiers: UInt32(shiftKey)).isValid)
        #expect(!ShortcutConfiguration(key: "Y", modifiers: UInt32(cmdKey) | 1).isValid)
        store.save(custom)
        #expect(store.load() == custom)
        #expect(defaults.persistentDomain(forName: suite)?.count == 1)
        defaults.set(Data("invalid".utf8), forKey: UserDefaultsShortcutStore.preferenceKey)
        #expect(store.load() == nil)
        defaults.set(try JSONEncoder().encode(ShortcutConfiguration(key: "Escape", modifiers: 0)),
                     forKey: UserDefaultsShortcutStore.preferenceKey)
        #expect(store.load() == nil)
    }

    @Test
    func realRegistrationPreservesOldBindingOnConflictAndReleasesItOnSuccess() {
        let manager = GlobalHotkeyManager()
        let competitor = GlobalHotkeyManager()
        let probe = GlobalHotkeyManager()
        defer { manager.unregister(); competitor.unregister(); probe.unregister() }
        let old = ShortcutConfiguration(key: "8", modifiers: UInt32(controlKey | optionKey | shiftKey)).resolvedShortcut()
        let new = ShortcutConfiguration(key: "9", modifiers: UInt32(controlKey | optionKey | shiftKey)).resolvedShortcut()
        #expect(manager.register(old) == .registered)
        #expect(manager.register(old) == .registered)
        #expect(competitor.register(new) == .registered)
        #expect(manager.register(new) == .conflict)
        #expect(probe.register(old) == .conflict)
        competitor.unregister()
        #expect(manager.register(new) == .registered)
        #expect(probe.register(old) == .registered)
    }

    @Test
    func sameShortcutRecoversAfterAnotherInstanceReleasesIt() async {
        let configuration = ShortcutConfiguration(key: "7", modifiers: UInt32(controlKey | optionKey | shiftKey))
        let competitor = GlobalHotkeyManager()
        let manager = GlobalHotkeyManager()
        defer { competitor.unregister(); manager.unregister() }
        #expect(competitor.register(configuration.resolvedShortcut()) == .registered)
        let store = MemoryShortcutStore()
        store.saved = configuration
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store, hotkeyManager: manager)
        #expect(model.hotkeyRegistration == .conflict)
        #expect(model.status == .error)
        #expect(model.errorMessage?.contains("Saywing or OpenScreenReader") == true)
        #expect(model.errorMessage?.contains("Settings › Shortcuts") == true)

        // Applying the same shortcut must retry; no preference reset or new key is needed.
        competitor.unregister()
        model.enqueueShortcutChange(configuration)
        await model.waitForInteractionToSettle()
        #expect(model.hotkeyRegistration == .registered)
        #expect(model.status == .ready)
        #expect(model.errorMessage == nil)
        #expect(store.saved == configuration)
    }

    @Test
    func changingShortcutRecoversFromStartupConflict() async {
        let hotkey = HotkeyManagerFake(registrationResult: .conflict)
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: hotkey)
        #expect(model.status == .error)
        hotkey.registrationResult = .registered
        model.enqueueShortcutChange(ShortcutConfiguration(key: "J", modifiers: UInt32(cmdKey | shiftKey)))
        await model.waitForInteractionToSettle()
        #expect(model.status == .ready)
        #expect(model.errorMessage == nil)
    }

    @Test
    func captureAutomaticallyReadsTextAndRetainsOnlyCountsAfterPlayback() async {
        let selection = RegionSelectionControllerFake()
        let ocr = OCRFake()
        let escape = EscapeFake()
        let speech = SpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: escape,
            ocrService: ocr, speechService: speech)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await model.waitForSpeechToSettle()
        #expect(ocr.calls == 1)
        #expect(speech.receivedText == "Hello world")
        #expect(model.status == .ready)
        #expect(model.lastOCRSummary == OCRSummary(characterCount: 11, lineCount: 1))
        #expect(model.captureFeedback?.contains("11 characters") == true)
        #expect(!escape.isActive)
        #expect(await model.pipelineCoordinator.snapshot().lastTerminal?.reason == .completed)
        await model.handleReadRequest()
        #expect(model.lastOCRSummary == nil)
    }

    @Test
    func menuShowsFeedbackOnlyWhenItAddsInformation() async {
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: RegionSelectionControllerFake())
        #expect(model.captureFeedback == nil, "The idle menu needs no instructions.")
        #expect(!model.isReadingActive)
        #expect(model.readActionTitle == "Read Screen Region…")
        await model.handleReadRequest()
        #expect(model.isReadingActive)
        #expect(model.captureFeedback == nil, "The status line already says Selecting.")
        #expect(model.readActionTitle == "Stop Reading")
        #expect(ShortcutConfiguration.default.keyboardShortcut == KeyboardShortcut("r", modifiers: [.option]))
        #expect(ShortcutConfiguration(key: "Space", modifiers: UInt32(cmdKey | shiftKey | controlKey)).keyboardShortcut
            == KeyboardShortcut(.space, modifiers: [.command, .shift, .control]))
    }

    @Test
    func blankOCRHasActionableFeedbackWithoutSpeech() async {
        let selection = RegionSelectionControllerFake()
        let ocr = OCRFake()
        let speech = SpeechFake()
        ocr.result = OCRResult(lines: [])
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: ocr, speechService: speech)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        #expect(model.status == .ready)
        #expect(speech.receivedText == nil)
        #expect(model.lastOCRSummary?.characterCount == 0)
        #expect(model.captureFeedback == "No readable text found. Select a clearer region.")
    }

    @Test(arguments: [false, true])
    func speechRemainsCancellableAndLateCompletionCannotAffectNewSelection(repeatedShortcut: Bool) async {
        let selection = RegionSelectionControllerFake()
        let escape = EscapeFake()
        let speech = SpeechFake()
        speech.suspend = true
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: escape,
            ocrService: OCRFake(), speechService: speech)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await speech.waitUntilStarted()
        await model.waitForInteractionToSettle()
        #expect(model.status == .speaking)
        #expect(escape.isActive)
        #expect(!model.canChangeShortcut)
        #expect(await model.pipelineCoordinator.snapshot().phase == .speaking)
        if repeatedShortcut { await model.handleReadRequest() }
        else { escape.onEscape?(); await model.waitForInteractionToSettle() }
        #expect(speech.stopped)
        #expect(model.status == .stopped)
        #expect(!escape.isActive)
        await model.handleReadRequest()
        speech.resume()
        await model.waitForSpeechToSettle()
        #expect(model.status == .selecting)
        #expect(model.lastOCRSummary == nil)
    }

    @Test
    func speechFailureIsGenericAndDoesNotFallBack() async {
        let selection = RegionSelectionControllerFake()
        let speech = SpeechFake()
        speech.shouldFail = true
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: OCRFake(), speechService: speech)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await model.waitForSpeechToSettle()
        #expect(model.status == .error)
        #expect(model.errorMessage == SpeechFailure.failed.localizedDescription)
        #expect(speech.stopped)
    }

    @Test
    func speechFailuresKeepTheirOwnMessageAndOnlyDamagedFilesLoseTryAgain() async {
        let selection = RegionSelectionControllerFake()
        let speech = SpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: OCRFake(), speechService: speech)
        for (failure, help) in [(SpeechFailure.loadFailed, AppModel.ErrorHelp.reinstall), (.outOfMemory, .retry), (.interrupted, .retry),
                                (.notInstalled, .reinstall), (.failed, .retry)] {
            speech.failure = failure
            await model.handleReadRequest()
            selection.complete(Self.ocrRegion)
            await model.waitForInteractionToSettle()
            await model.waitForCaptureToSettle()
            await model.waitForSpeechToSettle()
            #expect(model.status == .error)
            #expect(model.errorMessage == failure.localizedDescription)
            #expect(model.errorHelp == help)
        }
    }

    @Test
    func aFailedRunSaysThatItsWaitingTextsWereCleared() async throws {
        let f = QueueFixture()
        await f.model.handleReadRequest()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForCaptureToSettle()
        try await f.speech.waitForReads(1)
        f.ocr.result = OCRResult(lines: ["Danach"])
        f.model.enqueueAddRequest()
        await f.model.waitForInteractionToSettle()
        f.selection.complete(Self.ocrRegion)
        await f.model.waitForQueueInputToSettle()
        #expect(f.model.queuedTextCount == 1)
        f.speech.failFirst(.interrupted)
        await f.model.waitForSpeechToSettle()
        #expect(f.model.status == .error)
        #expect(f.model.queuedTextCount == 0)
        #expect(!f.model.canSkipText)
        #expect(f.model.errorMessage == "\(SpeechFailure.interrupted.localizedDescription) The waiting texts were cleared. Select them again to read them.")
        #expect(f.speech.texts.count == 1, "Nothing was read past the failure.")
    }

    /// Reads with the real service, session and player against scripted workers.
    private func modelWithScriptedWorkers(_ workers: ScriptedSpeechWorkers, selection: RegionSelectionControllerFake, ocr: OCRFake) -> (AppModel, LocalSpeechService) {
        let service = workers.service()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: ocr, speechService: service)
        return (model, service)
    }

    @Test
    func theQueueSurvivesACrashOnItsNextTextAndReadsItWithAFreshWorker() async throws {
        let addedSecondText = AsyncGate()
        let selection = RegionSelectionControllerFake(), ocr = OCRFake()
        let workers = ScriptedSpeechWorkers([
            .custom { worker in
                let first = try await worker.nextRequest()
                worker.ready(first)
                try await addedSecondText.wait()
                worker.audio(first)
                worker.end(first)
                let second = try await worker.nextRequest()
                worker.ready(second)
                worker.exit()
            },
            .completes(),
        ])
        let (model, service) = modelWithScriptedWorkers(workers, selection: selection, ocr: ocr)
        defer { service.stop() }
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForCaptureToSettle()
        try await workers.waitForLaunches(1)
        ocr.result = OCRResult(lines: ["Danach"])
        model.enqueueAddRequest()
        await model.waitForInteractionToSettle()
        selection.complete(Self.ocrRegion)
        await model.waitForQueueInputToSettle()
        #expect(model.queuedTextCount == 1)
        addedSecondText.open()
        for _ in 0..<2_500 where model.status != .ready && model.status != .error { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.status == .ready)
        #expect(model.errorMessage == nil)
        #expect(workers.launched.count == 2)
        #expect(workers.launched.last?.receivedTexts == ["Danach"])
    }

    @Test
    func stopDuringARetryClearsEverythingAndNoLatePacketPlays() async throws {
        let addedSecondText = AsyncGate(), retrying = AsyncGate()
        var retryID = ""
        let selection = RegionSelectionControllerFake(), ocr = OCRFake()
        let workers = ScriptedSpeechWorkers([
            .custom { worker in
                let first = try await worker.nextRequest()
                worker.ready(first)
                try await addedSecondText.wait()
                worker.exit()
            },
            .custom { worker in
                retryID = try await worker.nextRequest()
                worker.ready(retryID)
                retrying.open()
            },
        ])
        let (model, service) = modelWithScriptedWorkers(workers, selection: selection, ocr: ocr)
        defer { service.stop() }
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForCaptureToSettle()
        try await workers.waitForLaunches(1)
        ocr.result = OCRResult(lines: ["Danach"])
        model.enqueueAddRequest()
        await model.waitForInteractionToSettle()
        selection.complete(Self.ocrRegion)
        await model.waitForQueueInputToSettle()
        addedSecondText.open()
        try await retrying.wait()
        #expect(model.status == .synthesizing)
        model.enqueueStopRequest()
        await model.waitForInteractionToSettle()
        workers.launched[1].audio(retryID, bytes: 48_000)
        await model.waitForSpeechToSettle()
        await service.waitForProducerToSettle()
        #expect(model.status == .stopped)
        #expect(model.queuedTextCount == 0)
        #expect(workers.launched.count == 2)
        #expect(workers.launched[1].killed)
        #expect(service.workerPID == nil)
        #expect(service.playbackDiagnostics.frames == 0)
    }

    @Test(arguments: [false, true])
    func modelLoadingCanBeCancelledOrTimedOutWithoutWaitingForWorker(timeout: Bool) async {
        let selection = RegionSelectionControllerFake()
        let speech = SpeechFake()
        speech.suspend = true
        speech.emitPlayback = false
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
            ocrService: OCRFake(), speechService: speech,
            speechStartupTimeout: timeout ? .milliseconds(80) : .seconds(90))
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await speech.waitUntilStarted()
        #expect(model.status == .synthesizing)
        if timeout { await model.waitForTimeoutToSettle() }
        else { await model.handleReadRequest() }
        #expect(model.status == (timeout ? .error : .stopped))
        #expect(model.errorMessage == (timeout ? SpeechFailure.timedOut.localizedDescription : nil))
        #expect(speech.stopped)
        speech.resume()
        await model.waitForSpeechToSettle()
        #expect(model.status == (timeout ? .error : .stopped))
    }

    @Test(arguments: [false, true])
    func cancelledOCRCannotPublishIntoNewSelection(repeatedShortcut: Bool) async {
        let selection = RegionSelectionControllerFake()
        let ocr = OCRFake()
        ocr.suspend = true
        let escape = EscapeFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: escape,
            ocrService: ocr)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await ocr.waitUntilStarted()
        #expect(model.status == .recognizing)
        #expect(escape.isActive)
        model.enqueueShortcutChange(ShortcutConfiguration(key: "J", modifiers: UInt32(cmdKey | shiftKey)))
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == .default)
        #expect(!model.canChangeShortcut)
        if repeatedShortcut { await model.handleReadRequest() }
        else { escape.onEscape?(); await model.waitForInteractionToSettle() }
        #expect(model.status == .stopped)
        #expect(!escape.isActive)
        await model.handleReadRequest()
        ocr.resume()
        await model.waitForCaptureToSettle()
        #expect(model.status == .selecting)
        #expect(model.lastOCRSummary == nil)
        #expect(model.lastCaptureSize == nil)
    }

    @Test
    func recognitionFailureDoesNotExposeUnderlyingPayload() async {
        let selection = RegionSelectionControllerFake()
        let ocr = OCRFake()
        ocr.shouldFail = true
        let escape = EscapeFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: escape,
            ocrService: ocr)
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        #expect(model.status == .error)
        #expect(model.errorMessage == OCRFailure.recognitionFailed.localizedDescription)
        #expect(model.lastOCRSummary == nil)
        #expect(!escape.isActive)
    }

    private static var ocrRegion: ScreenRegionSelection {
        ScreenRegionSelection(displayID: 1,
            rectInScreenPoints: CGRect(x: 0, y: 0, width: 20, height: 20),
            rectInBackingPixels: CGRect(x: 0, y: 0, width: 20, height: 20), backingScaleFactor: 1)
    }

    @Test(arguments: [false, true])
    func interruptedOCRFailsClosedAndRejectsLateText(timeout: Bool) async {
        let selection = RegionSelectionControllerFake()
        let ocr = OCRFake()
        ocr.suspend = true
        let escape = EscapeFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: escape,
            ocrService: ocr, operationTimeout: timeout ? .milliseconds(100) : .seconds(15))
        await model.handleReadRequest()
        selection.complete(Self.ocrRegion)
        await model.waitForInteractionToSettle()
        await ocr.waitUntilStarted()
        if timeout { await model.waitForTimeoutToSettle() }
        else { escape.onUnavailable?(); await model.waitForInteractionToSettle() }
        #expect(model.status == .error)
        #expect(!escape.isActive)
        #expect(model.lastOCRSummary == nil)
        #expect(await model.pipelineCoordinator.snapshot().activeContext == nil)
        ocr.resume()
        await model.waitForCaptureToSettle()
        #expect(model.status == .error)
        #expect(model.lastOCRSummary == nil)
    }

    @Test
    func defaultShortcutIsExplicitAndReadable() {
        #expect(HotkeyShortcut.readScreenRegion.carbonModifiers == UInt32(optionKey))
        #expect(HotkeyShortcut.readScreenRegion.displayName == "⌥R")
    }

    @Test(arguments: [("com.apple.keylayout.German", UInt32(kVK_ANSI_Z)),
                      ("com.apple.keylayout.US", UInt32(kVK_ANSI_Y))])
    func shortcutResolvesYForGermanAndUSLayouts(layout: (String, UInt32)) throws {
        let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceID: layout.0] as CFDictionary, true
        ).takeRetainedValue()
        #expect(CFArrayGetCount(sources) > 0)
        guard CFArrayGetCount(sources) > 0 else { return }
        let source = Unmanaged<TISInputSource>.fromOpaque(CFArrayGetValueAtIndex(sources, 0)).takeUnretainedValue()
        #expect(HotkeyShortcut.keyCode(for: "Y", modifiers: UInt32(cmdKey | shiftKey), source: source) == layout.1)
        #expect(HotkeyShortcut.keyCode(for: "🦉", modifiers: UInt32(cmdKey | shiftKey), source: source) == nil)
        #expect(ShortcutConfiguration(key: "Y", modifiers: UInt32(controlKey | optionKey))
            .resolvedShortcut(source: source).keyCode == layout.1)
        #expect(ShortcutConfiguration(key: "1", modifiers: UInt32(cmdKey | shiftKey))
            .resolvedShortcut(source: source).keyCode == UInt32(kVK_ANSI_1))
    }

    @Test
    func missingLayoutKeyCannotRegisterAnUnrelatedFallback() {
        let manager = GlobalHotkeyManager()
        #expect(manager.register(HotkeyShortcut(keyCode: nil,
            carbonModifiers: UInt32(cmdKey | shiftKey), displayName: "⌘⇧Y")) == .failed(OSStatus(paramErr)))
    }

    @Test
    func appRegistersTheHotkeyAndStartsSelection() async {
        let hotkey = HotkeyManagerFake(registrationResult: .registered)
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: hotkey, selectionController: selection,
                             captureService: CaptureFake(), escapeMonitor: EscapeFake())

        #expect(hotkey.registeredShortcut == .readScreenRegion)
        #expect(model.hotkeyRegistration == .registered)

        await model.handleReadRequest()

        #expect(model.status == .selecting)
        #expect(selection.startCount == 1)
        #expect(selection.cancelCount == 0)
    }

    @Test
    func repeatedReadRequestCancelsTheActiveSelection() async {
        let hotkey = HotkeyManagerFake(registrationResult: .registered)
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: hotkey, selectionController: selection,
                             captureService: CaptureFake(), escapeMonitor: EscapeFake())

        await model.handleReadRequest()
        await model.handleReadRequest()

        let snapshot = await model.pipelineCoordinator.snapshot()
        #expect(model.status == .stopped)
        #expect(selection.cancelCount == 1)
        #expect(snapshot.activeContext == nil)
        #expect(snapshot.pendingCancellation == nil)
    }

    @Test
    func completedSelectionIsPublishedWithoutPersistingPixels() async {
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: .acceptedForTesting(),
            shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake()
        )
        let region = ScreenRegionSelection(
            displayID: 7,
            rectInScreenPoints: CGRect(x: 100, y: 80, width: 400, height: 220),
            rectInBackingPixels: CGRect(x: 200, y: 160, width: 800, height: 440),
            backingScaleFactor: 2
        )

        await model.handleReadRequest()
        selection.complete(region)
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()

        let snapshot = await model.pipelineCoordinator.snapshot()
        #expect(model.lastSelection == region)
        #expect(model.status == .ready)
        #expect(snapshot.activeContext == nil)
        #expect(snapshot.lastTerminal?.reason == .completed)
    }

    @Test
    func registrationConflictIsVisibleAndPreventsSelection() async {
        let hotkey = HotkeyManagerFake(registrationResult: .conflict)
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: hotkey, selectionController: selection)

        await model.handleReadRequest()

        #expect(model.hotkeyRegistration == .conflict)
        #expect(model.status == .error)
        #expect(model.errorMessage == "The shortcut ⌥R is already in use. Quit any other Saywing or OpenScreenReader copy, then choose it again under Settings › Shortcuts, or record a different one.")
        #expect(selection.startCount == 0)
    }

    @Test
    func cancelledCaptureCannotPublishIntoANewerSelection() async throws {
        let selection = RegionSelectionControllerFake()
        let capture = CaptureFake()
        capture.suspend = true
        let escape = EscapeFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, captureService: capture, escapeMonitor: escape)
        await model.handleReadRequest()
        let region = ScreenRegionSelection(displayID: 1,
            rectInScreenPoints: CGRect(x: 0, y: 0, width: 20, height: 20),
            rectInBackingPixels: CGRect(x: 0, y: 0, width: 20, height: 20), backingScaleFactor: 1)
        selection.complete(region)
        await model.waitForInteractionToSettle()
        await capture.waitUntilStarted()
        #expect(model.status == .capturing)
        escape.onEscape?()
        await model.waitForInteractionToSettle()
        #expect(model.status == .stopped)
        #expect(!escape.isActive)
        await model.handleReadRequest()
        capture.resume()
        await model.waitForCaptureToSettle()
        #expect(model.status == .selecting)
        #expect(model.lastCaptureSize == nil)
    }

    @Test
    func missingEscapeAccessPreventsCaptureAndExplainsRemediation() async {
        let selection = RegionSelectionControllerFake()
        let capture = CaptureFake()
        let escape = EscapeFake()
        escape.shouldFail = true
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, captureService: capture, escapeMonitor: escape)
        await model.handleReadRequest()
        selection.complete(ScreenRegionSelection(displayID: 1,
            rectInScreenPoints: CGRect(x: 0, y: 0, width: 20, height: 20),
            rectInBackingPixels: CGRect(x: 0, y: 0, width: 20, height: 20), backingScaleFactor: 1))
        await model.waitForInteractionToSettle()
        #expect(model.status == .error)
        #expect(model.errorMessage?.contains("Input Monitoring") == true)
        #expect(capture.calls == 0)
        #expect(!escape.isActive)
    }

    @Test
    func rapidReadRequestsAreProcessedInOrder() async {
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: RegionSelectionControllerFake(),
                             captureService: CaptureFake(), escapeMonitor: EscapeFake())
        for _ in 0..<100 { model.enqueueReadRequest() }
        await model.waitForInteractionToSettle()
        let snapshot = await model.pipelineCoordinator.snapshot()
        #expect(model.status == .stopped)
        #expect(snapshot.activeContext == nil)
        #expect(snapshot.pendingCancellation == nil)
    }

    @Test
    func selectionGestureFollowsScreenshotModifiers() {
        var gesture = SelectionGesture(start: CGPoint(x: 100, y: 100))
        gesture.move(to: CGPoint(x: 160, y: 140))
        #expect(gesture.rect == CGRect(x: 100, y: 100, width: 60, height: 40))
        // Space moves the whole selection with the pointer.
        gesture.setMoving(true)
        gesture.move(to: CGPoint(x: 180, y: 150))
        #expect(gesture.rect == CGRect(x: 120, y: 110, width: 60, height: 40))
        gesture.setMoving(false)
        gesture.move(to: CGPoint(x: 200, y: 170))
        #expect(gesture.rect == CGRect(x: 120, y: 110, width: 80, height: 60))
        // Option grows the selection from its starting point as the centre.
        gesture.setModifiers(option: true, shift: false)
        #expect(gesture.rect == CGRect(x: 40, y: 50, width: 160, height: 120))
        gesture.setModifiers(option: false, shift: false)
        // Shift locks the edge that did not move first.
        gesture.setModifiers(option: false, shift: true)
        gesture.move(to: CGPoint(x: 230, y: 172))
        gesture.move(to: CGPoint(x: 240, y: 230))
        #expect(gesture.rect == CGRect(x: 120, y: 110, width: 120, height: 60))
        gesture.setModifiers(option: false, shift: false)
        #expect(gesture.rect == CGRect(x: 120, y: 110, width: 120, height: 120))
        // A vertical first movement locks the width instead.
        var vertical = SelectionGesture(start: .zero)
        vertical.move(to: CGPoint(x: 50, y: 50))
        vertical.setModifiers(option: false, shift: true)
        vertical.move(to: CGPoint(x: 51, y: 90))
        vertical.move(to: CGPoint(x: 120, y: 95))
        #expect(vertical.rect == CGRect(x: 0, y: 0, width: 50, height: 95))
    }

    @Test
    func clickSelectsABoundedAreaAroundThePointer() throws {
        let geometry = DisplaySelectionGeometry(displayID: 4,
            frameInScreenPoints: CGRect(x: -1440, y: 100, width: 1440, height: 900), backingScaleFactor: 2)
        let centred = try #require(geometry.clickSelection(at: CGPoint(x: 720, y: 450)))
        #expect(centred.rectInScreenPoints == CGRect(x: -1440 + 120, y: 150, width: 1200, height: 800))
        #expect(centred.focus == CGPoint(x: 0.5, y: 0.5))
        let corner = try #require(geometry.clickSelection(at: CGPoint(x: 30, y: 880)))
        #expect(corner.rectInScreenPoints == CGRect(x: -1440, y: 200, width: 1200, height: 800))
        #expect(corner.focus == CGPoint(x: 30.0 / 1200, y: 780.0 / 800))
        #expect(corner.rectInBackingPixels.size == CGSize(width: 2400, height: 1600))
        // The control flies from the clicked spot, not from the larger recognition area.
        let flight = corner.flightOrigin
        #expect(flight.midX == -1410 && flight.midY == 980 && flight.width < 60)
        let dragged = try #require(geometry.selection(in: CGRect(x: 10, y: 10, width: 100, height: 50)))
        #expect(dragged.focus == nil && dragged.flightOrigin == dragged.rectInScreenPoints)
        let text = OCRResult(lines: ["A", "B"], boxes: [CGRect(x: 0, y: 0.6, width: 0.2, height: 0.03),
                                                        CGRect(x: 0, y: 0.1, width: 0.2, height: 0.03)])
        #expect(corner.focusedText(text).lines.isEmpty, "A click far from any text reads nothing.")
        #expect(dragged.focusedText(text) == text, "A dragged region is read completely.")
    }

    @Test
    func selectionHintAppearsForTheFirstFewSelectionsOnly() throws {
        let suite = "com.christopherbobel.OpenScreenReader.hint-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var shown = 0
        for _ in 0..<8 where SelectionHint.consume(defaults) { shown += 1 }
        #expect(shown == SelectionHint.limit)
        #expect(SelectionHint.limit == 5)
    }

    @Test
    func selectionGeometryHandlesNegativeDisplayOriginsAndRetinaScale() throws {
        let geometry = DisplaySelectionGeometry(
            displayID: 9,
            frameInScreenPoints: CGRect(x: -1440, y: 100, width: 1440, height: 900),
            backingScaleFactor: 2
        )

        let selection = try #require(
            geometry.selection(
                from: CGPoint(x: 500, y: 350),
                to: CGPoint(x: 100, y: 200)
            )
        )

        #expect(selection.displayID == 9)
        #expect(selection.rectInScreenPoints == CGRect(x: -1340, y: 300, width: 400, height: 150))
        #expect(selection.rectInBackingPixels == CGRect(x: 200, y: 400, width: 800, height: 300))
        #expect(selection.backingScaleFactor == 2)
    }

    @Test
    func selectionGeometryClipsToItsStartDisplayAndRejectsZeroArea() {
        let geometry = DisplaySelectionGeometry(
            displayID: 3,
            frameInScreenPoints: CGRect(x: 0, y: 0, width: 1000, height: 700),
            backingScaleFactor: 1
        )

        let clipped = geometry.selection(
            from: CGPoint(x: 900, y: 600),
            to: CGPoint(x: 1200, y: 900)
        )

        #expect(clipped?.rectInScreenPoints == CGRect(x: 900, y: 600, width: 100, height: 100))
        #expect(geometry.selection(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11)) == nil)
    }

    /// A missing grant opens its setup step instead of letting the user drag a
    /// region that can only fail afterwards. Nothing is requested automatically.
    @Test
    func missingReadingPermissionOpensSetupBeforeSelection() async throws {
        let suite = "com.christopherbobel.OpenScreenReader.setup-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let selection = RegionSelectionControllerFake()
        final class Grants { var missing: SaywingPermission? = .screenRecording }
        let grants = Grants()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
                             ocrService: OCRFake(), speechService: SpeechFake(), preferences: preferences,
                             missingReadingPermission: { grants.missing })
        defer { model.closeSetup() }
        model.enqueuePrimaryShortcut()
        await model.waitForInteractionToSettle()
        #expect(selection.startCount == 0)
        #expect(model.isSetupOpen)
        #expect(model.status == .ready)
        #expect(!preferences.bool(forKey: "setupDismissed.v1"))
        grants.missing = nil
        model.enqueueReadRequest()
        await model.waitForInteractionToSettle()
        #expect(selection.startCount == 1)
    }
}

/// Follow-ups from the Apple design review: help at the source of an error,
/// dictation feedback where the text goes, and status in the menu bar.
@Suite("Feedback at its source", .serialized)
@MainActor
struct FeedbackAtSourceTests {
    /// The question mark explains the failure in place; setup only when a grant is missing.
    @Test func errorHelpExplainsInPlaceAndOffersSetupOnlyForMissingGrants() throws {
        final class Grants { var missing: SaywingPermission? }
        let grants = Grants()
        let suite = "com.christopherbobel.OpenScreenReader.error-help-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .conflict),
                             preferences: preferences, missingReadingPermission: { grants.missing })
        defer { model.closeSetup(); model.closeErrorHelp() }
        #expect(model.status == .error)
        // A taken shortcut is fixed in Settings, not by trying again.
        #expect(model.errorHelp == .shortcut)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 80, y: 20, width: 40, height: 40))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        model.showPlaybackControls(from: anchor)
        #expect(model.isShowingErrorHelp)
        #expect(!model.isSetupOpen)
        grants.missing = .inputMonitoring
        #expect(model.errorHelp == .allow(.inputMonitoring))
        let working = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                               preferences: preferences)
        #expect(working.errorHelp == .retry)
    }

    @Test func dictationCapsuleAppearsBelowTheCaretAndFallsBackToTheReadingPlace() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let docked = CGRect(x: 570, y: 4, width: 300, height: 92)
        let size = DictationCapsuleView.surface
        // Below the insertion point, centred on it.
        let caret = CGRect(x: 600, y: 500, width: 2, height: 18)
        let below = DictationCapsulePlacement.origin(caret: caret, visible: visible, docked: docked, size: size)
        #expect(below.y + size.height <= caret.minY)
        #expect(abs(below.x + size.width / 2 - caret.midX) < 1)
        // Above it when there is no room below, and always on screen.
        let low = DictationCapsulePlacement.origin(caret: CGRect(x: 1435, y: 20, width: 2, height: 18), visible: visible, docked: docked, size: size)
        #expect(low.y >= 38)
        #expect(low.x + size.width <= visible.maxX)
        // Without a caret, the same place the reading control was docked.
        let fallback = DictationCapsulePlacement.origin(caret: nil, visible: visible, docked: docked, size: size)
        #expect(abs(fallback.x + size.width / 2 - docked.midX) < 1)
        #expect(abs(fallback.y + size.height / 2 - docked.midY) < 1)
        let offscreen = DictationCapsulePlacement.origin(caret: CGRect(x: 5000, y: 5000, width: 2, height: 18), visible: visible, docked: docked, size: size)
        #expect(offscreen == fallback)
    }

    @Test func testFieldCaretIsInScreenCoordinates() {
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        window.contentView?.addSubview(field)
        field.string = "Hallo"
        field.setSelectedRange(NSRange(location: 5, length: 0))
        let caret = InsertionTarget(local: field).caretRect()
        #expect(caret.map { window.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.midX, y: $0.midY)) } == true)
    }

    /// Dictation uses the reading cues, at the same moment as its visible result.
    /// Status updates while the microphone records never add one; only the
    /// microphone's own moments do (see the recording cue tests).
    @Test func dictationCuesMatchItsVisibleResult() {
        let sounds = InterfaceSoundsFake()
        let controller = DictationController(resources: URL(fileURLWithPath: "/missing-dictation"), worker: DictationWorkerFake(),
            shortcut: HotkeyManagerFake(registrationResult: .registered), escape: HotkeyManagerFake(registrationResult: .registered),
            registerHotkey: false, interfaceSounds: sounds)
        defer { controller.shutdown() }
        controller.setStatus("Pasted", floating: true, capsuleState: .inserted)
        controller.setStatus("Paste sent", floating: true, capsuleState: .unconfirmed)
        controller.setStatus("Target changed", floating: true)
        controller.setStatus("Ready", floating: false)
        controller.phase = "recording"
        controller.setStatus("Recording · 0 s", floating: true)
        controller.setStatus("Notice", floating: true, capsuleState: .attention)
        #expect(sounds.cues == [.completion, .attention, .attention])
        controller.panel.orderOut(nil)
    }

    private func soundingDictation(schedulePasteCallback: @escaping (Double, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) -> (DictationController, InterfaceSoundsFake, RecorderFake, DictationWorkerFake) {
        let sounds = InterfaceSoundsFake()
        let worker = DictationWorkerFake()
        let controller = DictationController(resources: URL(fileURLWithPath: "/missing-dictation"), worker: worker,
            shortcut: HotkeyManagerFake(registrationResult: .registered), escape: HotkeyManagerFake(registrationResult: .registered),
            registerHotkey: false, interfaceSounds: sounds, schedulePasteCallback: schedulePasteCallback)
        let recorder = RecorderFake()
        recorder.onFinish = { [weak sounds] in recorder.cuesAtFinish = sounds?.cues }
        controller.makeRecorder = { recorder }
        return (controller, sounds, recorder, worker)
    }

    /// Holding Fn opens with one short cue; latching adds the latch cue once and
    /// shows on the finish control; closing sounds only after the microphone is closed.
    @Test func heldRecordingOpensLatchesAndClosesWithItsOwnCues() throws {
        let (controller, sounds, recorder, _) = soundingDictation()
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        controller.startRecording(target: InsertionTarget(local: controller.scratch), handsFree: false)
        #expect(controller.phase == "recording")
        #expect(sounds.cues == [.listening])
        #expect(!controller.capsule.isHandsFree)
        #expect(!controller.capsule.finishButton.isEmphasized)
        #expect(controller.handle(.lock))
        #expect(sounds.cues == [.listening, .handsFree])
        #expect(controller.capsule.isHandsFree)
        #expect(controller.capsule.finishButton.isEmphasized)
        #expect(controller.handle(.lock))
        #expect(sounds.cues == [.listening, .handsFree], "A repeated latch is not a new event.")
        #expect(controller.handle(.finish))
        #expect(recorder.events == ["start", "finish"])
        #expect(recorder.cuesAtFinish == [.listening, .handsFree], "The closing cue is never recorded.")
        #expect(sounds.cues == [.listening, .handsFree, .captured])
        #expect(controller.phase == "processing")
        #expect(!controller.capsule.isHandsFree, "Recognition no longer shows the latch.")
        controller.cancel(restart: false)
    }

    /// The shortcut and the Record button start hands-free: one latch cue, never two
    /// stacked cues. Discarding is silent and cuts a cue that is still sounding.
    @Test func handsFreeStartUsesOneCueAndDiscardingIsSilent() throws {
        let (controller, sounds, recorder, _) = soundingDictation()
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        controller.startRecording(target: InsertionTarget(local: controller.scratch))
        #expect(sounds.cues == [.handsFree])
        #expect(controller.capsule.isHandsFree)
        #expect(!sounds.isStopped)
        #expect(controller.handle(.cancel))
        #expect(sounds.cues == [.handsFree])
        #expect(sounds.isStopped)
        #expect(recorder.events == ["start", "cancel"])
        #expect(controller.phase != "recording")
    }

    /// A field that shows the text right away gets its tick and completion cue with
    /// the text; the clipboard is still restored only after the full wait.
    @Test func confirmedPasteSoundsWithTheTextNotAfterTheClipboardWait() async throws {
        var scheduled: [(Double, DispatchWorkItem)] = []
        let (controller, sounds, _, worker) = soundingDictation(schedulePasteCallback: { scheduled.append(($0, $1)) })
        defer { scheduled.forEach { $0.1.cancel() } }
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        controller.scratch.string = "Anfang MARKER Ende"
        controller.scratch.setSelectedRange((controller.scratch.string as NSString).range(of: "MARKER"))
        controller.window.makeFirstResponder(controller.scratch)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let id = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        controller.receive(.init(type: "result", id: id.uuidString, text: "Diktat"))
        #expect(controller.phase == "pasting")
        #expect(controller.scratch.string == "Anfang Diktat Ende")
        #expect(sounds.cues.isEmpty)
        #expect(scheduled.map { $0.0 } == [0.15, 1.0])
        let earlyConfirmation = try #require(scheduled.first?.1)
        let restoreClipboard = try #require(scheduled.last?.1)
        earlyConfirmation.perform()
        #expect(controller.phase == "pasting", "The clipboard is still held for slow apps.")
        #expect(controller.capsule.state == .inserted)
        #expect(sounds.cues == [.completion])
        restoreClipboard.perform()
        earlyConfirmation.cancel()
        restoreClipboard.cancel()
        #expect(controller.phase == "ready")
        #expect(controller.capsule.state == .inserted)
        #expect(sounds.cues == [.completion], "The result sounds once.")
        #expect(controller.resultSection.isHidden)
    }

    /// Escape after Cmd+V was sent, before the field showed the text: a slow app may
    /// still read the clipboard, so the earlier clipboard returns only after the wait.
    @Test func discardingASentPasteKeepsTheClipboardUntilTheScheduledRestore() throws {
        var scheduled: [(Double, DispatchWorkItem)] = []
        let (controller, _, _, worker) = soundingDictation(schedulePasteCallback: { scheduled.append(($0, $1)) })
        defer { scheduled.forEach { $0.1.cancel() } }
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        let board = NSPasteboard.general
        let previous = try? ClipboardSnapshot.capture(board)
        defer { if let previous { _ = previous.write(to: board) } }
        board.clearContents()
        board.setString("Vorherige Zwischenablage", forType: .string)
        controller.scratch.string = "Anfang MARKER Ende"
        controller.scratch.setSelectedRange((controller.scratch.string as NSString).range(of: "MARKER"))
        controller.window.makeFirstResponder(controller.scratch)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let id = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        controller.receive(.init(type: "result", id: id.uuidString, text: "Diktat"))
        #expect(controller.phase == "pasting")
        controller.cancel()
        #expect(!controller.isActive)
        #expect(board.string(forType: .string) == "Diktat", "Restoring now could paste the previous clipboard.")
        let restoreClipboard = try #require(scheduled.last?.1)
        restoreClipboard.perform()
        #expect(board.string(forType: .string) == "Vorherige Zwischenablage")
        #expect(controller.deferredLease == nil)
    }

    /// Once the field showed the text, nothing is pending: discarding restores at once.
    @Test func discardingAConfirmedPasteRestoresTheClipboardAtOnce() throws {
        var scheduled: [(Double, DispatchWorkItem)] = []
        let (controller, _, _, worker) = soundingDictation(schedulePasteCallback: { scheduled.append(($0, $1)) })
        defer { scheduled.forEach { $0.1.cancel() } }
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        let board = NSPasteboard.general
        let previous = try? ClipboardSnapshot.capture(board)
        defer { if let previous { _ = previous.write(to: board) } }
        board.clearContents()
        board.setString("Vorherige Zwischenablage", forType: .string)
        controller.scratch.string = "Anfang MARKER Ende"
        controller.scratch.setSelectedRange((controller.scratch.string as NSString).range(of: "MARKER"))
        controller.window.makeFirstResponder(controller.scratch)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let id = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        controller.receive(.init(type: "result", id: id.uuidString, text: "Diktat"))
        let earlyConfirmation = try #require(scheduled.first?.1)
        earlyConfirmation.perform()
        controller.cancel()
        #expect(board.string(forType: .string) == "Vorherige Zwischenablage")
        #expect(controller.deferredLease == nil)
    }

    @Test func inputDeviceChangeWhileRecordingDiscardsInsteadOfPasting() throws {
        let (controller, _, recorder, worker) = soundingDictation()
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        worker.ready = true
        controller.startRecording(target: InsertionTarget(local: controller.scratch))
        #expect(controller.phase == "recording")
        let interruption = try #require(recorder.onInterruption)
        interruption()
        #expect(!controller.isActive)
        #expect(recorder.events == ["start", "cancel"])
        #expect(worker.requests.isEmpty)
        #expect(controller.statusText == String(localized: "Recording stopped"))
        #expect(controller.detailLabel.stringValue == DictationError.inputDeviceChanged.localizedDescription)
        interruption()
        #expect(recorder.events == ["start", "cancel"], "A late notice for an ended recording does nothing.")
    }

    @Test func interruptedRecordingIsNeverSentWhenFinishRacesTheNotice() throws {
        let (controller, _, recorder, worker) = soundingDictation()
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        worker.ready = true
        controller.startRecording(target: InsertionTarget(local: controller.scratch))
        recorder.finishFailure = DictationError.inputDeviceChanged
        controller.finishRecording()
        #expect(!controller.isActive)
        #expect(worker.requests.isEmpty)
        #expect(controller.statusText == String(localized: "Recording stopped"))
    }

    @Test func microphoneRecorderMarksAnEngineChangeAndRefusesTheTruncatedAudio() async throws {
        let recorder = MicrophoneRecorder()
        let engine = ConfigurationSource()
        var notified = false
        recorder.onInterruption = { notified = true }
        recorder.audio.start(sampleRate: 48000)
        recorder.observeConfigurationChanges(of: engine)
        #expect(!recorder.wasInterrupted)
        let posted = Task.detached { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine) }
        await posted.value
        #expect(recorder.wasInterrupted, "Marked on the posting thread, before the main actor hears of it.")
        for _ in 0..<100 where !notified { await Task.yield() }
        #expect(notified)
        #expect(throws: DictationError.self) { _ = try recorder.finish() }
    }

    @Test func handsFreeShowsOnlyOnTheFinishControlWhileRecording() {
        let capsule = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        capsule.setHandsFree(true)
        #expect(!capsule.isHandsFree, "Only a recording can latch.")
        capsule.present(.recording, title: "", detail: "")
        capsule.setHandsFree(true)
        #expect(capsule.isHandsFree)
        #expect(capsule.finishButton.isEmphasized)
        #expect(!capsule.dismissButton.isEmphasized)
        #expect(capsule.accessibilityLabel()?.contains(String(localized: "Recording hands-free")) == true)
        #expect(capsule.barHeights.count == 9, "No text, timer or extra indicator is added.")
        capsule.present(.processing, title: "", detail: "")
        #expect(!capsule.isHandsFree)
        #expect(!capsule.finishButton.isEmphasized)
    }

    /// The window shows the result only when it could not be pasted.
    @Test func dictationResultAppearsOnlyWhenNotPasted() throws {
        let worker = DictationWorkerFake()
        let controller = DictationController(resources: URL(fileURLWithPath: "/missing-dictation"), worker: worker,
            shortcut: HotkeyManagerFake(registrationResult: .registered), escape: HotkeyManagerFake(registrationResult: .registered),
            registerHotkey: false)
        defer { controller.shutdown(); controller.panel.orderOut(nil) }
        #expect(controller.resultSection.isHidden)
        controller.window.makeFirstResponder(controller.scratch)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let id = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        controller.scratch.string = "Edited meanwhile"
        controller.receive(.init(type: "result", id: id.uuidString, text: "Kept result"))
        #expect(!controller.resultSection.isHidden)
        #expect(controller.result.string == "Kept result")
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        #expect(controller.resultSection.isHidden)
        controller.cancel(restart: false)
    }

    @Test func menuBarIconShowsReadingAndAttentionByShape() throws {
        let idle = MenuBarIcon.image(for: .idle)
        let reading = MenuBarIcon.image(for: .reading)
        let attention = MenuBarIcon.image(for: .attention)
        let recording = MenuBarIcon.image(for: .recording)
        for image in [idle, reading, attention, recording] { #expect(image.isTemplate) }
        let pngs = try [idle, reading, attention, recording].map { image in
            let tiff = try #require(image.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        }
        #expect(Set(pngs).count == 4)
        #expect(MenuBarIcon.image(for: .reading) === reading, "Images are cached, not redrawn per update")
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .conflict))
        #expect(model.menuBarIndicator == .attention)
    }
}

@Suite("Reading status presentation", .serialized)
@MainActor
struct ReadingPanelTests {
    @Test
    func hoverControlsSeparateClicksFromDraggingAndRejectCancelledPresses() throws {
        let window = ReadingStatusPanel()
        window.setFrame(CGRect(x: 100, y: 100, width: 300, height: 92), display: false)
        let view = ReadingControlView(frame: CGRect(x: 0, y: 0, width: 300, height: 92))
        window.contentView = view
        defer { view.stopAnimating(); window.close() }
        var pauses = 0, opens = 0, drags = 0, stops = 0
        view.onTogglePause = { [weak view] in pauses += 1; view?.setPaused(pauses % 2 == 1) }
        view.onOpenControls = { _ in opens += 1 }
        view.onDragMove = { _ in drags += 1 }
        view.present(.speaking, opening: false, action: { stops += 1 })
        let children = view.subviews.flatMap(\.subviews)
        let pause = try #require(children.first { $0.accessibilityIdentifier() == "readingPauseAction" } as? NSButton)
        let options = try #require(children.first { $0.accessibilityIdentifier() == "readingQueueCount" } as? NSButton)
        pause.superview?.mouseEntered(with: NSEvent())
        for index in 0..<240 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        func send(_ control: NSButton, drag: Bool, cancel: Bool = false) throws {
            let start = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0.5))
            }
            control.mouseDown(with: try event(.leftMouseDown, start))
            let end = CGPoint(x: start.x + (drag ? 12 : 2), y: start.y)
            control.mouseDragged(with: try event(.leftMouseDragged, end))
            if cancel { view.retract() }
            control.mouseUp(with: try event(.leftMouseUp, end))
        }
        try send(pause, drag: false)
        #expect(pauses == 1 && pause.title == "resume")
        try send(pause, drag: true)
        #expect(pauses == 1 && drags == 1)
        try send(options, drag: true)
        #expect(opens == 0 && drags == 2)
        try send(options, drag: false)
        #expect(opens == 1 && stops == 0)
        try send(pause, drag: false, cancel: true)
        #expect(pauses == 1)
        #expect(view.accessibilityCustomActions()?.isEmpty == true)
    }

    @Test
    func popoverAndAccessibilityKeepControlsReachableWithoutHover() throws {
        let view = ReadingControlView(frame: CGRect(origin: .zero, size: ReadingControlView.Metrics.surface))
        defer { view.stopAnimating() }
        var opens = 0, pauses = 0
        view.onOpenControls = { _ in opens += 1 }
        view.onTogglePause = { pauses += 1 }
        view.present(.speaking, opening: false, action: {})
        for index in 0..<240 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        let actions = try #require(view.accessibilityCustomActions())
        #expect(actions.first?.handler?() == true)
        #expect(actions.last?.handler?() == true)
        #expect(opens == 1 && pauses == 1)
        let options = try #require(view.subviews.flatMap(\.subviews).first { $0.accessibilityIdentifier() == "readingQueueCount" })
        let popover = NSPopover()
        view.holdControls(for: popover)
        #expect(options.alphaValue > 0.99, "Keyboard/VoiceOver opening synchronously reveals the popover anchor.")
        for index in 0..<240 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        #expect(options.alphaValue > 0.99)
        view.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        for index in 0..<240 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        #expect(options.alphaValue < 0.01)
        view.present(.preparing, opening: false, action: {})
        #expect(view.accessibilityCustomActions()?.count == 1)
        view.retract()
        #expect(actions.last?.handler?() == false, "A retained accessibility action cannot pause after Stop.")
    }

    @Test
    func controlsPopoverOpensTowardDesktopAtEachDockEdge() {
        #expect(ReadingPanelEdge.bottom.popoverEdge == .maxY)
        #expect(ReadingPanelEdge.left.popoverEdge == .maxX)
        #expect(ReadingPanelEdge.right.popoverEdge == .minX)
    }

    @Test
    func integratedControlsFitAndRemainStableOnHover() throws {
        for vertical in [false, true] {
            let size = vertical ? CGSize(width: 92, height: 300) : ReadingControlView.Metrics.surface
            let view = ReadingControlView(frame: CGRect(origin: .zero, size: size))
            defer { view.stopAnimating() }
            view.isVertical = vertical
            var opens = 0
            var stops = 0
            view.onOpenControls = { _ in opens += 1 }
            view.present(.speaking, opening: false, action: { stops += 1 })
            view.setQueueCount(0)
            func settle() {
                for index in 0..<240 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
            }
            settle()
            let children = view.subviews + view.subviews.flatMap(\.subviews)
            let options = try #require(children.first { $0.accessibilityIdentifier() == "readingQueueCount" } as? NSButton)
            let stop = try #require(children.compactMap { $0 as? ReadingStopButton }.first)
            let body = try #require(stop.superview)
            #expect(options.superview === body, "Options belong inside the capsule, not above it.")
            #expect(abs((vertical ? body.frame.height : body.frame.width) - 136) < 0.1)
            #expect(body.bounds.contains(options.frame))
            #expect(options.frame.width >= 40 && options.frame.height >= 40)
            #expect(stop.frame.size == CGSize(width: 44, height: 44))
            #expect(!options.frame.intersects(stop.frame))
            #expect(options.alphaValue < 0.01, "Resting capsule shows only waveform and Stop.")
            #expect(view.hitTest(view.convert(CGPoint(x: options.bounds.midX, y: options.bounds.midY), from: options)) === body)
            #expect(view.hitTest(view.convert(CGPoint(x: 22, y: 22), from: stop)) === stop)
            #expect(options.toolTip?.contains("Playback") == true)
            let frame = body.frame
            let stopFrame = stop.frame
            body.mouseEntered(with: NSEvent())
            settle()
            #expect(options.alphaValue > 0.99)
            let pause = try #require(children.first { $0.accessibilityIdentifier() == "readingPauseAction" } as? NSButton)
            #expect(pause.alphaValue > 0.99)
            #expect(pause.frame.width >= 40 && pause.frame.height >= 40)
            #expect(!pause.frame.intersects(options.frame))
            #expect(!pause.frame.intersects(stop.frame))
            #expect(view.hitTest(view.convert(CGPoint(x: options.bounds.midX, y: options.bounds.midY), from: options)) === options)
            #expect(abs(body.frame.width - frame.width) < 0.1)
            #expect(abs(body.frame.height - frame.height) < 0.1)
            #expect(abs(stop.frame.origin.x - stopFrame.origin.x) < 0.1)
            #expect(abs(stop.frame.origin.y - stopFrame.origin.y) < 0.1)
            options.performClick(nil)
            #expect(opens == 1 && stops == 0)
            view.setQueueCount(5)
            settle()
            #expect(options.title == "+5")
            #expect(abs(body.frame.width - frame.width) < 0.1)
            #expect(abs(body.frame.height - frame.height) < 0.1)
            body.mouseExited(with: NSEvent())
            settle()
            #expect(options.alphaValue < 0.01 && pause.alphaValue < 0.01)
            #expect((view.accessibilityCustomActions()?.count ?? 0) >= 2, "VoiceOver does not depend on hover.")
            view.retract()
            #expect(options.isEnabled == false)
            #expect(pause.isEnabled == false)
        }
    }

    @Test
    func integratedOptionsTrackTerminalStatesWithoutAnotherQueueUpdate() throws {
        let view = ReadingControlView(frame: CGRect(origin: .zero, size: ReadingControlView.Metrics.surface))
        defer { view.stopAnimating() }
        view.present(.speaking, opening: false, action: {})
        view.setQueueCount(2)
        let children = view.subviews + view.subviews.flatMap(\.subviews)
        let options = try #require(children.first { $0.accessibilityIdentifier() == "readingQueueCount" } as? NSButton)
        for state in [ReadingPanelState.finished, .stopped, .noText, .positioning] {
            view.present(state, opening: false, action: {})
            #expect(options.isHidden)
        }
        view.present(.failed, opening: false, action: {})
        #expect(!options.isHidden)
        #expect(options.title == "?")
        for index in 0..<240 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        let body = try #require(options.superview)
        #expect(body.bounds.insetBy(dx: -0.01, dy: -0.01).contains(options.frame))
        view.present(.speaking, opening: false, action: {})
        #expect(!options.isHidden)
        #expect(options.title == "+2")
    }

    @Test
    func returningFromQueueCaptureIsSilentAndShowsQueueCount() throws {
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let sounds = InterfaceSoundsFake()
        let controller = ReadingPanelController(interfaceSounds: sounds)
        defer { controller.hide() }
        controller.show(.speaking, displayID: number.uint32Value, onStop: {})
        controller.hide()
        sounds.cues.removeAll()
        controller.restore(.speaking, displayID: number.uint32Value, onStop: {})
        controller.updateQueueCount(2)
        #expect(sounds.cues.isEmpty)
        let children = controller.panel?.contentView?.subviews ?? []
        let badge = (children + children.flatMap(\.subviews)).first { $0.accessibilityIdentifier() == "readingQueueCount" } as? NSButton
        #expect(badge?.title == "+2")
        #expect(badge?.isHidden == false)
        controller.updateQueueCount(0)
        #expect(badge?.title == "···")
        #expect(badge?.isHidden == false)
    }

    @Test
    func draggingSurvivesSpeechTransitionsButNeverSurvivesHide() throws {
        let suite = "com.christopherbobel.OpenScreenReader.placement-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let controller = ReadingPanelController(defaults: defaults)
        defer { controller.hide() }
        var stops = 0
        controller.show(.preparing, displayID: number.uint32Value, onStop: { stops += 1 })
        let panel = try #require(controller.panel)
        let original = panel.frame
        let pointer = CGPoint(x: original.midX, y: original.midY)
        controller.beginDrag(at: pointer)
        controller.moveDrag(to: CGPoint(x: pointer.x + 2, y: pointer.y + 2))
        controller.endDrag()
        #expect(panel.frame == original, "A click or tiny hand movement is not a drag.")
        controller.beginDrag(at: pointer)
        controller.moveDrag(to: CGPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.midY))
        let draggedFrame = panel.frame
        controller.show(.speaking, displayID: number.uint32Value, onStop: { stops += 1 })
        #expect(panel.frame == draggedFrame, "Starting speech must not jerk a held capsule back to its dock.")
        controller.endDrag()
        let saved = ReadingPanelPlacement.load(from: defaults)
        #expect(saved.edge == .left)
        #expect((panel.contentView as? ReadingControlView)?.dockEdge == .left)
        // Advance the real spring explicitly; display-link delivery depends on
        // the runner's display and load, not on the drag behavior under test.
        let start = CACurrentMediaTime()
        for frame in 0..<240 {
            controller.stepSnap(now: start + Double(frame) / 60)
        }
        #expect(panel.frame == saved.frame(in: screen.visibleFrame))
        #expect(stops == 0)
        (panel.contentView as? ReadingControlView)?.currentAction()
        #expect(stops == 1)
        controller.beginDrag(at: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        controller.moveDrag(to: CGPoint(x: screen.visibleFrame.maxX, y: screen.visibleFrame.midY))
        controller.endDrag()
        controller.hide()
        controller.moveDrag(to: .zero)
        controller.endDrag()
        controller.stepSnap(now: start + 5)
        #expect(panel.isVisible == false)
        #expect(panel.contentView == nil)
        let newController = ReadingPanelController(defaults: defaults)
        defer { newController.hide() }
        newController.show(.positioning, displayID: number.uint32Value, onStop: nil)
        #expect(newController.panel?.frame == ReadingPanelPlacement.load(from: defaults).frame(in: screen.visibleFrame))
    }

    @Test
    func completionWaitsUntilUserReleasesTheDragSurface() async throws {
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let controller = ReadingPanelController(terminalDuration: .milliseconds(40))
        defer { controller.hide() }
        controller.show(.finished, displayID: number.uint32Value, onStop: nil)
        let frame = try #require(controller.panel?.frame)
        controller.beginDrag(at: CGPoint(x: frame.midX, y: frame.midY))
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.panel?.isVisible == true)
        controller.endDrag()
        // Dismissal and retraction each resume on MainActor. Other suites can
        // delay either stage, so wait for visibility instead of a fixed 350 ms.
        for _ in 0..<80 {
            if controller.panel?.isVisible == false { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.panel?.isVisible == false)
    }

    @Test
    func flickedControlLandsWhereItsMomentumPoints() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        #expect(abs(PanelMotion.project(1000) - 499) < 0.01, "Apple's projection with a 0.998 deceleration rate.")
        let nearBottom = CGPoint(x: 600, y: 160)
        #expect(ReadingPanelPlacement.dropped(at: nearBottom, in: visible).edge == .bottom)
        // A quick throw to the left wins over the closer bottom edge.
        let thrown = ReadingPanelPlacement.dropped(at: nearBottom, velocity: CGVector(dx: -2400, dy: 0), in: visible)
        #expect(thrown.edge == .left)
        let slowly = ReadingPanelPlacement.dropped(at: nearBottom, velocity: CGVector(dx: -80, dy: 0), in: visible)
        #expect(slowly.edge == .bottom, "A slow release is not a throw.")
        // Along the bottom edge the throw also carries the offset.
        let along = ReadingPanelPlacement.dropped(at: CGPoint(x: 600, y: 60), velocity: CGVector(dx: 900, dy: 0), in: visible)
        #expect(along.edge == .bottom && along.fraction > ReadingPanelPlacement.dropped(at: CGPoint(x: 600, y: 60), in: visible).fraction)
    }

    @Test
    func dragVelocityUsesOnlyTheLastMomentBeforeRelease() {
        var velocity = DragVelocity()
        velocity.add(CGPoint(x: 0, y: 0), at: 10.00)
        velocity.add(CGPoint(x: 30, y: 10), at: 10.03)
        velocity.add(CGPoint(x: 60, y: 20), at: 10.06)
        let moving = velocity.velocity(at: 10.07)
        #expect(abs(moving.dx - 1000) < 1 && abs(moving.dy - 333.3) < 1)
        #expect(velocity.velocity(at: 10.40) == .zero, "Holding still before release cancels the throw.")
        var instant = DragVelocity()
        instant.add(.zero, at: 5)
        instant.add(CGPoint(x: 400, y: 0), at: 5)
        #expect(instant.velocity(at: 5) == .zero, "Synthetic moves without elapsed time carry no speed.")
        var fast = DragVelocity()
        fast.add(.zero, at: 1)
        fast.add(CGPoint(x: 900, y: 0), at: 1.02)
        #expect(fast.velocity(at: 1.02).dx == PanelMotion.maximumSpeed)
    }

    @Test
    func springsSettleFromTheirCurrentVelocityWithoutDecorativeOvershoot() {
        var calm = PanelSpring(position: 0, velocity: 0, target: 100)
        var peak: CGFloat = 0
        var time: CGFloat = 0
        while !calm.isSettled && time < 2 { calm.step(1.0 / 120); peak = max(peak, calm.position); time += 1.0 / 120 }
        #expect(calm.isSettled && time < 0.8)
        #expect(peak <= 100.5, "Critically damped: no overshoot.")
        var handedOff = PanelSpring(position: 0, velocity: 1500, target: 100)
        var resting = PanelSpring(position: 0, velocity: 0, target: 100)
        handedOff.step(1.0 / 60); resting.step(1.0 / 60)
        #expect(handedOff.position > resting.position + 15, "The release velocity continues without a seam.")
        var flick = PanelSpring(position: 0, velocity: 2500, target: 100, dampingRatio: 0.85)
        var flickPeak: CGFloat = 0
        for _ in 0..<240 { flick.step(1.0 / 120); flickPeak = max(flickPeak, flick.position) }
        #expect(flickPeak > 100 && flickPeak < 130 && flick.isSettled, "A throw may overshoot a little, then rests.")
    }

    @Test
    func selectionFlightRespondsImmediately() {
        var first: [Float] = [0, 0]
        SelectionFlightWindow.timing.getControlPoint(at: 1, values: &first)
        // Ease-out: the frame leaves the selection at once instead of hesitating.
        #expect(first[1] > first[0] * 2)
        #expect(SelectionFlightWindow.durationMilliseconds <= 400)
    }

    @Test
    func edgesResistProgressivelyInsteadOfStoppingHard() {
        #expect(PanelMotion.rubberband(0, dimension: 300) == 0)
        let small = PanelMotion.rubberband(20, dimension: 300)
        let large = PanelMotion.rubberband(200, dimension: 300)
        #expect(small > 0 && small < 20)
        #expect(large > small && large < 300 * 0.55)
        #expect(PanelMotion.rubberband(-20, dimension: 300) == -small)
    }

    @Test
    func placementFitsEveryEdgeAndRemembersOnlyNormalizedGeometry() throws {
        let suite = "com.christopherbobel.OpenScreenReader.placement-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReadingPanelPlacement.load(from: defaults) == ReadingPanelPlacement())
        for visible in [CGRect(x: -1440, y: 124, width: 1440, height: 850),
                        CGRect(x: 120, y: -900, width: 1920, height: 860),
                        CGRect(x: 0, y: 0, width: 200, height: 50)] {
            for edge in ReadingPanelEdge.allCases {
                for fraction in [0.0, 0.5, 1.0] {
                    let placement = ReadingPanelPlacement(edge: edge, fraction: fraction)
                    let frame = placement.frame(in: visible)
                    #expect(visible.contains(frame))
                    placement.save(to: defaults)
                    #expect(ReadingPanelPlacement.load(from: defaults) == placement)
                }
            }
        }
        defaults.set("unknown", forKey: ReadingPanelPlacement.edgeKey)
        defaults.set(Double.nan, forKey: ReadingPanelPlacement.fractionKey)
        #expect(ReadingPanelPlacement.load(from: defaults) == ReadingPanelPlacement())
    }

    @Test
    func droppingSelectsNearestEdgeAndPreservesAlongEdgePosition() {
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 900)
        for (point, edge) in [(CGPoint(x: -1190, y: 700), ReadingPanelEdge.left),
                              (CGPoint(x: -10, y: 700), .right),
                              (CGPoint(x: -400, y: 110), .bottom)] {
            let placement = ReadingPanelPlacement.dropped(at: point, in: screen)
            #expect(placement.edge == edge)
            let frame = placement.frame(in: screen)
            #expect(screen.contains(frame))
            #expect(abs((edge == .bottom ? frame.midX : frame.midY) - (edge == .bottom ? point.x : point.y)) < 1)
        }
    }

    @Test
    func verticalControlHasUprightStopTargetAndBackgroundDragDoesNotStop() {
        let view = ReadingControlView(frame: CGRect(x: 0, y: 0, width: 92, height: 300))
        view.isVertical = true
        var stops = 0
        view.present(.speaking, opening: false, action: { stops += 1 })
        for index in 0..<120 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        let button = view.subviews.flatMap(\.subviews).compactMap { $0 as? ReadingStopButton }.first
        #expect(button?.frame.size == CGSize(width: 44, height: 44))
        #expect(stops == 0)
        // Re-presenting a captured callback (as the selection flight does) must not recurse.
        let capturedAction = view.currentAction
        view.present(.speaking, opening: false, action: capturedAction)
        view.currentAction()
        #expect(stops == 1)
        view.stopAnimating()
    }

    @Test
    func dragSurfaceReceivesMouseEventsWhileStopKeepsItsOwnHitTarget() throws {
        let window = ReadingStatusPanel()
        window.setFrame(CGRect(x: 100, y: 100, width: 300, height: 92), display: false)
        let view = ReadingControlView(frame: CGRect(x: 0, y: 0, width: 300, height: 92))
        window.contentView = view
        defer { view.stopAnimating(); window.close() }
        view.present(.positioning, opening: false, action: {})
        for index in 0..<120 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
        let target = try #require(view.hitTest(CGPoint(x: 130, y: 46)))
        #expect(!(target is ReadingStopButton))
        let button = try #require(view.subviews.flatMap(\.subviews).compactMap { $0 as? ReadingStopButton }.first)
        let buttonPoint = view.convert(CGPoint(x: 22, y: 22), from: button)
        #expect(view.hitTest(buttonPoint) === button)
        var positions: [CGPoint] = []
        var releases = 0
        view.onDragStart = { positions.append($0) }
        view.onDragMove = { positions.append($0) }
        view.onDragEnd = { releases += 1 }
        func event(_ type: NSEvent.EventType, _ location: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0.5))
        }
        target.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 130, y: 46)))
        target.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 150, y: 66)))
        target.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 150, y: 66)))
        #expect(positions == [CGPoint(x: 230, y: 146), CGPoint(x: 250, y: 166)])
        #expect(releases == 1)
    }

    /// Opt-in render of only the view's drawing, never a screenshot of the user's screen.
    @Test
    func renderPlacementLayouts() throws {
        guard let path = ProcessInfo.processInfo.environment["OSR_PLACEMENT_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for edge in ReadingPanelEdge.allCases {
          for (name, state, count) in [("speaking", ReadingPanelState.speaking, 0), ("hover", .speaking, 0), ("paused", .speaking, 0), ("queue", .speaking, 5),
                                       ("preparing", .preparing, 0), ("failed", .failed, 0), ("finished", .finished, 0)] {
            let size = edge == .bottom ? CGSize(width: 300, height: 92) : CGSize(width: 92, height: 300)
            let view = ReadingControlView(frame: CGRect(origin: .zero, size: size))
            view.isVertical = edge != .bottom
            view.present(state, opening: false, action: {})
            view.setQueueCount(count)
            view.setLevel(0.6)
            if ["hover", "paused", "queue"].contains(name) {
                let stop = try #require(view.subviews.flatMap(\.subviews).compactMap { $0 as? ReadingStopButton }.first)
                stop.superview?.mouseEntered(with: NSEvent())
                if name == "paused" { view.setPaused(true) }
            }
            for index in 0..<120 { view.tick(now: CACurrentMediaTime() + Double(index) / 60) }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(edge.rawValue)-\(name).png"))
            view.stopAnimating()
          }
        }
    }

    @Test
    func drawingClockDoesNotRetainAnUnownedView() async throws {
        weak var released: ReadingControlView?
        do {
            let view = ReadingControlView(frame: CGRect(origin: .zero, size: ReadingControlView.Metrics.surface))
            released = view
            view.present(.speaking, opening: true, action: {})
            try await Task.sleep(for: .milliseconds(35))
        }
        try await Task.sleep(for: .milliseconds(35))
        #expect(released == nil)
    }

    @Test
    func sameHostSurvivesTransitionsAndImmediateHideCancelsExit() async throws {
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let suite = "com.christopherbobel.OpenScreenReader.placement-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ReadingPanelController(terminalDuration: .seconds(10), defaults: defaults)
        defer { controller.hide() }
        controller.show(.recognizing, displayID: number.uint32Value, onStop: {})
        let host = try #require(controller.panel?.contentView)
        #expect(host is ReadingControlView, "First show installs the native reading control.")
        controller.show(.preparing, displayID: number.uint32Value, onStop: {})
        #expect(controller.panel?.contentView === host)
        controller.show(.speaking, displayID: number.uint32Value, onStop: {})
        #expect(controller.panel?.contentView === host)
        controller.dismiss()
        controller.hide()
        #expect(controller.panel?.isVisible == false)
        controller.show(.recognizing, displayID: number.uint32Value, onStop: {})
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.state == .recognizing)
        #expect(controller.panel?.isVisible == true)
        #expect(controller.panel?.frame == ReadingPanelController.frame(in: screen.visibleFrame))
    }

    @Test
    func soundCuesAreShortBoundedDeterministicStereoAndDecodeWithoutFiles() throws {
        for cue in InterfaceCue.allCases {
            let samples = cue.samples
            let rendering = cue.render(variant: 0)
            #expect(samples == cue.samples)
            #expect(rendering == cue.render(variant: 0))
            #expect(rendering.left.count == rendering.right.count)
            #expect(rendering.left != rendering.right, "The room is stereo.")
            #expect(samples.count <= 66_150, "Cues stay under 1.5 s.")
            let peak = Double(cue.peak) + 0.001
            #expect(rendering.left.allSatisfy { $0.isFinite && abs(Double($0)) <= peak })
            #expect(rendering.right.allSatisfy { $0.isFinite && abs(Double($0)) <= peak })
            #expect((rendering.left + rendering.right).map { abs($0) }.max() ?? 0 > cue.peak * 0.98, "Normalised to the intended peak.")
            #expect(rendering.left.first == 0 && rendering.right.first == 0)
            #expect(abs(rendering.left.last ?? 1) < 0.001 && abs(rendering.right.last ?? 1) < 0.001)
            if cue.variantCount > 1 { #expect(cue.render(variant: 1) != rendering, "Alternate voicings differ.") }
            #expect(cue.wavData.count == 44 + samples.count * 2 * InterfaceCue.channels)
            let decoded = try AVAudioPlayer(data: cue.wavData)
            #expect(decoded.numberOfChannels == 2)
            #expect(abs(decoded.duration - Double(samples.count) / Double(InterfaceCue.sampleRate)) < 0.001)
        }
    }

    /// The microphone cues sound while the user is about to speak or has just spoken:
    /// short, quieter than the reading cues, front-loaded and distinct from each other.
    @Test
    func microphoneCuesAreShortQuietAndFrontLoaded() {
        let microphone: [InterfaceCue] = [.listening, .handsFree, .captured]
        for cue in microphone {
            let samples = cue.samples
            #expect(samples.count <= Int(0.45 * Double(InterfaceCue.sampleRate)), "\(cue) stays under 450 ms.")
            #expect(cue.peak < InterfaceCue.completion.peak && cue.peak < InterfaceCue.selection.peak)
            #expect(cue.variantCount == 1, "Frequent cues stay identical, so they are learnt.")
            let energy = samples.map { Double($0 * $0) }
            let early = energy.prefix(Int(0.15 * Double(InterfaceCue.sampleRate))).reduce(0, +)
            #expect(early / energy.reduce(0, +) > 0.85, "\(cue) is over almost at once.")
        }
        for (index, cue) in microphone.enumerated() {
            for other in microphone[(index + 1)...] { #expect(cue.samples != other.samples) }
        }
    }

    @Test
    func stopButtonPressIsSilentAndCuesKeepToMeaningfulMoments() {
        let sounds = InterfaceSoundsFake()
        let controller = ReadingPanelController(terminalDuration: .seconds(10), interfaceSounds: sounds)
        defer { controller.hide() }
        guard let number = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        controller.show(.speaking, displayID: number.uint32Value, onStop: {})
        #expect(sounds.cues == [.selection], "Without a frame to fly, the opening cue plays immediately.")
        let view = controller.panel?.contentView as? ReadingControlView
        #expect(view != nil)
        sounds.cues.removeAll()
        sounds.isStopped = true
        view?.onPress?()
        view?.onRelease?()
        #expect(sounds.cues.isEmpty, "Stopping is a cancellation; it never adds a sound.")
        #expect(InterfaceCue.allCases == [.selection, .completion, .attention, .listening, .handsFree, .captured])
    }

    @Test
    func capturedFrameFliesIntoTheControlBeforeItOpensAndHideCancelsTheFlight() async throws {
        let sounds = InterfaceSoundsFake()
        let controller = ReadingPanelController(terminalDuration: .seconds(10), interfaceSounds: sounds)
        defer { controller.hide() }
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let origin = CGRect(x: screen.frame.midX - 120, y: screen.frame.midY - 40, width: 240, height: 80)
        controller.show(.recognizing, displayID: number.uint32Value, origin: origin, onStop: {})
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced {
            #expect(controller.flight == nil)
            #expect(controller.panel?.isVisible == true)
            return
        }
        #expect(controller.flight?.isVisible == true)
        #expect(controller.panel?.isVisible == false, "The control opens only when the frame has landed.")
        #expect(sounds.cues.isEmpty)
        controller.show(.preparing, displayID: number.uint32Value, onStop: {})
        #expect(controller.state == .preparing)
        try await Task.sleep(for: .milliseconds(SelectionFlightWindow.durationMilliseconds + 120))
        #expect(controller.flight == nil)
        #expect(controller.panel?.isVisible == true)
        #expect(sounds.cues == [.selection], "The opening cue is synchronised with the landing.")
        controller.hide()
        controller.show(.recognizing, displayID: number.uint32Value, origin: origin, onStop: {})
        let flight = controller.flight
        #expect(flight?.isVisible == true)
        controller.hide()
        #expect(controller.flight == nil)
        #expect(flight?.isVisible != true)
        try await Task.sleep(for: .milliseconds(SelectionFlightWindow.durationMilliseconds + 60))
        #expect(controller.panel?.isVisible != true)
        #expect(sounds.cues == [.selection], "A cancelled flight never lands or plays.")
    }
    /// Opt-in design review: `OSR_PANEL_PREVIEW_DIR=/path` (pass it to xcodebuild as
    /// `TEST_RUNNER_OSR_PANEL_PREVIEW_DIR`) writes the cue WAVs and on-screen captures
    /// of the opening sequence and every reading-control state into that directory.
    @Test
    func exportReadingControlPreview() async throws {
        guard let path = ProcessInfo.processInfo.environment["OSR_PANEL_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for cue in InterfaceCue.allCases {
            for variant in 0..<cue.variantCount {
                try cue.wavData(variant: variant).write(to: directory.appendingPathComponent("cue-\(cue)\(variant == 0 ? "" : "-b").wav"))
            }
        }
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let controller = ReadingPanelController(terminalDuration: .seconds(30))
        defer { controller.hide() }
        func capture(_ name: String) throws {
            let panel = try #require(controller.panel)
            let frame = panel.frame
            let primary = NSScreen.screens[0].frame
            let rect = CGRect(x: frame.minX - 40, y: primary.maxY - frame.maxY - 40, width: frame.width + 80, height: frame.height + 80)
            var image = CGWindowListCreateImage(rect, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution])
            if image == nil, let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                image = rep.cgImage
            }
            let captured = try #require(image)
            let png = try #require(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        let display = number.uint32Value
        let origin = CGRect(x: screen.frame.midX - 160, y: screen.frame.midY + 40, width: 320, height: 90)
        controller.show(.recognizing, displayID: display, origin: origin, onStop: {})
        for (index, delay) in [120, 140, 140, 160, 120, 100, 120, 400].enumerated() {
            try await Task.sleep(for: .milliseconds(delay))
            try capture("0-opening-\(index)")
        }
        try capture("1-recognizing")
        controller.show(.preparing, displayID: display, onStop: {})
        try await Task.sleep(for: .milliseconds(600))
        try capture("2-preparing")
        controller.show(.speaking, displayID: display, onStop: {})
        for (index, level) in [0.12, 0.45, 0.9].enumerated() {
            for _ in 0..<12 { controller.updateLevel(level); try await Task.sleep(for: .milliseconds(33)) }
            try capture("3-speaking-\(index)")
        }
        controller.show(.finished, displayID: display, onStop: nil)
        try await Task.sleep(for: .milliseconds(180))
        try capture("4-finished-drawing")
        try await Task.sleep(for: .milliseconds(500))
        try capture("4-finished")
        controller.dismiss()
        try await Task.sleep(for: .milliseconds(110))
        try capture("4-finished-closing")
        try await Task.sleep(for: .milliseconds(300))
        for (name, state) in [("5-stopped", ReadingPanelState.stopped), ("6-notext", .noText), ("7-failed", .failed)] {
            controller.hide()
            controller.show(.speaking, displayID: display, onStop: {})
            try await Task.sleep(for: .milliseconds(500))
            controller.show(state, displayID: display, onStop: nil)
            try await Task.sleep(for: .milliseconds(700))
            try capture(name)
        }
    }

    @Test
    func panelFitsSelectedDisplaysIncludingNegativeOriginsAndSmallFrames() {
        for visible in [CGRect(x: -1440, y: 124, width: 1440, height: 850),
                        CGRect(x: 120, y: -900, width: 1920, height: 860),
                        CGRect(x: 0, y: 0, width: 200, height: 50)] {
            let frame = ReadingPanelController.frame(in: visible)
            #expect(visible.contains(frame))
            #expect(frame.midX == visible.midX)
            #expect(frame.minY >= visible.minY)
        }
    }

    @Test
    func terminalDismissalCannotHideNewWorkAndPanelNeverBecomesKey() async throws {
        let screen = try #require(NSScreen.screens.first)
        let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let controller = ReadingPanelController(terminalDuration: .milliseconds(50))
        defer { controller.hide() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.show(.stopped, displayID: number.uint32Value, onStop: nil)
        let panel = try #require(controller.panel)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        controller.show(.preparing, displayID: number.uint32Value, onStop: {})
        try await Task.sleep(for: .milliseconds(120))
        #expect(controller.state == .preparing)
        #expect(panel.isVisible)
        controller.show(.finished, displayID: number.uint32Value, onStop: nil)
        // The dismissal is a main-actor task after `terminalDuration`; a busy CI runner can
        // run it later than a fixed sleep allows, so wait for it with a generous limit.
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.state != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.state == nil)
        #expect(!panel.isVisible)
        controller.show(.noText, displayID: number.uint32Value, onStop: nil)
        try await Task.sleep(for: .milliseconds(120))
        #expect(controller.state == .noText)
        controller.hide()
        #expect(panel.contentView == nil)
        controller.show(.speaking, displayID: UInt32.max, onStop: {})
        #expect(controller.state == nil)
        #expect(!panel.isVisible)
    }
}

@MainActor
private final class PoolProbe { var ran = false }

/// Stands in for the engine that posts a configuration change.
private final class ConfigurationSource: Sendable {}

@MainActor
private final class ReadingPanelFake: ReadingStatusPresenting {
    var level: Double = 0
    func updateLevel(_ level: Double) { self.level = level }
    var state: ReadingPanelState?
    var displayID: UInt32?
    var origin: CGRect?
    var onStop: (() -> Void)?
    func show(_ state: ReadingPanelState, displayID: UInt32, origin: CGRect?, onStop: (() -> Void)?) {
        self.origin = origin
        self.state = state
        self.displayID = displayID
        self.onStop = onStop
    }
    func hide() { state = nil; onStop = nil }
}

@MainActor
private final class RecorderFake: DictationRecording {
    var level = 0.0
    var events: [String] = []
    var onFinish: (() -> Void)?
    var onInterruption: (() -> Void)?
    var cuesAtFinish: [InterfaceCue]?
    var finishFailure: Error?
    func start() throws { events.append("start") }
    func finish() throws -> AudioPacket {
        events.append("finish")
        onFinish?()
        if let finishFailure { throw finishFailure }
        return AudioPacket(samples: [0.1, 0.2], rate: 16000)
    }
    func cancel() { events.append("cancel") }
}

@MainActor
private final class InterfaceSoundsFake: InterfaceSoundPlaying {
    var cues: [InterfaceCue] = []
    var isStopped = true
    func play(_ cue: InterfaceCue) { cues.append(cue); isStopped = false }
    func stop() { isStopped = true }
}

@MainActor
private final class EscapeFake: EscapeMonitoring {
    var onEscape: (() -> Void)?
    var onUnavailable: (() -> Void)?
    var isActive = false
    var shouldFail = false
    func start(onEscape: @escaping () -> Void, onUnavailable: @escaping () -> Void) throws {
        if shouldFail { throw EscapeMonitorFailure.permissionRequired }
        self.onEscape = onEscape
        self.onUnavailable = onUnavailable
        isActive = true
    }
    func stop() { isActive = false; onEscape = nil; onUnavailable = nil }
}

@MainActor
private final class CaptureFake: ScreenCapturing {
    var suspend = false
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func capture(_ selection: ScreenRegionSelection) async throws -> CGImage {
        calls += 1
        if suspend {
            await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
        }
        // Deliberately ignore cancellation to model Apple's one-shot callback.
        return CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    func waitUntilStarted() async {
        if continuation == nil { await withCheckedContinuation { started = $0 } }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class OCRFake: TextRecognizing {
    var calls = 0
    var suspend = false
    var shouldFail = false
    var result = OCRResult(lines: ["Hello world"])
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func recognize(_ image: CGImage) async throws -> OCRResult {
        calls += 1
        if suspend {
            await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
        }
        if shouldFail { throw NSError(domain: "private synthetic diagnostic", code: 1) }
        // Deliberately ignore cancellation to exercise stale-result rejection.
        return result
    }
    func waitUntilStarted() async {
        if continuation == nil { await withCheckedContinuation { started = $0 } }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class SpeechFake: SpeechReading {
    var playbackRate: Double = 1
    var playbackLevel: Double { 0.65 }
    var receivedText: String?
    var suspend = false
    var stopped = false
    var shouldFail = false
    var failure: SpeechFailure?
    var emitPlayback = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func read(_ text: String, onPlayback: @escaping @MainActor () -> Void) async throws {
        receivedText = text
        if let failure { throw failure }
        if shouldFail { throw NSError(domain: "private synthetic speech diagnostic", code: 1) }
        if emitPlayback { onPlayback() }
        if suspend {
            await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
        }
        // Deliberately non-cooperative: AppModel must reject a stale completion.
    }
    func stop() { stopped = true }
    func waitUntilStarted() async {
        if continuation == nil { await withCheckedContinuation { started = $0 } }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class QueueSpeechFake: SpeechReading {
    var isPaused = false
    func setPaused(_ paused: Bool) { isPaused = paused }
    var playbackRate = 1.0
    var preparedText: String?
    func prepareNext(_ text: String?) { preparedText = text }
    var texts: [String] = []
    private var completions: [CheckedContinuation<Void, Error>] = []
    func read(_ text: String, onPlayback: @escaping @MainActor () -> Void) async throws {
        texts.append(text)
        onPlayback()
        try await withCheckedThrowingContinuation { completions.append($0) }
    }
    func finishFirst() { if !completions.isEmpty { completions.removeFirst().resume() } }
    func failFirst(_ failure: SpeechFailure) { if !completions.isEmpty { completions.removeFirst().resume(throwing: failure) } }
    func stop() {
        preparedText = nil
        stopCurrent()
    }
    /// Runs once inside the next stopCurrent, like a Settings edit landing in that moment.
    var onStopCurrent: (() -> Void)?
    func stopCurrent() {
        let hook = onStopCurrent
        onStopCurrent = nil
        hook?()
        let pending = completions
        completions.removeAll()
        for completion in pending { completion.resume(throwing: CancellationError()) }
    }
    func waitForReads(_ count: Int) async throws {
        for _ in 0..<500 {
            if texts.count >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(texts.count >= count)
    }
}

@MainActor
private struct QueueFixture {
    let hotkey = HotkeyManagerFake(registrationResult: .registered)
    let selection = RegionSelectionControllerFake()
    let capture = CaptureFake()
    let ocr = OCRFake()
    let speech = QueueSpeechFake()
    let escape = EscapeFake()
    let model: AppModel
    init(operationTimeout: Duration = .seconds(15),
         waitForQueueTimeout: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: hotkey,
            selectionController: selection, captureService: capture, escapeMonitor: escape,
            ocrService: ocr, speechService: speech, operationTimeout: operationTimeout,
            waitForQueueTimeout: waitForQueueTimeout)
    }
}

@MainActor
private final class HotkeyManagerFake: HotkeyManaging {
    var onPress: (() -> Void)?
    private(set) var registeredShortcut: HotkeyShortcut?
    var registrationResult: HotkeyRegistration

    init(registrationResult: HotkeyRegistration) {
        self.registrationResult = registrationResult
    }

    func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistration {
        if registrationResult == .registered { registeredShortcut = shortcut }
        return registrationResult
    }

    func unregister() { registeredShortcut = nil }
}

@MainActor
final class MemoryShortcutStore: ShortcutStoring {
    var saved: ShortcutConfiguration?
    func load() -> ShortcutConfiguration? { saved }
    func save(_ configuration: ShortcutConfiguration) { saved = configuration }
}

@MainActor
private final class RegionSelectionControllerFake: RegionSelectionControlling {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var completion: ((ScreenRegionSelection) -> Void)?
    private var cancellation: ((SelectionCancelReason) -> Void)?

    func start(
        onSelection: @escaping (ScreenRegionSelection) -> Void,
        onCancel: @escaping (SelectionCancelReason) -> Void
    ) {
        startCount += 1
        completion = onSelection
        cancellation = onCancel
    }

    func cancel() {
        cancelCount += 1
        completion = nil
        cancellation = nil
    }

    /// The overlay ending by itself: Escape, a too-small drag, or a display change.
    func end(_ reason: SelectionCancelReason) {
        let cancellation = cancellation
        completion = nil
        self.cancellation = nil
        cancellation?(reason)
    }

    func complete(_ selection: ScreenRegionSelection) {
        let completion = completion
        self.completion = nil
        completion?(selection)
    }
}

@Suite("Local dictation lifecycle", .serialized)
@MainActor
struct DictationIntegrationTests {
    private func fixture(preferences: UserDefaults? = nil,
                         installed: Set<DictationModel> = Set(DictationModel.allCases))
        -> (DictationController, DictationWorkerFake, HotkeyManagerFake) {
        let worker = DictationWorkerFake()
        let escape = HotkeyManagerFake(registrationResult: .registered)
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-fixture-\(UUID())")
        for model in installed {
            try? FileManager.default.createDirectory(
                at: resources.appendingPathComponent(model.directoryName), withIntermediateDirectories: true)
        }
        let store = DictationModelStore(resources: resources,
            installRoot: resources.appendingPathComponent("Installed"), fetcher: DictationFetcherFake())
        let controller = DictationController(resources: resources, models: store,
            worker: worker, shortcut: HotkeyManagerFake(registrationResult: .registered), escape: escape,
            preferences: preferences ?? UserDefaults(suiteName: "com.christopherbobel.OpenScreenReader.dictation-tests")!, registerHotkey: false)
        return (controller, worker, escape)
    }

    @Test func dictationWindowFitsOnPresentationAndKeepsItsPositionOnReopen() throws {
        let (controller, worker, _) = fixture()
        defer { controller.window.orderOut(nil); controller.shutdown() }
        let content = try #require(controller.window.contentView)
        #expect(content.frame.height == 600, "Construction must not force window layout during StateObject initialization.")
        #expect(!controller.window.isVisible)
        worker.ready = true
        controller.showWindow()
        let stack = try #require(content.subviews.first as? NSStackView)
        #expect(abs(content.frame.height - (stack.fittingSize.height + 42)) < 1)
        controller.window.setFrameOrigin(NSPoint(x: 120, y: 150))
        let frame = controller.window.frame
        controller.window.orderOut(nil)
        controller.showWindow()
        #expect(controller.window.frame == frame)
        #expect(controller.record == nil)
    }

    @Test func microphoneCallbackAcceptsBackgroundAudioAndDiscardsAfterCancel() async throws {
        let recorder = MicrophoneRecorder()
        let audio = recorder.audio
        audio.start(sampleRate: 48000)
        let tap = AudioTapInvocation(block: recorder.makeInputTap())
        let ranOffMain = try await Task.detached { try tap.invokeStereoBuffer() }.value
        #expect(ranOffMain)
        let packet = audio.finish()
        #expect(packet.rate == 48000)
        #expect(packet.samples == [0.5, -0.25, 0, 0.75])
        audio.start(sampleRate: 48000)
        audio.cancel()
        _ = try await Task.detached { try tap.invokeStereoBuffer() }.value
        #expect(audio.finish().samples.isEmpty)
        #expect(audio.rms == 0)
    }

    @Test func ownTestFieldRetainsItsExplicitTargetAndRejectsEdits() {
        let (controller, _, _) = fixture()
        defer { controller.shutdown() }
        controller.scratch.string = "Anfang MARKER Ende"
        controller.scratch.setSelectedRange((controller.scratch.string as NSString).range(of: "MARKER"))
        controller.window.makeFirstResponder(controller.scratch)
        let target = InsertionTarget(local: controller.scratch)
        #expect(target.isCurrent())
        controller.scratch.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!target.isCurrent())
        controller.scratch.setSelectedRange((controller.scratch.string as NSString).range(of: "MARKER"))
        controller.scratch.string = "New user text"
        #expect(!target.isCurrent())
    }

    @Test func constructingControllerDoesNotRecord() {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        #expect(worker.starts == 0)
        #expect(controller.record == nil)
        #expect(!controller.isActive)
    }

    @Test func modelChoiceRestoresAndSwitchInvalidatesPreviousWorkerMessages() throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-model-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let (controller, worker, _) = fixture(preferences: preferences)
        defer { controller.shutdown() }
        controller.loadModel()
        let oldCallback = try #require(worker.onMessage)
        controller.selectModel(.qwen)
        #expect(controller.selectedModel == .qwen)
        #expect(worker.models == [.whisperTurbo, .qwen])
        #expect(worker.stops > 0)
        #expect(controller.record == nil)
        #expect(!controller.isActive)
        oldCallback(.init(type: "fatal", message: "Old worker failed"))
        oldCallback(.init(type: "ready", version: 1))
        #expect(controller.phase == "loading")
        #expect(controller.selectedModel == .qwen)
        let (restored, restoredWorker, _) = fixture(preferences: preferences)
        defer { restored.shutdown() }
        restored.loadModel()
        #expect(restoredWorker.models == [.qwen])
        restored.screenLockedOrSleeping(Notification(name: NSWorkspace.willSleepNotification))
        restored.screenBecameAvailable(Notification(name: NSWorkspace.didWakeNotification))
        #expect(restoredWorker.models == [.qwen, .qwen])
    }

    @Test func whisperTurboIsTheDefaultModelAndListedFirst() throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-default-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let (controller, worker, _) = fixture(preferences: preferences)
        defer { controller.shutdown() }
        #expect(controller.selectedModel == .whisperTurbo)
        #expect(DictationModel.allCases.first == .whisperTurbo)
        controller.loadModel()
        #expect(worker.models == [.whisperTurbo])
    }

    @Test func vocabularyIsParsedPersistedAndSentWithEachRecording() throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-vocabulary-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let (controller, worker, _) = fixture(preferences: preferences)
        defer { controller.shutdown() }
        #expect(controller.vocabulary.isEmpty)
        controller.setVocabulary(" Saywing \nBöbel, Owl Frame\n\nsaywing\n\(String(repeating: "x", count: 61))")
        #expect(controller.vocabulary == ["Saywing", "Böbel", "Owl Frame"])
        let (restored, _, _) = fixture(preferences: preferences)
        defer { restored.shutdown() }
        #expect(restored.vocabulary == ["Saywing", "Böbel", "Owl Frame"])
        worker.ready = true
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        controller.send(AudioPacket(samples: [0], rate: 16_000))
        #expect(worker.vocabularies == [["Saywing", "Böbel", "Owl Frame"]])
        controller.setVocabulary("")
        #expect(controller.vocabulary.isEmpty)
        #expect(preferences.object(forKey: "dictationVocabulary.v1") == nil)
    }

    @Test func vocabularyKeepsAtMostFiftyTerms() {
        let terms = DictationVocabulary.parse((1...80).map { "Term \($0)" }.joined(separator: "\n"))
        #expect(terms.count == DictationVocabulary.maximumTerms)
        #expect(terms.first == "Term 1")
        #expect(DictationVocabulary.parse("a\u{7}b\nok") == ["ok"])
    }

    @Test func whisperLargeIsSelectablePersistedAndStartsItsOwnWorker() throws {
        #expect(DictationModel.allCases == [.whisperTurbo, .qwen, .whisperLargeV3])
        #expect(DictationModel.whisperLargeV3.rawValue == "whisper-large-v3")
        #expect(DictationModel.whisperLargeV3.displayName == "Whisper Large v3")
        let suite = "com.christopherbobel.OpenScreenReader.dictation-large-model-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let (controller, worker, _) = fixture(preferences: preferences)
        defer { controller.shutdown() }
        controller.loadModel()
        controller.selectModel(.whisperLargeV3)
        #expect(worker.models == [.whisperTurbo, .whisperLargeV3])
        #expect(controller.record == nil)
        let (restored, restoredWorker, _) = fixture(preferences: preferences)
        defer { restored.shutdown() }
        restored.loadModel()
        #expect(restored.selectedModel == .whisperLargeV3)
        #expect(restoredWorker.models == [.whisperLargeV3])
    }

    @Test func whisperTurboIsTheDefaultAndUninstalledModelsCannotBeSelected() throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-install-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let (controller, worker, _) = fixture(preferences: preferences, installed: [.whisperTurbo])
        defer { controller.shutdown() }
        #expect(controller.selectedModel == .whisperTurbo)
        controller.loadModel()
        controller.selectModel(.whisperLargeV3)
        #expect(controller.selectedModel == .whisperTurbo)
        #expect(worker.models == [.whisperTurbo])
        #expect(worker.modelRoots == [nil], "Bundled models need no separate model root.")
        #expect(preferences.string(forKey: "dictationModel.v1") == nil)
    }

    @Test func savedChoiceOfAMissingModelStartsTheBundledDefaultWithoutForgettingIt() throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-missing-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("qwen3-asr", forKey: "dictationModel.v1")
        let (controller, worker, _) = fixture(preferences: preferences, installed: [.whisperTurbo])
        defer { controller.shutdown() }
        controller.loadModel()
        #expect(controller.selectedModel == .whisperTurbo)
        #expect(worker.models == [.whisperTurbo])
        #expect(preferences.string(forKey: "dictationModel.v1") == "qwen3-asr")
    }

    @Test func installedModelIsSelectedAndStartedFromItsInstallLocation() async throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-installed-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let fetcher = DictationFetcherFake(files: DictationModelFixture.largeFiles)
        let installRoot = resources.appendingPathComponent("Installed")
        let store = DictationModelStore(resources: resources, installRoot: installRoot, fetcher: fetcher)
        let worker = DictationWorkerFake()
        let controller = DictationController(resources: resources, models: store, worker: worker,
            shortcut: HotkeyManagerFake(registrationResult: .registered),
            escape: HotkeyManagerFake(registrationResult: .registered),
            preferences: preferences, registerHotkey: false)
        defer { controller.shutdown() }
        controller.loadModel()
        await controller.install(.whisperLargeV3)?.value
        #expect(store.availability[.whisperLargeV3] == .installed)
        #expect(controller.selectedModel == .whisperLargeV3)
        #expect(worker.models == [.whisperTurbo, .whisperLargeV3])
        #expect(worker.modelRoots == [nil, installRoot])
        #expect(controller.record == nil, "Installing never opens the microphone.")
    }

    @Test func languageAndClipboardDelayArePersistedPreferences() throws {
        let suite = "com.christopherbobel.OpenScreenReader.dictation-preference-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let (controller, worker, _) = fixture(preferences: preferences)
        defer { controller.shutdown() }
        #expect(controller.language == .automatic)
        #expect(!controller.restoresClipboardSlowly)
        controller.setLanguage(.german)
        controller.setRestoresClipboardSlowly(true)
        let (restored, _, _) = fixture(preferences: preferences)
        defer { restored.shutdown() }
        #expect(restored.language == .german)
        #expect(restored.restoresClipboardSlowly)
        worker.ready = true
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        controller.send(AudioPacket(samples: [0], rate: 16_000))
        #expect(worker.languages == ["German"])
        #expect(DictationLanguage.allCases.map(\.workerValue) == [nil, "German", "English"])
    }

    @Test func workerCodesBecomeLocalizedTextAndLegacyMessagesPassThrough() throws {
        let coded = try JSONDecoder().decode(DictationWorkerMessage.self,
            from: Data(#"{"type":"error","id":"x","code":"processing_failed","message":"raw"}"#.utf8))
        #expect(coded.localizedDetail == "The recording could not be processed. Please try again.")
        let legacy = DictationWorkerMessage(type: "fatal", message: "Legacy worker text")
        #expect(legacy.localizedDetail == "Legacy worker text")
    }

    @Test func modelCannotSwitchDuringDictationAndFailureDoesNotFallback() throws {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        controller.loadModel()
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let selected = controller.selectedModel
        controller.selectModel(selected == .qwen ? .whisperTurbo : .qwen)
        #expect(controller.selectedModel == selected)
        #expect(worker.starts == 1)
        #expect(controller.isActive)
        controller.receive(.init(type: "fatal", message: "Selected model missing"))
        #expect(worker.starts == 1)
        #expect(controller.selectedModel == selected)
        #expect(!controller.isActive)
    }

    @Test func automaticPreparationLoadsOnceWithoutRecording() {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        controller.loadModel()
        controller.loadModel()
        #expect(worker.starts == 1)
        #expect(controller.record == nil)
        #expect(!controller.isActive)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        controller.loadModel()
        #expect(worker.starts == 1)
        #expect(controller.phase == "ready")
    }

    @Test func readingKeepsAnIdleDictationModelWarm() {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        controller.loadModel()
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        controller.cancelForReading()
        #expect(worker.ready)
        #expect(worker.stops == 0)
        #expect(controller.phase == "ready")
    }

    @Test func wakeWaitsForActiveSessionThenLoadsWithoutRecording() {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        controller.loadModel()
        controller.screenLockedOrSleeping(Notification(name: NSWorkspace.willSleepNotification))
        controller.screenLockedOrSleeping(Notification(name: NSWorkspace.sessionDidResignActiveNotification))
        controller.loadModel()
        #expect(worker.starts == 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(worker.starts == 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(worker.starts == 2)
        #expect(controller.record == nil)
        #expect(!controller.isActive)
    }

    @Test func shutdownPreventsDeferredPreparationAndWake() {
        let (controller, worker, _) = fixture()
        controller.shutdown()
        controller.loadModel()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(worker.starts == 0)
        #expect(controller.record == nil)
    }

    @Test func cancelInferencePreparesNextDictationAndRejectsOldResult() throws {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        controller.loadModel()
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let old = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        controller.cancel()
        #expect(worker.starts == 2)
        #expect(!controller.isActive)
        #expect(controller.record == nil)
        controller.receive(.init(type: "result", id: old.uuidString, text: "Old result"))
        #expect(controller.latestText.isEmpty)
    }

    @Test func cancellationRejectsLateTranscriptAndReleasesColdAudio() throws {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let old = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1, 0.2], rate: 16000))
        #expect(worker.requests.isEmpty)
        controller.cancel(restart: false)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        controller.receive(.init(type: "result", id: old.uuidString, text: "Stale transcript"))
        #expect(worker.requests.isEmpty)
        #expect(controller.latestText.isEmpty)
        #expect(controller.scratch.string.isEmpty)
        #expect(!controller.isActive)
    }

    @Test func coldAudioIsSentOnlyOnceModelIsReady() throws {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        let id = try #require(controller.request)
        controller.send(AudioPacket(samples: [0.1, 0.2], rate: 48000))
        #expect(worker.requests.isEmpty)
        worker.ready = true
        controller.receive(.init(type: "ready", version: 1))
        #expect(worker.requests == [id])
        #expect(worker.lastRate == 48000)
        controller.cancel(restart: false)
        #expect(worker.stops > 0)
    }

    @Test func escapeConflictPreventsAudioJob() throws {
        let (controller, _, escape) = fixture()
        defer { controller.shutdown() }
        escape.registrationResult = .conflict
        #expect(throws: DictationError.self) { try controller.begin(target: InsertionTarget(local: controller.scratch)) }
        #expect(controller.request == nil)
        #expect(controller.record == nil)
    }

    @Test func failedModelStartDiscardsJob() throws {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        controller.receive(.init(type: "fatal", message: "Synthetic failure"))
        #expect(!controller.isActive)
        #expect(controller.record == nil)
        #expect(controller.phase == "unloaded")
        #expect(worker.stops > 0)
    }

    @Test func readingCancelsDictationAndStopsItsModelBeforeSelection() async throws {
        let (controller, worker, _) = fixture()
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, escapeMonitor: EscapeFake(), dictation: controller)
        defer { controller.shutdown() }
        worker.ready = true
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        controller.send(AudioPacket(samples: [0.1], rate: 16000))
        model.enqueuePrimaryShortcut()
        #expect(!controller.isActive)
        #expect(!worker.ready)
        await model.waitForInteractionToSettle()
        #expect(selection.startCount == 1)
        model.enqueueStopRequest()
        await model.waitForInteractionToSettle()
    }

    @Test func dictationStopsReadingBeforeItsActivationCallback() async {
        let (controller, _, _) = fixture()
        let selection = RegionSelectionControllerFake(), speech = SpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, escapeMonitor: EscapeFake(), speechService: speech, dictation: controller)
        defer { controller.shutdown() }
        await model.handleReadRequest()
        #expect(model.status == .selecting)
        var callback = false
        controller.onActivation? {
            #expect(speech.stopped)
            #expect(model.status == .stopped)
            #expect(selection.cancelCount > 0)
            callback = true
        }
        await model.waitForInteractionToSettle()
        #expect(callback)
    }

    /// A worker that reports why it cannot load and exits at once: the specific
    /// reason must reach the user, not the generic "process ended".
    @Test func workerFatalMessageWinsOverItsOwnExit() async throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-fatal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: resources) }
        let bin = resources.appendingPathComponent("Python/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // The worker sandbox lets only the interpreter itself run, so a `#!/bin/sh` stand-in
        // would be refused. A signed zsh copy runs worker.py as a script without any exec.
        let python = bin.appendingPathComponent("python3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/zsh"), to: python)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", python.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        try "print -r -- '{\"type\":\"fatal\",\"code\":\"load_failed\"}'\nexit 1\n"
            .write(to: resources.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        let worker = DictationWorker()
        defer { worker.stop() }
        for _ in 0..<12 {
            var messages: [DictationWorkerMessage] = []
            worker.onMessage = { messages.append($0) }
            worker.start(resources: resources, model: .whisperTurbo, modelRoot: nil)
            for _ in 0..<500 where messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            // Give a late generic report the chance to arrive, too.
            try await Task.sleep(for: .milliseconds(700))
            #expect(messages.map(\.type) == ["fatal"])
            #expect(messages.first?.code == "load_failed")
            #expect(!worker.running)
        }
    }

    @Test func dictationShortcutCannotBeReassignedToReading() async {
        let store = MemoryShortcutStore()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store,
            hotkeyManager: HotkeyManagerFake(registrationResult: .registered))
        model.enqueueShortcutChange(.dictationDefault)
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == .default)
        #expect(store.saved == nil)
        #expect(model.shortcutNotice?.contains("dictation") == true)
    }
}

@MainActor
private final class DictationWorkerFake: DictationTranscribing {
    var onMessage: ((DictationWorkerMessage) -> Void)?
    var ready = false
    var running = false
    var starts = 0, stops = 0
    var models: [DictationModel] = []
    var requests: [UUID] = []
    var lastRate = 0.0
    var modelRoots: [URL?] = []
    func start(resources: URL, model: DictationModel, modelRoot: URL?) {
        starts += 1; running = true; models.append(model); modelRoots.append(modelRoot)
    }
    func stop() { stops += 1; ready = false; running = false }
    var languages: [String?] = []
    var vocabularies: [[String]] = []
    func transcribe(_ audio: AudioPacket, id: UUID, language: String?, vocabulary: [String]) {
        requests.append(id); lastRate = audio.rate; languages.append(language); vocabularies.append(vocabulary)
    }
}

// The tap is an Objective-C callback type without Sendable conformance. This
// test transfers only the callback; each PCM buffer is created/consumed on its
// invoking background thread, as AVAudioEngine does. No microphone is opened.
private final class AudioTapInvocation: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    init(block: @escaping AVAudioNodeTapBlock) { self.block = block }
    func invokeStereoBuffer() throws -> Bool {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        let left: [Float] = [1, -0.5, 0.25, 0.5]
        let right: [Float] = [0, 0, -0.25, 1]
        for i in 0..<4 { channels[0][i] = left[i]; channels[1][i] = right[i] }
        block(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
        return !Thread.isMainThread
    }
}

/// Small stand-in manifests and payloads; no network and no real model weights.
enum DictationModelFixture {
    static let largeFiles: [String: Data] = [
        "config.json": Data(#"{"n_mels":128}"#.utf8),
        "model.safetensors": Data(repeating: 7, count: 4096),
    ]

    static func sha256(_ data: Data) -> String {
        SHA256Digest.hex(of: data)
    }

    static func resources(bundling bundled: Set<DictationModel>,
                          largeWeights: Data = largeFiles["model.safetensors"]!) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-store-\(UUID())")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Licenses"), withIntermediateDirectories: true)
        let license = Data("MIT License".utf8)
        try license.write(to: root.appendingPathComponent("Licenses/LICENSE-OpenAI"))
        for model in bundled {
            try manager.createDirectory(at: root.appendingPathComponent(model.directoryName), withIntermediateDirectories: true)
        }
        let config = largeFiles["config.json"]!
        let large: [String: Any] = [
            "repo": "mlx-community/whisper-large-v3-8bit",
            "revision": "7fede54fd97b154a4f5e476646484fc023b1bcdf",
            "files": [
                ["rfilename": ".gitattributes", "size": 3],
                ["rfilename": "config.json", "size": config.count, "verified_sha256": sha256(config)],
                ["rfilename": "weights.safetensors", "source_filename": "model.safetensors",
                 "size": largeWeights.count, "verified_sha256": sha256(largeWeights)],
                ["rfilename": "LICENSE-OpenAI", "size": license.count, "verified_sha256": sha256(license),
                 "source": "https://raw.githubusercontent.com/openai/whisper/v20240930/LICENSE"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: large)
            .write(to: root.appendingPathComponent(DictationModel.whisperLargeV3.manifestName))
        return root
    }
}

/// Serves fixed payloads by file name, records requests and can wait until cancelled.
final class DictationFetcherFake: DictationModelFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let files: [String: Data]
    private let waitsForCancellation: Bool
    private var recorded: [URL] = []
    private var sizes: [Int64] = []
    var requests: [URL] { lock.withLock { recorded } }
    var expectedSizes: [Int64] { lock.withLock { sizes } }

    init(files: [String: Data] = [:], waitsForCancellation: Bool = false) {
        self.files = files
        self.waitsForCancellation = waitsForCancellation
    }

    func fetch(_ url: URL, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { recorded.append(url); sizes.append(expectedSize) }
        if waitsForCancellation { try await Task.sleep(for: .seconds(30)) }
        guard let data = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        try data.write(to: destination)
        progress(Int64(data.count))
    }
}

@Suite("Dictation model installation", .serialized)
@MainActor
struct DictationModelInstallationTests {
    @Test func bundledModelsAreInstalledAndOthersCanBeInstalled() throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let store = DictationModelStore(resources: resources,
            installRoot: resources.appendingPathComponent("Installed"), fetcher: DictationFetcherFake())
        #expect(store.availability[.whisperTurbo] == .installed)
        #expect(store.availability[.whisperLargeV3] == .notInstalled)
        #expect(store.availability[.qwen] == .notInstalled)
        #expect(store.modelRoot(for: .whisperTurbo) == nil)
        #expect(store.downloadSize(of: .whisperLargeV3) == Int64(4110), "Weights plus config; bundled licenses are not downloaded.")
    }

    @Test func unsupportedBackendCannotUseOldModelsOrStartDownloads() async throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo, .qwen])
        try Data(#"{"whisper-turbo":"whisper.cpp"}"#.utf8)
            .write(to: resources.appendingPathComponent("runtime-backends.json"))
        let fetcher = DictationFetcherFake()
        let store = DictationModelStore(resources: resources,
            installRoot: resources.appendingPathComponent("Installed"), fetcher: fetcher)
        #expect(store.isInstalled(.whisperTurbo))
        #expect(!store.isInstalled(.qwen))
        #expect(!store.canDownload(.qwen))
        #expect(!store.canDownload(.whisperLargeV3))
        await store.install(.qwen).value
        #expect(fetcher.requests.isEmpty)
    }

    @Test func installDownloadsPinnedFilesVerifiesThemAndOnlyThenMovesThemIntoPlace() async throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let installRoot = resources.appendingPathComponent("Installed")
        let fetcher = DictationFetcherFake(files: DictationModelFixture.largeFiles)
        let store = DictationModelStore(resources: resources, installRoot: installRoot, fetcher: fetcher)
        let leftover = installRoot.appendingPathComponent(".staging-WhisperLargeV3-from-a-quit-app")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        await store.install(.whisperLargeV3).value
        #expect(store.availability[.whisperLargeV3] == .installed)
        #expect(store.modelRoot(for: .whisperLargeV3) == installRoot)
        let base = "https://huggingface.co/mlx-community/whisper-large-v3-8bit/resolve/7fede54fd97b154a4f5e476646484fc023b1bcdf/"
        #expect(fetcher.requests.map(\.absoluteString) == [base + "config.json", base + "model.safetensors"],
                "Only pinned Hugging Face files are requested; licenses come from the app bundle.")
        let directory = installRoot.appendingPathComponent("WhisperLargeV3")
        #expect(try Data(contentsOf: directory.appendingPathComponent("weights.safetensors"))
                == DictationModelFixture.largeFiles["model.safetensors"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("LICENSE-OpenAI").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: installRoot.path) == ["WhisperLargeV3"],
                "No staging data remains after a successful install.")
    }

    @Test func downloadsAreBoundToTheirPinnedSizeAndInstalledFilesAreReadOnly() async throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let installRoot = resources.appendingPathComponent("Installed")
        let fetcher = DictationFetcherFake(files: DictationModelFixture.largeFiles)
        let store = DictationModelStore(resources: resources, installRoot: installRoot, fetcher: fetcher)
        await store.install(.whisperLargeV3).value
        #expect(store.availability[.whisperLargeV3] == .installed)
        #expect(fetcher.expectedSizes == [DictationModelFixture.largeFiles["config.json"]!.count,
                                          DictationModelFixture.largeFiles["model.safetensors"]!.count].map(Int64.init),
                "Every request carries the manifest size the response must not exceed.")
        let weights = installRoot.appendingPathComponent("WhisperLargeV3/weights.safetensors")
        let mode = try FileManager.default.attributesOfItem(atPath: weights.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o444)
        #expect(!FileManager.default.isWritableFile(atPath: weights.path))
    }

    @Test func pinnedSizeRuleStopsOversizedOrMisannouncedDownloads() {
        #expect(!DictationDownloadSize.violatesPin(written: 10, announced: 100, expected: 100))
        #expect(!DictationDownloadSize.violatesPin(written: 100, announced: -1, expected: 100),
                "Unknown Content-Length is allowed up to the pinned size.")
        #expect(DictationDownloadSize.violatesPin(written: 101, announced: -1, expected: 100))
        #expect(DictationDownloadSize.violatesPin(written: 1, announced: 99, expected: 100))
        #expect(DictationDownloadSize.violatesPin(written: 1, announced: 5_000_000_000, expected: 100))
    }

    @Test func staleStagingFoldersFromACrashAreRemovedWhenTheStoreStarts() throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let installRoot = resources.appendingPathComponent("Installed")
        let manager = FileManager.default
        for name in [".staging-WhisperLargeV3-crashed", ".staging-Model-crashed"] {
            let folder = installRoot.appendingPathComponent(name)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("weights.safetensors"))
        }
        try manager.createDirectory(at: installRoot.appendingPathComponent("Unrelated"), withIntermediateDirectories: true)
        _ = DictationModelStore(resources: resources, installRoot: installRoot, fetcher: DictationFetcherFake())
        #expect(try manager.contentsOfDirectory(atPath: installRoot.path) == ["Unrelated"])
    }

    @Test func hashMismatchInstallsNothing() async throws {
        let resources = try DictationModelFixture.resources(
            bundling: [.whisperTurbo], largeWeights: Data(repeating: 1, count: 4096))
        let installRoot = resources.appendingPathComponent("Installed")
        let store = DictationModelStore(resources: resources, installRoot: installRoot,
            fetcher: DictationFetcherFake(files: DictationModelFixture.largeFiles))
        await store.install(.whisperLargeV3).value
        guard case .failed = store.availability[.whisperLargeV3] else {
            Issue.record("Expected a visible failure, got \(String(describing: store.availability[.whisperLargeV3]))")
            return
        }
        #expect(store.modelRoot(for: .whisperLargeV3) == nil)
        #expect(!FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("WhisperLargeV3").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: installRoot.path)) ?? [] == [])
    }

    @Test func cancellingAnInstallLeavesNothingBehind() async throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let installRoot = resources.appendingPathComponent("Installed")
        let store = DictationModelStore(resources: resources, installRoot: installRoot,
            fetcher: DictationFetcherFake(files: DictationModelFixture.largeFiles, waitsForCancellation: true))
        let task = store.install(.whisperLargeV3)
        guard case .installing = store.availability[.whisperLargeV3] else {
            Issue.record("Install did not start"); return
        }
        store.cancelInstall(.whisperLargeV3)
        await task.value
        #expect(store.availability[.whisperLargeV3] == .notInstalled)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: installRoot.path)) ?? [] == [])
    }

    /// Opt-in real download: `TEST_RUNNER_SAYWING_LIVE_MODEL_INSTALL=/abs/Saywing.app/Contents/Resources/Dictation`.
    /// Installs Whisper Large v3 from Hugging Face into `$TMPDIR/saywing-live-install` for the worker check.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAYWING_LIVE_MODEL_INSTALL"] != nil))
    func liveInstallFromHuggingFace() async throws {
        let resources = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SAYWING_LIVE_MODEL_INSTALL"]))
        let installRoot = FileManager.default.temporaryDirectory.appendingPathComponent("saywing-live-install")
        try? FileManager.default.removeItem(at: installRoot)
        let store = DictationModelStore(resources: resources, installRoot: installRoot)
        #expect(store.availability[.whisperLargeV3] == .notInstalled)
        let started = Date()
        await store.install(.whisperLargeV3).value
        #expect(store.availability[.whisperLargeV3] == .installed)
        #expect(store.modelRoot(for: .whisperLargeV3) == installRoot)
        print("LIVE INSTALL", installRoot.path, "seconds", Int(Date().timeIntervalSince(started)))
    }

    @Test func downloadsAndRedirectsStayOnHuggingFaceOverHTTPS() {
        #expect(URLSessionModelFetcher.allows(URL(string: "https://huggingface.co/mlx-community/x")!))
        #expect(URLSessionModelFetcher.allows(URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/abc")!))
        #expect(URLSessionModelFetcher.allows(URL(string: "https://cas-bridge.xethub.hf.co/x")!))
        #expect(!URLSessionModelFetcher.allows(URL(string: "http://huggingface.co/x")!))
        #expect(!URLSessionModelFetcher.allows(URL(string: "https://evilhf.co/x")!))
        #expect(!URLSessionModelFetcher.allows(URL(string: "https://huggingface.co.example.com/x")!))
    }

    /// Installs made before a manifest listed its license text (Qwen3-ASR) must keep
    /// loading: the bundled text is added locally, never downloaded, never overwritten.
    @Test func olderInstallsReceiveBundledLicenseTextsWithoutDownloading() throws {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let installRoot = resources.appendingPathComponent("Installed")
        let model = installRoot.appendingPathComponent(DictationModel.whisperLargeV3.directoryName)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let fetcher = DictationFetcherFake()
        let store = DictationModelStore(resources: resources, installRoot: installRoot, fetcher: fetcher)
        #expect(store.isInstalled(.whisperLargeV3))
        #expect(try Data(contentsOf: model.appendingPathComponent("LICENSE-OpenAI")) == Data("MIT License".utf8))
        #expect(fetcher.requests.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("WhisperTurbo/LICENSE-OpenAI").path), "Signed bundle stays unchanged.")

        try Data("kept".utf8).write(to: model.appendingPathComponent("LICENSE-OpenAI"))
        _ = DictationModelStore(resources: resources, installRoot: installRoot, fetcher: fetcher)
        #expect(try Data(contentsOf: model.appendingPathComponent("LICENSE-OpenAI")) == Data("kept".utf8))
    }
}

@Suite("Fn dictation gestures")
struct FnDictationGestureTests {
    @Test func holdReleasesToInsert() {
        var state = FnDictationGesture()
        #expect(state.press(at: 0) == [.start])
        #expect(state.release(at: 0.7) == [.finish])
        #expect(state.expire(at: 2).isEmpty)
    }
    @Test func singleTapCancelsWithoutPasting() {
        var state = FnDictationGesture()
        _ = state.press(at: 0)
        #expect(state.release(at: 0.1).isEmpty)
        #expect(state.expire(at: 0.49).isEmpty)
        #expect(state.expire(at: 0.5) == [.cancel])
    }
    @Test func doubleTapLocksAndNextTapFinishes() {
        var state = FnDictationGesture()
        _ = state.press(at: 0); _ = state.release(at: 0.1)
        #expect(state.press(at: 0.2) == [.lock])
        #expect(state.release(at: 0.3).isEmpty)
        #expect(state.expire(at: 2).isEmpty)
        #expect(state.press(at: 3).isEmpty)
        #expect(state.release(at: 3.1) == [.finish])
    }
    @Test func thirdQuickTapDiscards() {
        var state = FnDictationGesture()
        _ = state.press(at: 0); _ = state.release(at: 0.1)
        _ = state.press(at: 0.2); _ = state.release(at: 0.25)
        _ = state.press(at: 0.3)
        #expect(state.release(at: 0.35) == [.cancel])
    }
    @Test func fnSpaceLocksAndTogglesWithoutReleaseInsertion() {
        var state = FnDictationGesture()
        _ = state.press(at: 0)
        #expect(state.space(at: 0.1) == [.lock])
        #expect(state.release(at: 0.2).isEmpty)
        _ = state.press(at: 3)
        #expect(state.space(at: 3.1) == [.finish])
        #expect(state.release(at: 3.2).isEmpty)
    }
    @Test func otherFnCombinationsDoNotDictate() {
        var state = FnDictationGesture()
        _ = state.press(at: 0)
        #expect(state.otherKey() == [.cancel])
        #expect(state.release(at: 1).isEmpty)
        #expect(state.expire(at: 2).isEmpty)
    }
    @Test func resetRejectsLateReleaseAndTimeout() {
        var state = FnDictationGesture()
        _ = state.press(at: 0); _ = state.release(at: 0.1)
        state.reset()
        #expect(state.release(at: 1).isEmpty)
        #expect(state.expire(at: 2).isEmpty)
    }
    @Test @MainActor func readingDefaultUsesTwoKeysAndPreservesSavedShortcuts() {
        #expect(ShortcutConfiguration.default == ShortcutConfiguration(key: "R", modifiers: UInt32(optionKey)))
        let store = MemoryShortcutStore()
        store.save(ShortcutConfiguration(key: "Y", modifiers: UInt32(cmdKey | shiftKey)))
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store, hotkeyManager: HotkeyManagerFake(registrationResult: .registered))
        #expect(model.shortcutConfiguration == .previousDefault)
        #expect(store.saved == .previousDefault)
        let custom = ShortcutConfiguration(key: "K", modifiers: UInt32(controlKey | shiftKey))
        store.save(custom)
        let customModel = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: store, hotkeyManager: HotkeyManagerFake(registrationResult: .registered))
        #expect(customModel.shortcutConfiguration == custom)
    }
}

@Suite(.serialized)
@MainActor
struct DictationCapsuleTests {
    @Test(arguments: [false, true])
    func bothActivitiesShareTheQuietMeterAndVisualHeight(reducedMotion: Bool) {
        let reading = ReadingControlView(frame: CGRect(origin: .zero, size: ReadingControlView.Metrics.surface))
        let dictation = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        defer { reading.stopAnimating(); dictation.stopAnimating() }
        reading.present(.speaking, opening: true, action: {})
        dictation.present(.recording, title: "", detail: "")
        dictation.updateRecording(rms: 0.08)
        reading.setLevel(dictation.inputLevel)
        let start = CACurrentMediaTime()
        for frame in 1...120 {
            let time = start + Double(frame) / 60
            reading.tick(now: time, reducedMotion: reducedMotion)
            dictation.drawFrame(now: time, reducedMotion: reducedMotion)
        }
        #expect(reading.visualBodyFrame.height == dictation.bodyFrame.height)
        #expect(reading.barHeights.count == 9 && dictation.barHeights.count == 9)
        if reducedMotion {
            #expect(reading.barHeights.allSatisfy { $0 == 4 })
        } else {
            #expect(reading.barHeights.allSatisfy { $0 > 2 })
        }
        for (a, b) in zip(reading.barHeights, dictation.barHeights) {
            #expect(abs(a - Double(b)) < 0.01)
        }
        reading.setLevel(0)
        dictation.updateRecording(rms: 0)
        for frame in 121...360 {
            let time = start + Double(frame) / 60
            reading.tick(now: time, reducedMotion: reducedMotion)
            dictation.drawFrame(now: time, reducedMotion: reducedMotion)
        }
        // Reduced Motion keeps the fixed indicator; animated meters settle to silence.
        let quietHeight = reducedMotion ? 4.0 : 2.0
        #expect(reading.barHeights.allSatisfy { abs($0 - quietHeight) < 0.01 })
        #expect(dictation.barHeights.allSatisfy { abs(Double($0) - quietHeight) < 0.01 })
    }

    @Test func meterResponseDoesNotDependOnRefreshRate() {
        func response(hz: Int) -> Double {
            var level = 0.0
            for _ in 0..<hz / 4 {
                level = SaywingCapsuleStyle.smooth(level, toward: 0.8, dt: 1 / Double(hz))
            }
            for _ in 0..<hz / 4 {
                level = SaywingCapsuleStyle.smooth(level, toward: 0, dt: 1 / Double(hz))
            }
            return level
        }
        #expect(abs(response(hz: 60) - response(hz: 120)) < 0.000001)
    }

    @Test func dictationDisplayClockDoesNotRetainItsView() async throws {
        weak var released: DictationCapsuleView?
        do {
            let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
            released = view
            view.present(.recording, title: "", detail: "")
            view.show()
            try await Task.sleep(for: .milliseconds(35))
        }
        try await Task.sleep(for: .milliseconds(35))
        #expect(released == nil)
    }

    /// Actual AppKit views at equal scale, using synthetic levels only.
    @Test func renderSharedCapsuleSpecimen() throws {
        guard let path = ProcessInfo.processInfo.environment["SAYWING_DICTATION_RENDER_DIR"] else { return }
        let canvas = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 330))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = ReadingPalette.paper.cgColor
        func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: size, weight: .medium)
            label.textColor = ReadingPalette.ink
            label.frame = CGRect(x: x, y: y, width: size > 12 ? 460 : 180, height: 22)
            canvas.addSubview(label)
        }
        label("Saywing · Eine gemeinsame Form", x: 30, y: 285, size: 17)
        label("Vorlesen", x: 100, y: 250, size: 12)
        label("Diktieren", x: 332, y: 250, size: 12)
        for (index, pair) in [(ReadingPanelState.speaking, DictationCapsuleState.recording),
                              (.preparing, .processing), (.finished, .inserted)].enumerated() {
            let y = CGFloat(175 - index * 72)
            let reading = ReadingControlView(frame: CGRect(x: -4, y: y, width: 300, height: 92))
            let dictation = DictationCapsuleView(frame: CGRect(x: 293, y: y + 16, width: 152, height: 60))
            canvas.addSubview(reading)
            canvas.addSubview(dictation)
            reading.present(pair.0, opening: false, action: {})
            dictation.present(pair.1, title: "", detail: "")
            dictation.updateRecording(rms: 0.08)
            reading.setLevel(dictation.inputLevel)
            let start = CACurrentMediaTime()
            for frame in 1...120 {
                reading.tick(now: start + Double(frame) / 60, reducedMotion: false)
                dictation.drawFrame(now: start + Double(frame) / 60, reducedMotion: false)
            }
            reading.stopAnimating()
            dictation.stopAnimating()
        }
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("saywing-together.png"))
    }

    @Test func recordingControlsStaySeparateAndNeverTakeFocus() {
        let panel = DictationStatusPanel(contentRect: CGRect(origin: .zero, size: DictationCapsuleView.surface),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        panel.contentView = view
        defer { panel.orderOut(nil) }
        var finished = 0, discarded = 0
        view.onFinish = { finished += 1 }
        view.onDismiss = { discarded += 1 }
        view.present(.recording, title: "Aufnahme", detail: "Esc verwirft.")
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(view.finishButton.frame.size == CGSize(width: 32, height: 44))
        #expect(view.dismissButton.frame.size == CGSize(width: 32, height: 44))
        #expect(!view.finishButton.frame.intersects(view.dismissButton.frame))
        view.finishButton.performClick(nil)
        view.dismissButton.performClick(nil)
        #expect(finished == 1 && discarded == 1)
        view.present(.processing, title: "Text wird erkannt …", detail: "Lokal auf deinem Mac")
        view.finishButton.performClick(nil)
        #expect(finished == 1, "Late clicks must not finish a different phase.")
        #expect(view.finishButton.isHidden)
    }

    @Test func miniBarHasNoVisibleTextAndKeepsItsSizeAcrossStates() {
        let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        for state in DictationCapsuleState.allCases {
            view.present(state, title: "Status", detail: "Details")
            #expect(view.bodyFrame.size == CGSize(width: 120, height: 28))
            #expect(!descendants(view).contains { $0 is NSTextField }, "No text or timer in the floating bar.")
            #expect(!view.finishButton.frame.intersects(view.dismissButton.frame))
        }
    }

    @Test func inputMeterUsesAudioAndRejectsStaleOrInvalidLevels() {
        let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        view.present(.recording, title: "Aufnahme", detail: "")
        view.updateRecording(rms: 0)
        #expect(view.inputLevel == 0)
        #expect(view.accessibilityLabel()?.contains("Recording") == true)
        view.updateRecording(rms: 0.1)
        #expect(view.inputLevel > 0 && view.inputLevel <= 1)
        view.updateRecording(rms: .nan)
        #expect(view.inputLevel == 0)
        view.present(.processing, title: "Text wird erkannt …", detail: "")
        view.updateRecording(rms: 1)
        #expect(view.inputLevel == 0)
        #expect(view.accessibilityLabel()?.contains("Recognizing text") == true)
    }

    @Test func terminalFeedbackDoesNotImplyUnverifiedInsertion() {
        let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        view.present(.unconfirmed, title: "Einfügen ausgelöst", detail: "Bitte Zielfeld prüfen.")
        #expect(view.state == .unconfirmed)
        #expect(view.accessibilityHelp() == "Bitte Zielfeld prüfen.")
        #expect(view.accessibilityLabel()?.contains("Paste sent") == true)
        view.present(.inserted, title: "Eingefügt", detail: "Bereit für die nächste Aufnahme.")
        #expect(view.state == .inserted)
        #expect(view.finishButton.isHidden)
        #expect(view.dismissButton.accessibilityLabel() == "Close notice")
    }

    @Test func controllerDismissalPreservesResultsAndOldDismissalCannotHideActiveWork() throws {
        let worker = DictationWorkerFake()
        let controller = DictationController(resources: URL(fileURLWithPath: "/missing-dictation"),
            worker: worker, shortcut: HotkeyManagerFake(registrationResult: .registered),
            escape: HotkeyManagerFake(registrationResult: .registered), registerHotkey: false)
        defer { controller.shutdown() }
        controller.latestText = "Synthetic retained result"
        controller.result.string = controller.latestText
        controller.setStatus("Eingefügt", floating: true, capsuleState: .inserted)
        controller.capsule.dismissButton.performClick(nil)
        #expect(!controller.panel.isVisible)
        #expect(controller.latestText == "Synthetic retained result")
        controller.setStatus("Hinweis", floating: true)
        controller.hidePanelLater()
        let oldHide = try #require(controller.panelHide)
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        controller.phase = "processing"
        oldHide.perform()
        #expect(controller.panel.isVisible, "An old timer cannot hide an active request.")
        controller.setStatus("Text wird erkannt …", floating: true)
        controller.hidePanelLater()
        #expect(controller.capsule.state == .processing)
        controller.capsule.dismissButton.performClick(nil)
        #expect(!controller.isActive && !controller.panel.isVisible)
        #expect(!controller.capsule.isAnimating)
    }

    @Test func reducedMotionAndHiddenPanelStopAnimation() {
        let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
        view.present(.processing, title: "Text wird erkannt …", detail: "")
        view.show()
        #expect(view.isAnimating == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        view.drawFrame(now: 1, reducedMotion: true)
        let first = view.barHeights
        view.drawFrame(now: 20, reducedMotion: true)
        #expect(view.barHeights == first)
        view.stopAnimating()
        #expect(!view.isAnimating)
    }

    /// Native view-only design specimens. Synthetic levels, no microphone/screen capture.
    @Test func renderDictationStates() throws {
        guard let path = ProcessInfo.processInfo.environment["SAYWING_DICTATION_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in DictationCapsuleState.allCases {
            let view = DictationCapsuleView(frame: CGRect(origin: .zero, size: DictationCapsuleView.surface))
            view.present(state, title: state == .attention ? "Aufnahme nicht gestartet" : "", detail: "Bitte das Diktierfenster öffnen.")
            view.updateRecording(rms: 0.08)
            view.drawFrame(now: 1, reducedMotion: false)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("dictation-\(state.rawValue).png"))
            view.stopAnimating()
        }
    }
}

/// Opt-in design review of the windows: `OSR_WINDOW_PREVIEW_DIR=/path` (pass it to
/// xcodebuild as `TEST_RUNNER_OSR_WINDOW_PREVIEW_DIR`) renders every Settings tab,
/// Setup, the playback controls and the dictation test window to PNG.
@Suite("Window previews", .serialized)
@MainActor
struct WindowPreviewTests {
    @Test func exportWindowPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["OSR_WINDOW_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "com.christopherbobel.OpenScreenReader.window-preview.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let dictation = DictationController(resources: URL(fileURLWithPath: "/missing-dictation"),
            worker: DictationWorkerFake(), shortcut: HotkeyManagerFake(registrationResult: .registered),
            escape: HotkeyManagerFake(registrationResult: .registered), preferences: preferences, registerHotkey: false)
        defer { dictation.shutdown() }
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             preferences: preferences, dictation: dictation)
        func write(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
        }
        func render<V: View>(_ content: V, _ name: String) throws {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: appearance)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                try write(host, "\(name)-\(suffix)")
                window.contentView = nil
            }
        }
        for tab in [SettingsTab.general, .reading, .dictation, .shortcuts, .privacy] {
            try render(SettingsView(model: model, initialTab: tab), "settings-\(tab)")
        }
        for step in [SetupStep.welcome, .permission(.screenRecording), .permission(.inputMonitoring), .readingModel, .tryReading,
                     .dictationOffer, .permission(.microphone), .permission(.accessibility), .tryDictation, .done] {
            try render(SetupView(model: model, flow: SetupFlowController(model: model, permissions: PermissionStatus { _ in false }, start: step)),
                       "setup-\(step.previewName)")
        }
        try render(SetupView(model: model, flow: SetupFlowController(model: model, permissions: PermissionStatus { $0 == .screenRecording },
                                                                    start: .permission(.screenRecording))), "setup-screenRecording-granted")
        let termsRequired = AppModel(modelTerms: ModelTermsAcceptance(bundle: .main, store: MemoryModelTermsStore()),
                                     shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                                     preferences: preferences)
        try render(SetupView(model: termsRequired, flow: SetupFlowController(model: termsRequired, permissions: PermissionStatus { _ in true },
                                                                            start: .readingModel)), "setup-readingModel-terms-required")
        try render(SettingsView(model: termsRequired, initialTab: .reading), "settings-reading-terms-required")
        try render(ReadingErrorView(model: termsRequired).background(Color(nsColor: .windowBackgroundColor)), "reading-error-terms")
        try render(PlaybackControlsView(model: model).background(Color(nsColor: .windowBackgroundColor)), "playback-controls")
        try render(SystemSettingsGuideView(permission: .accessibility, onClose: {}), "setup-guide")
        let failing = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .conflict),
                               preferences: preferences)
        // Popovers bring their own material; offscreen they need a background to be legible.
        try render(ReadingErrorView(model: failing).background(Color(nsColor: .windowBackgroundColor)), "reading-error-help")
        let overlay = RegionSelectionOverlayController(defaults: preferences)
        overlay.start(onSelection: { _ in }, onCancel: { _ in })
        if let view = NSApp.windows.first(where: { $0.title == "Select Screen Region" && $0.isVisible })?.contentView,
           let pill = view.subviews.first {
            let area = pill.frame.insetBy(dx: -60, dy: -30)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: area))
            view.cacheDisplay(in: area, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("selection-hint.png"))
        }
        overlay.cancel()
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            dictation.window.appearance = NSAppearance(named: appearance)
            // The frame view draws the window background behind the AppKit labels.
            try write(try #require(dictation.window.contentView?.superview), "dictation-window-\(suffix)")
        }
    }
}

@Suite("Setup models and shortcuts", .serialized)
@MainActor
struct SetupConfigurationTests {
    private func fixture(fetcher: DictationFetcherFake = DictationFetcherFake()) throws
        -> (DictationController, HotkeyManagerFake, UserDefaults, URL) {
        let resources = try DictationModelFixture.resources(bundling: [.whisperTurbo])
        let defaults = UserDefaults(suiteName: "com.christopherbobel.OpenScreenReader.setup-config.\(UUID())")!
        let hotkey = HotkeyManagerFake(registrationResult: .registered)
        let store = DictationModelStore(resources: resources, installRoot: resources.appendingPathComponent("Installed"), fetcher: fetcher)
        let controller = DictationController(resources: resources, models: store, worker: DictationWorkerFake(),
            shortcut: hotkey, escape: HotkeyManagerFake(registrationResult: .registered),
            preferences: defaults, registerHotkey: false)
        return (controller, hotkey, defaults, resources)
    }

    @Test func dictationShortcutSavesOnlyAfterSuccessfulRegistration() throws {
        let (controller, hotkey, defaults, root) = try fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: root) }
        let custom = ShortcutConfiguration(key: "D", modifiers: UInt32(controlKey | optionKey))
        controller.changeShortcut(custom)
        #expect(controller.shortcutConfiguration == custom)
        let stored = UserDefaultsShortcutStore(defaults: defaults, preferenceKey: "dictationShortcut.v1")
        #expect(stored.load() == custom)
        hotkey.registrationResult = .conflict
        controller.changeShortcut(.dictationDefault)
        #expect(controller.shortcutConfiguration == custom)
        #expect(stored.load() == custom)
        #expect(controller.shortcutNotice != nil)
        controller.setFnEnabled(false)
        let restored = DictationController(resources: root, models: controller.models, worker: DictationWorkerFake(),
            shortcut: HotkeyManagerFake(registrationResult: .registered), preferences: defaults, registerHotkey: false)
        defer { restored.shutdown() }
        #expect(restored.shortcutConfiguration == custom)
        #expect(!restored.fnEnabled)
        #expect(restored.record == nil)
    }

    @Test func recordingAKeySuspendsDictationAndRejectsLateActivation() throws {
        let (controller, hotkey, _, root) = try fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered), dictation: controller)
        let activation = hotkey.onPress
        model.setRecordingShortcut(true)
        #expect(controller.shortcutsSuspended)
        activation?()
        controller.refreshPermissions()
        #expect(!controller.isActive)
        #expect(controller.record == nil)
        model.setRecordingShortcut(false)
        #expect(!controller.shortcutsSuspended)
    }

    @Test func allThreeShortcutsHaveDistinctAssignments() async throws {
        let (controller, _, _, root) = try fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: root) }
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            queueHotkeyManager: HotkeyManagerFake(registrationResult: .registered), queueShortcutStore: MemoryShortcutStore(), dictation: controller)
        model.enqueueDictationShortcutChange(model.shortcutConfiguration)
        await model.waitForInteractionToSettle()
        #expect(controller.shortcutConfiguration == .dictationDefault)
        let custom = ShortcutConfiguration(key: "D", modifiers: UInt32(controlKey | optionKey))
        model.enqueueDictationShortcutChange(custom)
        await model.waitForInteractionToSettle()
        #expect(controller.shortcutConfiguration == custom)
        model.enqueueShortcutChange(custom)
        model.enqueueQueueShortcutChange(custom)
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == .default)
        #expect(model.queueShortcutConfiguration == .queueDefault)
        model.enqueueShortcutChange(.dictationDefault)
        await model.waitForInteractionToSettle()
        #expect(model.shortcutConfiguration == .dictationDefault, "The old dictation key is no longer reserved.")
    }

    @Test func interruptedInstallRestoresIntentWithoutStartingNetworkOrRecording() throws {
        let fetcher = DictationFetcherFake()
        let (controller, _, defaults, root) = try fixture(fetcher: fetcher)
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: root) }
        defaults.set(DictationModel.whisperLargeV3.rawValue, forKey: "dictationInstallIntent.v1")
        let restored = DictationController(resources: root, models: controller.models, worker: DictationWorkerFake(),
            shortcut: HotkeyManagerFake(registrationResult: .registered), preferences: defaults, registerHotkey: false)
        defer { restored.shutdown() }
        #expect(restored.pendingInstallModel == .whisperLargeV3)
        #expect(restored.models.availability[.whisperLargeV3] == .notInstalled)
        #expect(fetcher.requests.isEmpty)
        #expect(restored.record == nil)
    }

    @Test func confirmedDownloadSwitchesOnlyAfterVerificationAndClearsIntent() async throws {
        let fetcher = DictationFetcherFake(files: DictationModelFixture.largeFiles)
        let (controller, _, defaults, root) = try fixture(fetcher: fetcher)
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = try #require(controller.install(.whisperLargeV3))
        #expect(controller.pendingInstallModel == .whisperLargeV3)
        #expect(controller.selectedModel == .whisperTurbo)
        await task.value
        #expect(controller.selectedModel == .whisperLargeV3)
        #expect(controller.pendingInstallModel == nil)
        #expect(defaults.string(forKey: "dictationInstallIntent.v1") == nil)
        #expect(controller.record == nil)
    }

    @Test func changingChoiceWhileDownloadingCannotBeUndoneByItsCompletion() async throws {
        let fetcher = DictationFetcherFake(files: DictationModelFixture.largeFiles)
        let (controller, _, _, root) = try fixture(fetcher: fetcher)
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = try #require(controller.install(.whisperLargeV3))
        controller.selectModel(.whisperTurbo)
        await task.value
        #expect(controller.selectedModel == .whisperTurbo)
        #expect(controller.pendingInstallModel == nil)
    }
}

/// Records what dictation asks of the pasteboard, including options that NSPasteboard cannot report back.
final class RecordingPasteboard: DictationPasteboard {
    private(set) var changeCount = 0
    private(set) var pasteboardItems: [NSPasteboardItem]? = []
    private(set) var preparedOptions: [NSPasteboard.ContentsOptions] = []

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        preparedOptions.append(options)
        changeCount += 1
        pasteboardItems = []
        return changeCount
    }
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        pasteboardItems = (pasteboardItems ?? []) + objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        pasteboardItems?.first?.string(forType: dataType)
    }
    /// Another app's copy: a new change count and new contents.
    func copy(_ types: [String: Data]) {
        changeCount += 1
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: .init(type)) }
        pasteboardItems = [item]
    }
    var types: Set<String> { Set(pasteboardItems?.flatMap { $0.types.map(\.rawValue) } ?? []) }
}

@Suite("Dictation clipboard privacy", .serialized)
@MainActor
struct DictationClipboardPrivacyTests {
    @Test func transcriptIsMarkedForClipboardManagersAndStaysOnThisMac() throws {
        let board = RecordingPasteboard()
        board.copy([NSPasteboard.PasteboardType.string.rawValue: Data("Original".utf8)])
        let lease = try ClipboardLease.begin("Diktat", on: board)
        #expect(board.string(forType: .string) == "Diktat")
        #expect(board.types.isSuperset(of: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                            "org.nspasteboard.AutoGeneratedType"]))
        #expect(!lease.clearsInsteadOfRestoring)
        #expect(lease.restore())
        #expect(board.string(forType: .string) == "Original")
        #expect(!board.types.contains("org.nspasteboard.TransientType"), "Restored data carries no added markers.")
        #expect(board.preparedOptions == [.currentHostOnly, .currentHostOnly],
                "Neither the transcript nor the restored clipboard reaches Universal Clipboard.")
    }

    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                      "org.nspasteboard.AutoGeneratedType"])
    func passwordManagerItemsAreClearedInsteadOfRestored(marker: String) throws {
        let board = RecordingPasteboard()
        board.copy([NSPasteboard.PasteboardType.string.rawValue: Data("hunter2".utf8), marker: Data()])
        let lease = try ClipboardLease.begin("Diktat", on: board)
        #expect(lease.clearsInsteadOfRestoring)
        #expect(lease.restore())
        #expect(board.pasteboardItems?.isEmpty == true, "Putting the password back would stop its timed clearing.")
        #expect(board.string(forType: .string) == nil)
        #expect(board.preparedOptions == [.currentHostOnly, .currentHostOnly])
    }

    @Test func newerCopiesWinOverClearingAndRestoring() throws {
        for original in [[NSPasteboard.PasteboardType.string.rawValue: Data("Original".utf8)],
                         [NSPasteboard.PasteboardType.string.rawValue: Data("hunter2".utf8),
                          "org.nspasteboard.ConcealedType": Data()]] {
            let board = RecordingPasteboard()
            board.copy(original)
            let lease = try ClipboardLease.begin("Diktat", on: board)
            board.copy([NSPasteboard.PasteboardType.string.rawValue: Data("New copy".utf8)])
            #expect(!lease.restore())
            #expect(board.string(forType: .string) == "New copy")
        }
    }

    @Test func promisedFilesAreRefusedFromTheTypeListAlone() {
        let board = RecordingPasteboard()
        board.copy(["com.apple.NSFilePromiseItemMetaData": Data([1]), "public.file-url": Data("file:///x".utf8)])
        let before = board.changeCount
        #expect(throws: DictationError.self) { _ = try ClipboardLease.begin("Diktat", on: board) }
        #expect(board.changeCount == before, "A refused clipboard stays untouched.")
    }
}

@Suite("Local worker sandbox", .serialized)
struct WorkerSandboxTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// An ad-hoc signed copy of `/bin/cat` stands in for the bundled interpreter at `bin/python3`.
    private static func interpreter(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: python)
        // A copied platform binary is killed at launch until it carries its own signature.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", python.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        return python
    }

    @Test func bundledProfileFileIsTheAppProfile() throws {
        let file = try String(contentsOf: Self.repository.appendingPathComponent("Runtime/Dictation/worker.sb"), encoding: .utf8)
        #expect(file == WorkerSandbox.profile, "Scripts and integration checks must test the profile the app uses.")
    }

    @Test func argumentsUseCanonicalPathsAndFailClosedWhenMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sandbox-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try Self.interpreter(in: root)
        let arguments = try #require(WorkerSandbox.arguments(resources: root, modelRoot: nil, python: python))
        let canonical = try #require(WorkerSandbox.canonicalPath(root))
        #expect(canonical.hasPrefix("/private/"), "Seatbelt needs the real path, not Foundation's /var alias.")
        #expect(arguments.contains("RESOURCES=\(canonical)") && arguments.contains("MODEL_ROOT=\(canonical)"))
        #expect(arguments.contains("PYTHON=\(canonical)/bin/python3") && arguments.contains("PYTHON_HOME=\(canonical)"))
        #expect(arguments.last == python.path)
        #expect(WorkerSandbox.arguments(resources: root.appendingPathComponent("missing"), modelRoot: nil,
                                        python: python) == nil)
        #expect(WorkerSandbox.arguments(resources: root, modelRoot: nil, python: URL(fileURLWithPath: "/bin/cat")) == nil,
                "An interpreter directly below / would make the whole disk readable.")
    }

    /// Runs the real profile with a copy of `/bin/cat` standing in for the interpreter.
    @Test func profileAllowsOnlyTheRuntimeAndDeniesWritesProcessesAndOtherFiles() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sandbox-run-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let runtime = base.appendingPathComponent("Runtime"), outside = base.appendingPathComponent("Outside")
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: runtime.appendingPathComponent("allowed.txt"))
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let cat = try Self.interpreter(in: runtime)
        func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            let sandbox = try #require(WorkerSandbox.arguments(resources: runtime, modelRoot: nil, python: cat))
            process.arguments = Array(sandbox.dropLast()) + [executable.path] + arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, text)
        }
        let allowed = try run(cat, [runtime.appendingPathComponent("allowed.txt").path])
        #expect(allowed == (0, "runtime"))
        let secret = try run(cat, [outside.appendingPathComponent("secret.txt").path])
        #expect(secret.0 != 0 && !secret.1.contains("private"), "Files outside the runtime and model stay unreadable.")
        let other = try run(URL(fileURLWithPath: "/bin/echo"), ["escaped"])
        #expect(other.0 != 0 && !other.1.contains("escaped"), "Only the interpreter may be executed.")
    }
}

/// Holds the accepted hash in memory; tests never touch the user's real preferences.
final class MemoryModelTermsStore: ModelTermsAcceptanceStoring {
    var acceptedTermsSHA256: String?
}

extension ModelTermsAcceptance {
    /// Tests of unrelated behaviour read with accepted terms; the gate has its own suite.
    static func acceptedForTesting() -> ModelTermsAcceptance {
        let terms = ModelTermsAcceptance(document: "Synthetic model terms", store: MemoryModelTermsStore())
        terms.setAccepted(true)
        return terms
    }
}

/// Open RAIL-M §4(a)/§5: reading aloud with Supertonic 3 needs an explicit, local
/// acceptance of exactly the terms bundled with this build.
@Suite("Supertonic model terms acceptance", .serialized)
@MainActor
struct ModelTermsAcceptanceTests {
    @Test func acceptanceStoresOnlyTheHashOfTheBundledTermsLocally() throws {
        let suite = "com.christopherbobel.OpenScreenReader.model-terms-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let terms = ModelTermsAcceptance(document: "Terms v1", store: UserDefaultsModelTermsStore(defaults: defaults))
        #expect(terms.state == .notAccepted)
        #expect(!terms.isAccepted)
        #expect(terms.setAccepted(true) == .accepted)
        let hash = SHA256Digest.hex(of: Data("Terms v1".utf8))
        #expect(defaults.string(forKey: "supertonicTermsAccepted.v1") == hash)
        #expect(UserDefaultsModelTermsStore.preferenceKey == "supertonicTermsAccepted.v1")
        #expect(defaults.persistentDomain(forName: suite)?.keys.sorted() == ["supertonicTermsAccepted.v1"], "Nothing else is stored.")
        #expect(ModelTermsAcceptance(document: "Terms v1", store: UserDefaultsModelTermsStore(defaults: defaults)).isAccepted,
                "Acceptance survives a relaunch.")
        #expect(terms.setAccepted(false) == .notAccepted)
        #expect(defaults.object(forKey: "supertonicTermsAccepted.v1") == nil, "Unchecking withdraws the acceptance.")
    }

    @Test func changedOrMissingTermsAreNeverAccepted() {
        let store = MemoryModelTermsStore()
        ModelTermsAcceptance(document: "Terms v1", store: store).setAccepted(true)
        let changed = ModelTermsAcceptance(document: "Terms v2", store: store)
        #expect(changed.state == .changed)
        #expect(!changed.isAccepted)
        let missing = ModelTermsAcceptance(document: nil, store: store)
        #expect(missing.state == .unavailable)
        #expect(missing.setAccepted(true) == .unavailable)
        #expect(store.acceptedTermsSHA256 == SHA256Digest.hex(of: Data("Terms v1".utf8)), "Missing terms cannot be accepted.")
        let empty = MemoryModelTermsStore()
        #expect(ModelTermsAcceptance(document: nil, store: empty).setAccepted(true) == .unavailable)
        #expect(empty.acceptedTermsSHA256 == nil)
    }

    @Test func bundledTermsAndLicenseAreWhatTheHashCovers() throws {
        let document = try #require(ModelTerms.document(in: .main))
        let terms = ModelTermsAcceptance(bundle: .main, store: MemoryModelTermsStore())
        #expect(terms.documentSHA256 == SHA256Digest.hex(of: Data(document.utf8)))
        #expect(terms.state == .notAccepted)
    }

    @Test(arguments: [false, true])
    func readingWithoutAcceptanceCapturesNothingAndOpensTheTerms(fromMenu: Bool) async throws {
        let suite = "com.christopherbobel.OpenScreenReader.model-terms-gate.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let selection = RegionSelectionControllerFake(), capture = CaptureFake(), ocr = OCRFake(), speech = SpeechFake()
        let escape = EscapeFake()
        let terms = ModelTermsAcceptance(document: "Terms v1", store: MemoryModelTermsStore())
        let model = AppModel(modelTerms: terms, shortcutStore: MemoryShortcutStore(),
                             hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, captureService: capture, escapeMonitor: escape,
                             ocrService: ocr, speechService: speech, preferences: preferences)
        defer { model.closeSetup() }
        #expect(model.errorHelp == .acceptModelTerms)
        // Setup is a real, focused window; record what the gate published rather than
        // relying on nothing else touching it before the expectations run.
        var statuses: [AppStatus] = [], messages: [String] = []
        let watchers = [model.$status.sink { statuses.append($0) },
                        model.$errorMessage.sink { if let message = $0 { messages.append(message) } }]
        defer { watchers.forEach { $0.cancel() } }
        if fromMenu { model.enqueueReadRequest() } else { model.enqueuePrimaryShortcut() }
        await model.waitForInteractionToSettle()
        #expect(selection.startCount == 0)
        #expect(capture.calls == 0 && ocr.calls == 0)
        #expect(speech.receivedText == nil)
        #expect(!escape.isActive)
        #expect(!model.isReadingActive)
        #expect(await model.pipelineCoordinator.snapshot().activeContext == nil)
        #expect(Array(statuses.prefix(2)) == [.ready, .error])
        #expect(Array(messages.prefix(1)) == [String(localized: "Saywing reads aloud only after you accept the Supertonic 3 model terms. Nothing was captured.")])
        #expect(model.isSetupOpen)
        #expect(model.setupStep == .readingModel)
        #expect(!preferences.bool(forKey: "setupDismissed.v1"))
        model.setModelTermsAccepted(true)
        #expect(model.status == .ready)
        #expect(model.errorMessage == nil)
        model.enqueueReadRequest()
        await model.waitForInteractionToSettle()
        #expect(selection.startCount == 1)
        model.enqueueStopRequest()
        await model.waitForInteractionToSettle()
    }

    @Test func termsMissingFromTheBuildSayReadingIsUnavailable() async throws {
        let suite = "com.christopherbobel.OpenScreenReader.model-terms-missing.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: ModelTermsAcceptance(document: nil, store: MemoryModelTermsStore()),
                             shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, preferences: preferences)
        defer { model.closeSetup() }
        #expect(model.modelTermsState == .unavailable)
        model.setModelTermsAccepted(true)
        #expect(model.modelTermsState == .unavailable)
        model.enqueueReadRequest()
        await model.waitForInteractionToSettle()
        #expect(selection.startCount == 0)
        #expect(model.status == .error)
        #expect(model.errorMessage?.contains("missing") == true)
    }

    @Test func acceptedTermsReadAsBefore() async {
        let selection = RegionSelectionControllerFake(), ocr = OCRFake(), speech = SpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
                             hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, captureService: CaptureFake(), escapeMonitor: EscapeFake(),
                             ocrService: ocr, speechService: speech)
        await model.handleReadRequest()
        selection.complete(ScreenRegionSelection(displayID: 1,
            rectInScreenPoints: CGRect(x: 0, y: 0, width: 20, height: 20),
            rectInBackingPixels: CGRect(x: 0, y: 0, width: 20, height: 20), backingScaleFactor: 1))
        await model.waitForInteractionToSettle()
        await model.waitForCaptureToSettle()
        await model.waitForSpeechToSettle()
        #expect(speech.receivedText == "Hello world")
        #expect(model.status == .ready)
        #expect(!model.isSetupOpen)
    }

    @Test func withdrawingAcceptanceStopsTheActiveReading() async {
        let selection = RegionSelectionControllerFake(), speech = SpeechFake()
        let model = AppModel(modelTerms: .acceptedForTesting(), shortcutStore: MemoryShortcutStore(),
                             hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             selectionController: selection, escapeMonitor: EscapeFake(), speechService: speech)
        await model.handleReadRequest()
        #expect(model.status == .selecting)
        model.setModelTermsAccepted(false)
        await model.waitForInteractionToSettle()
        #expect(model.status == .stopped)
        #expect(!model.isReadingActive)
        #expect(speech.stopped)
        #expect(selection.cancelCount > 0)
    }

    @Test func setupCannotLeaveTheReadingVoiceStepWithoutAcceptance() throws {
        let suite = "com.christopherbobel.OpenScreenReader.model-terms-setup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(modelTerms: ModelTermsAcceptance(document: "Terms v1", store: MemoryModelTermsStore()),
                             shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
                             preferences: defaults)
        let granted = PermissionStatus { _ in true }
        let flow = SetupFlowController(model: model, permissions: granted, start: .readingModel)
        #expect(!flow.canContinue)
        flow.advance()
        #expect(flow.step == .readingModel)
        model.setModelTermsAccepted(true)
        #expect(flow.canContinue)
        flow.advance()
        #expect(flow.step == .readingShortcuts)
        flow.stop()
        // A saved checkpoint past the voice step returns to it while the terms are not accepted.
        model.setModelTermsAccepted(false)
        for checkpoint in ["readingShortcuts", "try-reading"] {
            defaults.set(["step": checkpoint, "resume": true], forKey: SetupFlowController.checkpointKey)
            let restored = SetupFlowController(model: model, permissions: granted)
            #expect(restored.step == .readingModel)
            restored.stop()
        }
        let terms = SetupFlowController(model: model, permissions: granted, entry: .modelTerms)
        #expect(terms.step == .readingModel)
        terms.stop()
    }
}

extension DictationIntegrationTests {
    /// Dictation and the meeting transcript do not use Supertonic; the terms never gate them.
    @Test func dictationStartsWithoutModelTermsAcceptance() async throws {
        let (controller, worker, _) = fixture()
        defer { controller.shutdown() }
        let selection = RegionSelectionControllerFake()
        let model = AppModel(modelTerms: ModelTermsAcceptance(document: "Terms v1", store: MemoryModelTermsStore()),
            shortcutStore: MemoryShortcutStore(), hotkeyManager: HotkeyManagerFake(registrationResult: .registered),
            selectionController: selection, escapeMonitor: EscapeFake(), dictation: controller)
        defer { model.closeSetup() }
        var started = false
        controller.onActivation? { started = true }
        await model.waitForInteractionToSettle()
        #expect(started)
        worker.ready = true
        try controller.begin(target: InsertionTarget(local: controller.scratch))
        #expect(controller.isActive)
        #expect(model.status == .ready)
        #expect(model.errorMessage == nil)
        #expect(!model.isSetupOpen)
        #expect(selection.startCount == 0)
        controller.cancel(restart: false)
    }
}
