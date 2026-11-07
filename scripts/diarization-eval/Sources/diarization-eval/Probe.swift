import CoreML
import FluidAudio
import Foundation

// Probe for CoreML's execution path. FluidAudio's LSEENDModel binds every recurrent
// state output (`enc_kv_new`, ...) to the very MLMultiArray it passes as the matching
// input (`enc_kv`, ...), so the model updates its state in place. This probe runs
// the same audio three ways in one process and prints a checksum of the speaker
// probabilities for each:
//
//   fluid    LSEENDModel.predict, state aliased in place (what the app runs);
//   fresh    the same, twice more, with fresh state, to see in-process drift;
//   split    a separate MLModel, no output backings, the returned state fed back
//            as the next input: nothing aliased.
//
//   diarization-eval --model <mlmodelc> --probe <wav> [--chunks N]

/// Inputs from LSEEND's own feature provider, state from a dictionary.
final class SplitStateInput: MLFeatureProvider {
  var values: [String: MLFeatureValue] = [:]
  var featureNames: Set<String> { Set(values.keys) }
  func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
}

let stateNames = ["enc_kv", "enc_scale", "enc_conv_cache", "cnn_window", "dec_kv", "dec_scale"]

func checksum(_ out: [Float]) -> Double {
  out.enumerated().reduce(0) { $0 + Double($1.element) * Double($1.offset + 1) }
}

/// Probabilities after the warm-up frames, frames x speakers, as LSEENDModel returns them.
func probabilities(_ probs: MLMultiArray, warmup: Int, metadata: LSEENDMetadata) -> [Float] {
  let frames = metadata.chunkSize - warmup
  let speakers = metadata.maxSpeakers
  let frameStride = probs.strides[1].intValue
  let speakerStride = probs.strides[2].intValue
  var out = [Float](repeating: 0, count: max(0, frames) * speakers)
  let base = probs.dataPointer.assumingMemoryBound(to: Float.self)
  for f in 0..<max(0, frames) {
    for s in 0..<speakers { out[f * speakers + s] = base[(warmup + f) * frameStride + s * speakerStride] }
  }
  return out
}

func probeFluid(samples: ArraySlice<Float>, model: LSEENDModel, chunks: Int) throws -> (Double, Int) {
  let provider = try LSEENDFeatureProvider(from: model.metadata)
  try provider.enqueueAudio(samples)
  var sum = 0.0, count = 0, high = 0
  while count < chunks, let input = try provider.emitNextChunk() {
    let out = try model.predict(from: input)
    sum += checksum(out)
    high += out.filter { $0 > 0.5 }.count
    count += 1
  }
  return (sum, high)
}

func probeSplit(samples: ArraySlice<Float>, url: URL, metadata: LSEENDMetadata, chunks: Int) throws -> (Double, Int) {
  let configuration = MLModelConfiguration()
  configuration.computeUnits = .cpuOnly
  let model = try MLModel(contentsOf: url, configuration: configuration)
  let provider = try LSEENDFeatureProvider(from: metadata)
  try provider.enqueueAudio(samples)
  let initial = try LSEENDState(from: metadata)
  let split = SplitStateInput()
  split.values = [
    "enc_kv": MLFeatureValue(multiArray: initial.encRetKv), "enc_scale": MLFeatureValue(multiArray: initial.encRetScale),
    "enc_conv_cache": MLFeatureValue(multiArray: initial.encConvCache),
    "cnn_window": MLFeatureValue(multiArray: initial.cnnWindow),
    "dec_kv": MLFeatureValue(multiArray: initial.decRetKv), "dec_scale": MLFeatureValue(multiArray: initial.decRetScale),
  ]
  var sum = 0.0, count = 0, high = 0
  while count < chunks, let input = try provider.emitNextChunk() {
    split.values["features"] = input.featureValue(for: "features")
    split.values["valid_mask"] = input.featureValue(for: "valid_mask")
    let result = try model.prediction(from: split)
    guard let probs = result.featureValue(for: "probs")?.multiArrayValue else { throw MeetingError("no probs") }
    let out = probabilities(probs, warmup: input.warmupFrames, metadata: metadata)
    sum += checksum(out)
    high += out.filter { $0 > 0.5 }.count
    for name in stateNames {
      guard let next = result.featureValue(for: name + "_new") else { throw MeetingError("no \(name)_new") }
      split.values[name] = next
    }
    count += 1
  }
  return (sum, high)
}

func probe(audio path: String, modelURL: URL, chunks: Int) throws {
  let (samples, _) = try load(path)
  let slice = samples[0..<min(samples.count, 8000 * 60)]
  let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
  var line: [String] = []
  for label in ["fluid", "fresh", "fresh"] {
    let (sum, high) = try probeFluid(samples: slice, model: model, chunks: chunks)
    line.append(String(format: "%@ %.6f/%d", label, sum, high))
  }
  let (sum, high) = try probeSplit(samples: slice, url: modelURL, metadata: model.metadata, chunks: chunks)
  line.append(String(format: "split %.6f/%d", sum, high))
  print(line.joined(separator: " "))
}

/// The app's own check (when the adapter carries it): prints the difference and its cost.
func stateCheck(modelURL: URL, seconds audioSeconds: Double) throws {
  let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
  let clock = ContinuousClock()
  var difference: Float = 0
  let took = try clock.measure { difference = try LSEENDStateCheck.difference(model: model, modelURL: modelURL, seconds: audioSeconds) }
  print(String(format: "check difference %.6f seconds %.3f", difference, seconds(took)))
}
