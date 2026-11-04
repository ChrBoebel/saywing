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
