import CoreML
import FluidAudio
import Foundation

/// Diagnosis: checksums of the mel features and of the model output for the first
/// chunks, to see which stage differs between processes.
func diagnose(audio path: String, model: LSEENDModel) throws {
  let (samples, _) = try load(path)
  let provider = try LSEENDFeatureProvider(from: model.metadata)
  try provider.enqueueAudio(samples[0..<80_000])
  var melSum = 0.0, outSum = 0.0
  var count = 0
  while let input = try provider.emitNextChunk(), count < 200 {
    let mel = input.melFeatures
    for i in 0..<mel.count { melSum += Double(truncating: mel[i]) * Double(i % 7 + 1) }
    let out = try model.predict(from: input)
    outSum += out.enumerated().reduce(0) { $0 + Double($1.element) * Double($1.offset + 1) }
    count += 1
  }
  print(String(format: "chunks %d mel %.6f out %.6f", count, melSum, outSum))
}
