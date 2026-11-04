import Foundation

/// Tells voices apart in the others' audio. Used from one serial queue only, so
/// implementations may keep unsynchronised state. Times are seconds of audio fed
/// so far; each call returns only new stretches.
protocol MeetingVoiceDiarizing: AnyObject, Sendable {
  func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan]
  /// Flushes the model's look-ahead at the end of a transcript.
  func finish() throws -> [MeetingVoiceSpan]
}

/// Feeds the "Others" track into a diarizer on its own queue and places its
/// results on the meeting timeline. Audio waits here only briefly: when the
/// diarizer falls behind by more than `backlogLimit`, new audio is dropped rather
/// than piling up in memory, and the voices resume after the gap. The diarizer, and
/// with it the model and everything it holds about the voices, is released as soon
/// as the tracker finishes, is cancelled or fails.
final class MeetingVoiceTracker: @unchecked Sendable {
  private let onVoices: @Sendable ([MeetingVoiceSpan]) -> Void
  private let onFailure: @Sendable (String) -> Void
  private let queue = DispatchQueue(label: "Saywing.meeting.voices", qos: .utility)
  private let backlogLimit: TimeInterval
  private let lock = NSLock()
  private var active = true
  private var backlog: TimeInterval = 0
  // Queue-only state.
  private var diarizer: (any MeetingVoiceDiarizing)?
  private var fed: TimeInterval = 0
  /// (diarizer time, meeting time) where the two clocks were last aligned.
  private var anchors: [(fed: TimeInterval, time: TimeInterval)] = []

  init(
    diarizer: any MeetingVoiceDiarizing, backlogLimit: TimeInterval = 5,
    onVoices: @escaping @Sendable ([MeetingVoiceSpan]) -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) {
    self.diarizer = diarizer
    self.backlogLimit = backlogLimit
    self.onVoices = onVoices
    self.onFailure = onFailure
  }

  /// A chunk of the others' audio, already placed on the meeting timeline. Called
  /// from the audio thread.
  func append(_ chunk: MeetingAudioChunk, at time: TimeInterval) {
    guard !chunk.samples.isEmpty, chunk.sampleRate > 0 else { return }
    let duration = Double(chunk.samples.count) / chunk.sampleRate
    let accepted = lock.withLock {
      guard active, backlog + duration <= backlogLimit else { return false }
      backlog += duration
      return true
    }
    guard accepted else { return }
    queue.async { [self] in
      defer { lock.withLock { backlog -= duration } }
      guard lock.withLock({ active }), let diarizer else { return }
      // A jump on the meeting timeline (a device change, dropped audio) starts a
      // new alignment; small jitter does not.
      let expected = anchors.last.map { $0.time + (fed - $0.fed) }
      if expected.map({ abs($0 - time) > 0.05 }) ?? true { anchors.append((fed, time)) }
      do {
        let spans = try diarizer.append(chunk.samples, sampleRate: chunk.sampleRate)
        fed += duration
        deliver(spans)
      } catch {
        fail(error)
      }
    }
  }

  /// Waits for queued audio, flushes the diarizer and delivers the last voices.
  /// Blocks the caller; run it off the main thread.
  func finish() {
    queue.sync {
      defer { diarizer = nil }
      guard lock.withLock({ active }), let diarizer else { return }
      do {
        deliver(try diarizer.finish())
      } catch {
        fail(error)
      }
      lock.withLock { active = false }
    }
  }

  /// Drops everything queued; nothing is delivered afterwards.
  func cancel() {
    lock.withLock { active = false }
    queue.async { [self] in diarizer = nil }
  }

  /// For tests: waits until queued audio has been processed.
  func drain() { queue.sync {} }

  private func deliver(_ spans: [MeetingVoiceSpan]) {
    let placed = spans.compactMap { span -> MeetingVoiceSpan? in
      // The anchor of the start places the whole stretch: one crossing a gap
      // only reaches into time where nothing was heard.
      guard let anchor = anchors.last(where: { $0.fed <= span.start }) ?? anchors.first else { return nil }
      let offset = anchor.time - anchor.fed
      return MeetingVoiceSpan(voice: span.voice, start: span.start + offset, end: span.end + offset)
    }
    if !placed.isEmpty, lock.withLock({ active }) { onVoices(placed) }
  }

  private func fail(_ error: Error) {
    let wasActive = lock.withLock {
      defer { active = false }
      return active
    }
    diarizer = nil
    if wasActive { onFailure(error.localizedDescription) }
  }
}

/// The voice model a build carries, placed by scripts/bundle-diarization-model.py.
/// A build without it simply keeps the others as one speaker.
enum MeetingVoiceModel {
  static func bundled(in resources: URL? = Bundle.main.resourceURL) -> URL? {
    guard let directory = resources?.appendingPathComponent("Diarization", isDirectory: true),
      let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return nil }
    return contents.sorted { $0.path < $1.path }.first {
      $0.pathExtension == "mlmodelc"
        && FileManager.default.fileExists(atPath: $0.appendingPathComponent("weights/weight.bin").path)
    }
  }
}
