import AVFoundation
import Foundation

// Runs the app's voice adapter (NemotronMeetingDiarizer) over prepared conversations
// and writes what it reported. Scoring happens in score.py against the scenario
// manifest.
//
//   diarization-eval --model <folder> --plan <runs.json> --out <results.jsonl>
//
// <folder> is laid out like the app's Diarization folder, as
// scripts/fetch-diarization-model.py leaves it: the manifest names the preset.
//
// runs.json: [{"run": "dev-001.clean8", "audio": "/path/file.wav", "feedRate": 48000}, ...].
// Audio is fed in 10 ms chunks through `append`, as the voice tracker does.

struct Run: Decodable {
  let run: String
  let audio: String
  /// Rate to feed at; the file is converted to it first when it differs.
  let feedRate: Double?
}

struct Result: Encodable {
  let run: String
  let rate: Double
  let duration: Double
  let loadSeconds: Double
  let feedSeconds: Double
  let realTimeFactor: Double
  let footprintAfterLoadMB: Double
  let peakFootprintMB: Double
  /// [voice, start, end] as the adapter reported them.
  let spans: [[Double]]
  /// Seconds of audio fed when each span arrived, minus the span's end.
  let lags: [Double]
  let failure: String?
}

func footprintMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

func load(_ path: String) throws -> (samples: [Float], rate: Double) {
  let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
    throw MeetingError("no buffer for \(path)")
  }
  try file.read(into: buffer)
  return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
}

/// One offline conversion of the whole file, so the only streaming resampler on the
/// way is the adapter's own.
func converted(_ samples: [Float], from rate: Double, to target: Double) throws -> [Float] {
  guard rate != target else { return samples }
  guard let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
    let destination = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
    let converter = AVAudioConverter(from: source, to: destination),
    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
    let output = AVAudioPCMBuffer(
      pcmFormat: destination, frameCapacity: AVAudioFrameCount(Double(samples.count) * target / rate) + 4096)
  else { throw MeetingError("cannot convert \(rate) to \(target)") }
  converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
  input.frameLength = AVAudioFrameCount(samples.count)
  samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
  final class Fed: @unchecked Sendable { var done = false }
  let fed = Fed()
  var error: NSError?
  converter.convert(to: output, error: &error) { _, status in
    if fed.done {
      status.pointee = .endOfStream
      return nil
    }
    fed.done = true
    status.pointee = .haveData
    return input
  }
  if let error { throw error }
  return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

func seconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

/// Through the app's own lookup and loader, from a resources folder whose Diarization
/// folder is the given one. A stable folder keeps CoreML's compiled cache from piling
/// up. The model is loaded before any audio, so the lag measures the adapter, not
/// the app's preload.
func makeDiarizer(model: URL, resources: URL) async throws -> any MeetingVoiceDiarizing {
  let link = resources.appendingPathComponent("Diarization")
  if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != model.path {
    try? FileManager.default.removeItem(at: resources)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
  }
  return try await MeetingVoiceModel.loadDiarizer(in: resources)
}

func evaluate(_ run: Run, model: URL, resources: URL) async throws -> Result {
  let (original, fileRate) = try load(run.audio)
  let rate = run.feedRate ?? fileRate
  let samples = try converted(original, from: fileRate, to: rate)
  let clock = ContinuousClock()
  let started = clock.now
  let diarizer = try await makeDiarizer(model: model, resources: resources)
  let loadTime = clock.now - started
  let afterLoad = footprintMB()
  var peak = afterLoad
  var spans: [MeetingVoiceSpan] = []
  var lags: [Double] = []
  var failure: String?
  let chunk = Int(rate / 100)
  let feed = clock.measure {
    do {
      var position = 0
      var count = 0
      while position < samples.count {
        let end = min(position + chunk, samples.count)
        let new = try diarizer.append(Array(samples[position..<end]), sampleRate: rate)
        position = end
        let heard = Double(position) / rate
        lags += new.map { heard - $0.end }
        spans += new
        count += 1
        if count % 200 == 0 { peak = max(peak, footprintMB()) }
      }
      let last = try diarizer.finish()
      let heard = Double(samples.count) / rate
      lags += last.map { heard - $0.end }
      spans += last
    } catch {
      failure = "\(error)"
    }
  }
  peak = max(peak, footprintMB())
  let duration = Double(samples.count) / rate
  return Result(
    run: run.run, rate: rate, duration: duration, loadSeconds: seconds(loadTime), feedSeconds: seconds(feed),
    realTimeFactor: seconds(feed) / duration, footprintAfterLoadMB: afterLoad, peakFootprintMB: peak,
    spans: spans.map { [Double($0.voice), $0.start, $0.end] }, lags: lags, failure: failure)
}

var arguments: [String: String] = [:]
var index = 1
while index + 1 < CommandLine.arguments.count {
  arguments[CommandLine.arguments[index]] = CommandLine.arguments[index + 1]
  index += 2
}
guard let modelPath = arguments["--model"], let planPath = arguments["--plan"], let outPath = arguments["--out"] else {
  FileHandle.standardError.write(Data("usage: diarization-eval --model <folder> --plan <runs.json> --out <results.jsonl>\n".utf8))
  exit(2)
}
let model = URL(fileURLWithPath: modelPath)
let resources = URL(fileURLWithPath: outPath).deletingLastPathComponent().appendingPathComponent("model-resources")
let runs = try JSONDecoder().decode([Run].self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
try Data().write(to: URL(fileURLWithPath: outPath))
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
for (number, run) in runs.enumerated() {
  let result = try await evaluate(run, model: model, resources: resources)
  try out.write(contentsOf: encoder.encode(result) + Data("\n".utf8))
  print(String(format: "[%d/%d] %@ rtf %.4f spans %d%@", number + 1, runs.count, run.run, result.realTimeFactor,
               result.spans.count, result.failure.map { " FAILED \($0)" } ?? ""))
}
try out.close()
