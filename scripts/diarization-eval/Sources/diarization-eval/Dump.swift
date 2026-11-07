import FluidAudio
import Foundation

/// For exploring post-processing offline: the model's raw per-frame speaker
/// probabilities, fed exactly as the adapter feeds them (its own resampler, 10 ms
/// chunks), with how much audio had been heard when each batch of frames arrived.
/// Writes <dir>/<run>.f32 (frames x speakers) and <dir>/<run>.json.
struct ProbabilityDump: Encodable {
  let run: String
  let speakers: Int
  let frameSeconds: Double
  let duration: Double
  /// [frames so far, seconds heard] after every update that brought frames.
  let arrivals: [[Double]]
}

func dumpProbabilities(_ run: Run, model: LSEENDModel, into folder: URL) throws {
  let (original, fileRate) = try load(run.audio)
  let rate = run.feedRate ?? fileRate
  let samples = try converted(original, from: fileRate, to: rate)
  let metadata = model.metadata
  let diarizer = try LSEENDDiarizer(
    model: model, timelineConfig: DiarizerTimelineConfig(maxStoredFrames: 0, storeSegments: false))
  var audio = try MeetingVoiceAudio(modelRate: Double(metadata.sampleRate))
  var probabilities: [Float] = []
  var arrivals: [[Double]] = []
  var heard = 0
  let speakers = metadata.maxSpeakers
  func record(_ update: DiarizerTimelineUpdate?) {
    guard let update, !update.chunkResult.finalizedPredictions.isEmpty else { return }
    probabilities += update.chunkResult.finalizedPredictions
    arrivals.append([Double(probabilities.count / speakers), Double(heard) / Double(metadata.sampleRate)])
  }
  let chunk = Int(rate / 100)
  var position = 0
  while position < samples.count {
    let end = min(position + chunk, samples.count)
    let modelSamples = try audio.modelSamples(Array(samples[position..<end]), sampleRate: rate)
    heard += modelSamples.count
    position = end
    record(try diarizer.process(samples: modelSamples, sourceSampleRate: nil))
  }
  record(try diarizer.finalizeSession())
  let data = probabilities.withUnsafeBufferPointer { Data(buffer: $0) }
  try data.write(to: folder.appendingPathComponent("\(run.run).f32"))
  let info = ProbabilityDump(
    run: run.run, speakers: speakers, frameSeconds: Double(metadata.frameDurationSeconds),
    duration: Double(heard) / Double(metadata.sampleRate), arrivals: arrivals)
  try JSONEncoder().encode(info).write(to: folder.appendingPathComponent("\(run.run).json"))
}
