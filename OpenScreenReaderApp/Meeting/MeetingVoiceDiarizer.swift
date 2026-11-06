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

/// LS-EEND through FluidAudio, in this process, on the CPU. Loads only the given
/// local model and never calls FluidAudio's download helpers. Everything it holds
/// about the voices lives in memory and ends with this object.
final class LSEENDMeetingDiarizer: MeetingVoiceDiarizing, @unchecked Sendable {
  private let diarizer: LSEENDDiarizer
  private let modelRate: Double
  private var audio: MeetingVoiceAudio
  private var stretches: MeetingVoiceStretches
  private var heardSamples = 0

  /// Seconds a voice still speaking grows before it is reported again.
  private static let openStep: TimeInterval = 1
  /// FluidAudio's documented examples: a blip is no speaker, a breath is no change.
  private static let shortestSpeech: TimeInterval = 0.2
  private static let shortestGap: TimeInterval = 0.5

  init(modelURL: URL) throws {
    // Saywing has no runtime path to these, and this makes every one of them throw.
    ModelHub.offlineMode = true
    // The CPU is FluidAudio's documented fastest choice for this model.
    let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
    guard try LSEENDStateCheck.difference(model: model, modelURL: modelURL) <= LSEENDStateCheck.tolerance else {
      throw MeetingError(String(localized: "The voice model could not be prepared reliably. Free some disk space and start again."))
    }
    let metadata = model.metadata
    let frame = TimeInterval(metadata.frameDurationSeconds)
    // Keeps neither frames nor segments: they would grow with the meeting.
    diarizer = try LSEENDDiarizer(
      model: model,
      timelineConfig: DiarizerTimelineConfig(
        minFramesOn: Int((Self.shortestSpeech / frame).rounded()),
        minFramesOff: Int((Self.shortestGap / frame).rounded()),
        maxStoredFrames: 0, storeSegments: false))
    modelRate = Double(metadata.sampleRate)
    audio = try MeetingVoiceAudio(modelRate: modelRate)
    stretches = MeetingVoiceStretches(frameDuration: frame, openStep: Int((Self.openStep / frame).rounded()))
  }

  func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan] {
    let converted = try audio.modelSamples(samples, sampleRate: sampleRate)
    heardSamples += converted.count
    return spans(from: try diarizer.process(samples: converted, sourceSampleRate: nil), final: false)
  }

  func finish() throws -> [MeetingVoiceSpan] {
    spans(from: try diarizer.finalizeSession(), final: true)
  }

  private func spans(from update: DiarizerTimelineUpdate?, final: Bool) -> [MeetingVoiceSpan] {
    guard let update else { return [] }
    let finalized = update.finalizedSegments.map(Self.segment)
    let tentative = update.tentativeSegments.map(Self.segment)
    return stretches.spans(
      closed: final ? finalized + tentative : finalized, open: final ? [] : tentative,
      heard: Double(heardSamples) / modelRate)
  }

  private static func segment(_ segment: DiarizerSegment) -> MeetingVoiceStretches.Segment {
    MeetingVoiceStretches.Segment(voice: segment.speakerIndex, startFrame: segment.startFrame, endFrame: segment.endFrame)
  }
}

/// FluidAudio binds every recurrent state output of LS-EEND (`enc_kv_new`, ...) to the
/// array it passes as the matching input (`enc_kv`, ...), so CoreML updates the state
/// in place. CoreML's usual CPU path handles that. When it cannot write its cache
/// folder (`~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`: a cache folder
/// the user cannot write, a full disk), CoreML takes another path that does not: its
/// probabilities differ from process to process, and in some processes every voice
/// becomes one. Whatever the cause, this runs two seconds of synthetic voices through
/// FluidAudio's in-place path and through a second copy of the model whose state is
/// returned and fed back, nothing shared; the two agree when the state is safe.
enum LSEENDStateCheck {
  /// With the cache both runs agreed bit for bit for every variant; without it they
  /// differed by 0.16 to 0.46 (2026-11-06, Apple M4, macOS 26 build 25G83).
  static let tolerance: Float = 1e-3
  private static let stateNames = ["enc_kv", "enc_scale", "enc_conv_cache", "cnn_window", "dec_kv", "dec_scale"]

  /// The same for a model loaded here, as the adapter loads it.
  static func difference(modelURL: URL) throws -> Float {
    try difference(model: try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly), modelURL: modelURL)
  }

  /// The largest difference in any speaker probability between the two runs.
  static func difference(model: LSEENDModel, modelURL: URL, seconds: Double = 2) throws -> Float {
    let metadata = model.metadata
    let samples = syntheticVoices(rate: Double(metadata.sampleRate), seconds: seconds)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let separate = try MLModel(contentsOf: modelURL, configuration: configuration)
    let inPlace = try LSEENDFeatureProvider(from: metadata)
    let fedBack = try LSEENDFeatureProvider(from: metadata)
    try inPlace.enqueueAudio(samples)
    try fedBack.enqueueAudio(samples)
    let state = try LSEENDState(from: metadata)
    var values: [String: MLFeatureValue] = [
      "enc_kv": MLFeatureValue(multiArray: state.encRetKv),
      "enc_scale": MLFeatureValue(multiArray: state.encRetScale),
      "enc_conv_cache": MLFeatureValue(multiArray: state.encConvCache),
      "cnn_window": MLFeatureValue(multiArray: state.cnnWindow),
      "dec_kv": MLFeatureValue(multiArray: state.decRetKv),
      "dec_scale": MLFeatureValue(multiArray: state.decRetScale),
    ]
    var largest: Float = 0
    while let shared = try inPlace.emitNextChunk(), let own = try fedBack.emitNextChunk() {
      let expected = try model.predict(from: shared)
      values["features"] = own.featureValue(for: "features")
      values["valid_mask"] = own.featureValue(for: "valid_mask")
      let result = try separate.prediction(from: try MLDictionaryFeatureProvider(dictionary: values))
      guard let probs = result.featureValue(for: "probs")?.multiArrayValue else { throw MeetingError(String(localized: "The voice model could not be prepared reliably. Free some disk space and start again.")) }
      let warmup = own.warmupFrames
      let speakers = metadata.maxSpeakers
      let frames = expected.count / max(speakers, 1)
      for frame in 0..<frames {
        for speaker in 0..<speakers {
          let other = probs[[0, NSNumber(value: warmup + frame), NSNumber(value: speaker)]].floatValue
          largest = max(largest, abs(other - expected[frame * speakers + speaker]))
        }
      }
      for name in stateNames {
        guard let next = result.featureValue(for: name + "_new") else {
          throw MeetingError(String(localized: "The voice model could not be prepared reliably. Free some disk space and start again."))
        }
        values[name] = next
      }
    }
    return largest
  }

  /// Two alternating harmonic voices (110 and 210 Hz, slow vibrato, syllable-rate
  /// envelope) with a little deterministic noise: enough to move the state.
  static func syntheticVoices(rate: Double, seconds: Double) -> [Float] {
    var noise: UInt32 = 0x2545_F491
    return (0..<Int(rate * seconds)).map { index in
      let time = Double(index) / rate
      let base: Double = Int(time) % 2 == 0 ? 110 : 210
      let pitch: Double = base * (1 + 0.03 * sin(2 * Double.pi * 5 * time))
      var tone: Double = 0
      for harmonic in 1...12 {
        let order = Double(harmonic)
        tone += sin(2 * Double.pi * pitch * order * time) / order
      }
      let envelope: Double = 0.5 + 0.5 * sin(2 * Double.pi * 4 * time)
      noise = noise &* 1_664_525 &+ 1_013_904_223
      let hiss: Double = Double(noise) / Double(UInt32.max) - 0.5
      return Float(0.15 * envelope * tone + 0.01 * hiss)
    }
  }
}

/// Stands in for a model that is present but would not load: the transcript goes on
/// and the first audio reports why the others stay one speaker.
private final class UnavailableMeetingVoiceModel: MeetingVoiceDiarizing, @unchecked Sendable {
  private let message: String
  init(_ message: String) { self.message = message }
  func append(_ samples: [Float], sampleRate: Double) throws -> [MeetingVoiceSpan] { throw MeetingError(message) }
  func finish() throws -> [MeetingVoiceSpan] { throw MeetingError(message) }
}

extension MeetingVoiceModel {
  /// The diarizer for a transcript that is starting; nil when this build has no
  /// model. Loads only from the app's own resources.
  static func makeDiarizer(in resources: URL? = Bundle.main.resourceURL) -> (any MeetingVoiceDiarizing)? {
    guard let url = bundled(in: resources) else { return nil }
    do {
      return try LSEENDMeetingDiarizer(modelURL: url)
    } catch {
      return UnavailableMeetingVoiceModel(error.localizedDescription)
    }
  }
}
