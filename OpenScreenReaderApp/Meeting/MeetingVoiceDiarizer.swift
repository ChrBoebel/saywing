import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Turns the segments the model keeps extending into stretches reported once each.
/// A voice still speaking is reported in steps, so a monologue gets its label while
/// it lasts without adding a span to the transcript ten times a second.
struct MeetingVoiceStretches {
  struct Segment: Equatable {
    let voice: Int
    let startFrame: Int
    let endFrame: Int
  }

  let frameDuration: TimeInterval
  let openStep: Int
  private var reported: [Int: Int] = [:]

  init(frameDuration: TimeInterval, openStep: Int) {
    self.frameDuration = frameDuration
    self.openStep = openStep
  }

  /// `closed` segments report everything new; `open` ones only a full step. No
  /// stretch reaches past `heard`, the seconds of real audio fed so far.
  mutating func spans(closed: [Segment], open: [Segment], heard: TimeInterval) -> [MeetingVoiceSpan] {
    var spans: [MeetingVoiceSpan] = []
    for (segments, step) in [(closed, 1), (open, openStep)] {
      for segment in segments {
        let start = max(segment.startFrame, reported[segment.voice] ?? 0)
        guard segment.endFrame - start >= step else { continue }
        reported[segment.voice] = segment.endFrame
        let end = min(TimeInterval(segment.endFrame) * frameDuration, heard)
        let begin = TimeInterval(start) * frameDuration
        if end > begin { spans.append(MeetingVoiceSpan(voice: segment.voice, start: begin, end: end)) }
      }
    }
    return spans.sorted { $0.start < $1.start }
  }
}

/// Brings the others' audio to the model's rate through one long-lived converter.
/// FluidAudio's `sourceSampleRate:` builds a new converter per call, which loses the
/// filter state at every border of the small chunks a live track delivers.
struct MeetingVoiceAudio {
  private static var conversionFailed: String { String(localized: "This audio format cannot be used to tell voices apart.") }
  private let format: AVAudioFormat
  private var converter: AVAudioConverter?

  init(modelRate: Double) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: modelRate, channels: 1) else {
      throw MeetingError(Self.conversionFailed)
    }
    self.format = format
  }

  mutating func modelSamples(_ samples: [Float], sampleRate: Double) throws -> [Float] {
    if sampleRate == format.sampleRate { return samples }
    if converter?.inputFormat.sampleRate != sampleRate {
      converter = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        .flatMap { AVAudioConverter(from: $0, to: format) }
    }
    guard let converter else { throw MeetingError(Self.conversionFailed) }
    // Nil means the converter is still filling its filter, not a failure.
    guard let output = MeetingResampler.convert(samples, with: converter), let data = output.floatChannelData else {
      return []
    }
    return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
  }
}

/// Turns the model's speaker probabilities into stretches: FluidAudio's timeline with
/// the app's rule (0.2 s of speech before a voice counts, gaps under 0.5 s do not end
/// it) and `MeetingVoiceStretches`. Keeps neither frames nor segments, which would
/// grow with the meeting.
struct MeetingVoiceFrames {
  /// FluidAudio's documented examples: a blip is no speaker, a breath is no change.
  private static let shortestSpeech: TimeInterval = 0.2
  private static let shortestGap: TimeInterval = 0.5
  /// Seconds a voice still speaking grows before it is reported again.
  private static let openStep: TimeInterval = 1

  private let timeline: DiarizerTimeline
  private var stretches: MeetingVoiceStretches

  init(voices: Int, frameDuration: TimeInterval) {
    timeline = DiarizerTimeline(
      config: DiarizerTimelineConfig(
        numSpeakers: voices, frameDurationSeconds: Float(frameDuration),
        minFramesOn: Int((Self.shortestSpeech / frameDuration).rounded()),
        minFramesOff: Int((Self.shortestGap / frameDuration).rounded()),
        maxStoredFrames: 0, storeSegments: false))
    stretches = MeetingVoiceStretches(frameDuration: frameDuration, openStep: Int((Self.openStep / frameDuration).rounded()))
  }

  /// New frames, voices x frames flattened frame by frame, all final; `heard` is the
  /// seconds of real audio fed so far. `final` closes every voice still speaking.
  mutating func spans(_ probabilities: [Float], heard: TimeInterval, final: Bool) throws -> [MeetingVoiceSpan] {
    let update = try timeline.addPredictions(finalizedPredictions: probabilities, tentativePredictions: [])
    let closed = update.finalizedSegments.map(Self.segment)
    let open = update.tentativeSegments.map(Self.segment)
    return stretches.spans(closed: final ? closed + open : closed, open: final ? [] : open, heard: heard)
  }

  /// Frames the timeline still holds; stays zero.
  var retainedFrames: Int { timeline.finalizedPredictions.count / max(timeline.speakerCapacity, 1) + timeline.numTentativeFrames }

  private static func segment(_ segment: DiarizerSegment) -> MeetingVoiceStretches.Segment {
    MeetingVoiceStretches.Segment(voice: segment.speakerIndex, startFrame: segment.startFrame, endFrame: segment.endFrame)
  }
}

/// NVIDIA's Nemotron 3 Diarization through FluidAudio, in this process, on the Neural
/// Engine where the Mac has one. Up to eight voices, numbered in the order they first
/// speak, at 10 ms. Loads only the given local model and never calls FluidAudio's
/// download helpers. Everything it holds about the voices (the speaker cache, the
/// recent frames) has a fixed size, lives in memory and ends with this object.
final class NemotronMeetingDiarizer: MeetingVoiceDiarizing, @unchecked Sendable {
  private let diarizer: Nemotron3Diarizer
  private let modelRate: Double
  private var audio: MeetingVoiceAudio
  private var frames: MeetingVoiceFrames
  private var heardSamples = 0

  init(models: Nemotron3Models, config: Nemotron3Config) throws {
    diarizer = Nemotron3Diarizer(config: config, models: models)
    diarizer.reset()
    modelRate = Double(config.sampleRate)
    audio = try MeetingVoiceAudio(modelRate: modelRate)
    // 10 ms, without the Float's rounding error carried into meeting time.
    let frame = (Double(config.outputFrameSeconds) * 1_000).rounded() / 1_000
    frames = MeetingVoiceFrames(voices: config.numSpeakers, frameDuration: frame)
  }

  /// Loads the bundled model. Takes about 6 s the first time CoreML sees it on a
  /// Mac (it compiles it for the Neural Engine and caches that), well under a second
  /// afterwards.
  static func load(_ model: MeetingVoiceModel.Bundled) async throws -> NemotronMeetingDiarizer {
    // Saywing has no runtime path to these, and this makes every one of them throw.
    ModelHub.offlineMode = true
    let failed = MeetingError(
      String(localized: "The model that tells voices apart could not be loaded. Reinstall Saywing to restore it."))
    // A manifest this FluidAudio reads differently is no model rather than a wrong one.
    guard let config = Nemotron3Config.preset(named: model.preset), config.modelFileName == model.model else { throw failed }
    let models: Nemotron3Models
    do {
      models = try await Nemotron3Models.load(config: config, directory: model.directory, computeUnits: .all)
    } catch {
      throw failed
    }
    try Task.checkCancellation()
    return try NemotronMeetingDiarizer(models: models, config: config)
  }

  func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan] {
    let converted = try audio.modelSamples(samples, sampleRate: sampleRate)
    guard !converted.isEmpty else { return [] }
    heardSamples += converted.count
    diarizer.appendAudio(converted)
    let results = try diarizer.processBufferedAudio()
    guard !results.isEmpty else { return [] }
    return try frames.spans(results.flatMap(\.probabilities), heard: heard, final: false)
  }

  func finish() throws -> [MeetingVoiceSpan] {
    try frames.spans(try diarizer.finishStream().flatMap(\.probabilities), heard: heard, final: true)
  }

  private var heard: TimeInterval { Double(heardSamples) / modelRate }
}

extension MeetingVoiceModel {
  /// What a transcript about to start uses for the others' voices: the bundled model,
  /// loading in the background from now on; nil when this build has no model. Loads
  /// only from the app's own resources.
  static func makeDiarizer(in resources: URL? = Bundle.main.resourceURL) -> (any MeetingVoiceDiarizing)? {
    guard let model = bundled(in: resources) else { return nil }
    return MeetingVoicePreload { try await NemotronMeetingDiarizer.load(model) }
  }

  /// The bundled model itself, loaded now. For the preload, tests and the evaluation.
  static func loadDiarizer(in resources: URL? = Bundle.main.resourceURL) async throws -> any MeetingVoiceDiarizing {
    guard let model = bundled(in: resources) else {
      throw MeetingError("No voice model in \(resources?.path ?? "the app")")
    }
    return try await NemotronMeetingDiarizer.load(model)
  }
}
