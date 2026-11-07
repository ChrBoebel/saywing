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

/// Loads the voice model in the background as soon as a transcript may start, and
/// stands in for it until it is ready, so the transcript never waits for it. Audio
/// that arrives before then waits here, at most `bufferLimit` seconds of it (the
/// oldest goes first; about 5.8 MB at 48 kHz for 30 s), and is fed to the model once
/// it is loaded, so the others' first words get their voices too. Its times stay
/// seconds of all audio given to it. Releasing it cancels a load still running and
/// frees a model that is loaded or arrives late; nothing is kept for later.
final class MeetingVoicePreload: MeetingVoiceDiarizing, @unchecked Sendable {
  private final class Slot: @unchecked Sendable {
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    var result: Swift.Result<any MeetingVoiceDiarizing, any Error>?
  }

  private let slot: Slot
  private let task: Task<Void, Never>
  private let bufferLimit: TimeInterval
  private let finishWait: TimeInterval
  // Used from the tracker's queue only.
  private var model: (any MeetingVoiceDiarizing)?
  private var waiting: [(samples: [Float], rate: Double)] = []
  private var waitingSeconds: TimeInterval = 0
  private var dropped: TimeInterval = 0
  private var replayed: [MeetingVoiceSpan] = []

  init(
    bufferLimit: TimeInterval = 30, finishWait: TimeInterval = 30,
    load: @escaping @Sendable () async throws -> any MeetingVoiceDiarizing
  ) {
    self.bufferLimit = bufferLimit
    self.finishWait = finishWait
    let slot = Slot()
    self.slot = slot
    task = Task.detached(priority: .utility) {
      let result: Swift.Result<any MeetingVoiceDiarizing, any Error>
      do { result = .success(try await load()) } catch { result = .failure(error) }
      // Released meanwhile: a model that arrives now dies here.
      guard !Task.isCancelled else { return }
      slot.lock.withLock { slot.result = result }
      slot.done.signal()
    }
  }

  deinit { task.cancel() }

  /// Whether the load has ended, waiting up to `timeout` seconds. For tests and the end.
  @discardableResult func waitUntilLoaded(timeout: TimeInterval) -> Bool {
    if slot.lock.withLock({ slot.result != nil }) { return true }
    guard slot.done.wait(timeout: .now() + timeout) == .success else { return false }
    slot.done.signal()
    return true
  }

  func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan] {
    guard let model = try ready() else {
      waiting.append((samples, sampleRate))
      waitingSeconds += Double(samples.count) / sampleRate
      while waitingSeconds > bufferLimit, !waiting.isEmpty {
        let oldest = waiting.removeFirst()
        let seconds = Double(oldest.samples.count) / oldest.rate
        waitingSeconds -= seconds
        dropped += seconds
      }
      return []
    }
    return shifted(try model.append(samples, sampleRate: sampleRate))
  }

  /// A transcript that ends while the model still loads waits for it, at most
  /// `finishWait` seconds, so short transcripts get their voices too.
  func finish() throws -> [MeetingVoiceSpan] {
    if model == nil { waitUntilLoaded(timeout: finishWait) }
    guard let model = try ready() else {
      waiting = []
      task.cancel()
      return []
    }
    return shifted(try model.finish())
  }

  /// The model once it is loaded; the audio that waited for it goes in first, and
  /// its voices come out with the next result. Throws the load error.
  private func ready() throws -> (any MeetingVoiceDiarizing)? {
    if let model { return model }
    let result = slot.lock.withLock {
      defer { slot.result = nil }
      return slot.result
    }
    switch result {
    case nil:
      return nil
    case let .failure(error):
      waiting = []
      throw error
    case let .success(loaded):
      model = loaded
      let earlier = waiting
      waiting = []
      waitingSeconds = 0
      for chunk in earlier { replayed += try loaded.append(chunk.samples, sampleRate: chunk.rate) }
      return loaded
    }
  }

  /// Voices of the audio that waited first, all on this object's own clock.
  private func shifted(_ spans: [MeetingVoiceSpan]) -> [MeetingVoiceSpan] {
    let all = replayed + spans
    replayed = []
    guard dropped > 0 else { return all }
    return all.map { MeetingVoiceSpan(voice: $0.voice, start: $0.start + dropped, end: $0.end + dropped) }
  }
}

/// The voice model a build carries, placed by scripts/bundle-diarization-model.py
/// with the manifest it was verified against. A build without it simply keeps the
/// others as one speaker.
enum MeetingVoiceModel {
  static let manifestName = "nemotron-3-manifest.json"

  struct Bundled: Equatable, Sendable {
    /// The app's Diarization folder: the model, its assets and the manifest.
    let directory: URL
    /// The runtime configuration the manifest names, as FluidAudio calls it.
    let preset: String
    /// The compiled model the preset loads.
    let model: String
  }

  private struct Manifest: Decodable {
    struct Preset: Decodable {
      struct File: Decodable { let rfilename: String }
      let subdirectory: String
      let model: String
      let files: [File]
    }
    let bundledPreset: String
    let presets: [String: Preset]
    enum CodingKeys: String, CodingKey {
      case bundledPreset = "bundled_preset"
      case presets
    }
  }

  /// The model the manifest names, if every file it lists is in place.
  static func bundled(in resources: URL? = Bundle.main.resourceURL) -> Bundled? {
    guard let directory = resources?.appendingPathComponent("Diarization", isDirectory: true),
      let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
      let preset = manifest.presets[manifest.bundledPreset], !preset.files.isEmpty
    else { return nil }
    let prefix = preset.subdirectory + "/"
    for file in preset.files {
      let name = file.rfilename.hasPrefix(prefix) ? String(file.rfilename.dropFirst(prefix.count)) : file.rfilename
      guard !name.split(separator: "/").contains(".."),
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
      else { return nil }
    }
    return Bundled(directory: directory, preset: manifest.bundledPreset, model: preset.model)
  }
}
