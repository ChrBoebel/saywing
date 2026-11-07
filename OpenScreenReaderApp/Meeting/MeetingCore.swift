import Foundation

/// Who a line belongs to: the microphone is "Me", every other app's sound is "Others".
enum MeetingSpeaker: String, CaseIterable, Sendable {
  case me, others

  var label: String {
    switch self {
    case .me: String(localized: "Me")
    case .others: String(localized: "Others")
    }
  }
}

/// One recognition result, in seconds since the transcript started.
struct MeetingRecognition: Equatable, Sendable {
  let speaker: MeetingSpeaker
  let start: TimeInterval
  let end: TimeInterval
  let text: String
  let isFinal: Bool
  /// The text in timed pieces (words, as the recogniser splits them), when known.
  var pieces: [MeetingPiece] = []
}

struct MeetingPiece: Equatable, Sendable {
  let text: String
  let start: TimeInterval
  let end: TimeInterval
}

/// A stretch where one voice spoke on the "Others" track, on the meeting timeline.
/// Voice numbers come from the diarizer and mean nothing outside one transcript.
struct MeetingVoiceSpan: Equatable, Sendable {
  let voice: Int
  let start: TimeInterval
  let end: TimeInterval
}

/// A voice heard among the others, as the window offers it for naming and merging.
struct MeetingVoice: Equatable, Identifiable {
  let voice: Int
  let label: String
  var id: Int { voice }
}

/// A turn as shown: consecutive segments of one speaker, final text first and the
/// still-changing tail separately so it can be drawn quieter. `voice` tells the
/// others apart when the diarizer heard them; `label` is what the turn is shown as.
struct MeetingTranscriptEntry: Identifiable, Equatable {
  let speaker: MeetingSpeaker
  var voice: Int? = nil
  /// The voice's number ("Speaker 2"), kept under a name too; it picks the colour.
  var number: Int? = nil
  var label: String
  let start: TimeInterval
  /// Where the turn's last word ends; with `start`, the stretch a correction moves.
  var end: TimeInterval
  let text: String
  let pending: String
  var id: String { "\(speaker.rawValue)-\(voice.map(String.init) ?? "")-\(start)" }
}

/// The live transcript. It lives only in memory; nothing here touches disk.
struct MeetingTranscript: Equatable {
  private(set) var finals: [MeetingRecognition] = []
  private(set) var volatile: [MeetingSpeaker: MeetingRecognition] = [:]
  private(set) var echoSpans: [ClosedRange<TimeInterval>] = []
  /// Sorted by start; none longer than `longestVoiceSpan`, so lookups stay local.
  private(set) var voiceSpans: [MeetingVoiceSpan] = []
  private var names: [Int: String] = [:]
  private var mergedInto: [Int: Int] = [:]
  /// Turns the user gave to another voice. The latest correction of a moment wins,
  /// over earlier ones and over every span the diarizer reports, then or later.
  private var corrections: [Correction] = []
  /// People the user added for a turn, with the number each took. Their voices are
  /// negative, so they never meet a voice of the model.
  private var newPeople: [Int: Int] = [:]
  /// The number of each voice, from the last change.
  private var numbers: [Int: Int] = [:]
  private static let longestVoiceSpan: TimeInterval = 30
  /// Visible turns in time order, derived once per change. SwiftUI reads this on
  /// every render (five times a second while live); the echo filter is quadratic.
  private(set) var entries: [MeetingTranscriptEntry] = []

  private struct Correction: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let voice: Int
  }

  /// One voice's words inside a recognition result. `heard` is what the diarizer
  /// said before any correction, in order; it alone decides the numbers.
  private struct Part {
    let start: TimeInterval
    let end: TimeInterval
    let voice: Int?
    let heard: [Int]
    let text: String
  }

  /// Volatile results replace each other; a final result replaces them all.
  mutating func apply(_ recognition: MeetingRecognition) {
    defer { derive() }
    let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard recognition.isFinal else {
      volatile[recognition.speaker] = text.isEmpty ? nil : recognition
      return
    }
    volatile[recognition.speaker] = nil
    guard !text.isEmpty else { return }
    let cleaned = MeetingRecognition(
      speaker: recognition.speaker, start: recognition.start, end: recognition.end, text: text,
      isFinal: true, pieces: recognition.pieces)
    let index = finals.firstIndex { $0.start > cleaned.start } ?? finals.endIndex
    finals.insert(cleaned, at: index)
  }

  /// Marks a stretch where the microphone only heard the others through the speakers.
  mutating func addEcho(_ span: ClosedRange<TimeInterval>) {
    defer { derive() }
    var merged = span
    var kept: [ClosedRange<TimeInterval>] = []
    for existing in echoSpans {
      if existing.overlaps(merged) {
        merged = min(existing.lowerBound, merged.lowerBound)...max(existing.upperBound, merged.upperBound)
      } else {
        kept.append(existing)
      }
    }
    kept.append(merged)
    echoSpans = kept.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// Adds a stretch of one voice from the diarizer; it may arrive after the text.
  mutating func addVoice(_ span: MeetingVoiceSpan) {
    guard span.end > span.start else { return }
    defer { derive() }
    var start = span.start
    while start < span.end {
      let end = min(span.end, start + Self.longestVoiceSpan)
      let piece = MeetingVoiceSpan(voice: span.voice, start: start, end: end)
      let index = voiceSpans.firstIndex { $0.start > piece.start } ?? voiceSpans.endIndex
      voiceSpans.insert(piece, at: index)
      start = end
    }
  }

  /// Names a voice in every turn and the export; an empty name brings the number back.
  mutating func rename(voice: Int, to name: String) {
    defer { derive() }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    names[resolved(voice)] = name.isEmpty ? nil : name
  }

  /// One person the diarizer heard as two voices: `voice` becomes `target`, with
  /// the target's name and number.
  mutating func merge(voice: Int, into target: Int) {
    let (from, to) = (resolved(voice), resolved(target))
    guard from != to else { return }
    defer { derive() }
    mergedInto[from] = to
    names[from] = nil
  }

  /// One turn of the others that the diarizer gave the wrong voice: its words, and
  /// any the recogniser places there later, belong to `voice` from now on. The
  /// rest of the old voice stays where it is. Only the others' voiced turns move.
  mutating func reassign(_ turn: MeetingTranscriptEntry, to voice: Int) {
    guard turn.speaker == .others, turn.voice != nil, turn.end >= turn.start else { return }
    defer { derive() }
    corrections.append(Correction(start: turn.start, end: turn.end, voice: voice))
  }

  /// Gives a turn to someone the diarizer did not hear as a voice of their own. The
  /// new person takes the next free number and keeps it.
  mutating func reassignToNewPerson(_ turn: MeetingTranscriptEntry) {
    guard turn.speaker == .others, turn.voice != nil, turn.end >= turn.start else { return }
    let voice = -(newPeople.count + 1)
    newPeople[voice] = nextNumber
    reassign(turn, to: voice)
  }

  /// What a new person would be called: "Speaker 3" next to two voices.
  var newPersonLabel: String { String(localized: "Speaker \(nextNumber)") }

  private var nextNumber: Int {
    let used = Set(numbers.values)
    return (1...).first { !used.contains($0) } ?? 1
  }

  var isEmpty: Bool { entries.isEmpty }

  /// The voices that have text, in the order they first spoke.
  var voices: [MeetingVoice] {
    var seen = Set<Int>()
    return entries.compactMap { entry in
      guard let voice = entry.voice, seen.insert(voice).inserted else { return nil }
      return MeetingVoice(voice: voice, label: entry.label)
    }
  }

  /// Visible turns in time order. "Me" loses what was only the others through the
  /// speakers: whole segments inside an echo, words timed inside one, and runs of
  /// three or more words the others said at the same moment. The others split by
  /// voice where the diarizer heard one, and where the user corrected it.
  private mutating func derive() {
    let items = (finals + volatile.values.sorted { $0.speaker.rawValue < $1.speaker.rawValue })
      .compactMap { item in visibleText(of: item).map { (item: item, text: $0) } }
      .flatMap { item, text in
        voiced(item, text).map { (speaker: item.speaker, isFinal: item.isFinal, part: $0) }
      }
      .sorted { $0.part.start < $1.part.start }
    // Numbers follow the order in which the diarizer first heard words of a voice,
    // before any merge or correction, so neither a merge, a moved turn nor a late
    // voice renumbers the others. A new person keeps the number it was given.
    var numbers = newPeople
    func number(_ voice: Int) {
      guard numbers[voice] == nil else { return }
      let used = Set(numbers.values)
      numbers[voice] = (1...).first { !used.contains($0) }
    }
    items.forEach { $0.part.heard.forEach(number) }
    var turns: [(speaker: MeetingSpeaker, voice: Int?, start: TimeInterval, end: TimeInterval, text: [String], pending: [String])] = []
    for item in items {
      let voice = item.part.voice.map(resolved)
      if let voice { number(voice) }
      if turns.last?.speaker != item.speaker || turns.last?.voice != voice {
        turns.append((item.speaker, voice, item.part.start, item.part.end, [], []))
      }
      turns[turns.count - 1].end = max(turns[turns.count - 1].end, item.part.end)
      if item.isFinal {
        turns[turns.count - 1].text.append(item.part.text)
      } else {
        turns[turns.count - 1].pending.append(item.part.text)
      }
    }
    self.numbers = numbers
    entries = turns.map { turn in
      let number = turn.voice.flatMap { numbers[$0] }
      let label: String
      if let voice = turn.voice {
        label = names[voice] ?? String(localized: "Speaker \(number ?? numbers.count + 1)")
      } else {
        label = turn.speaker.label
      }
      return MeetingTranscriptEntry(
        speaker: turn.speaker, voice: turn.voice, number: number, label: label, start: turn.start, end: turn.end,
        text: turn.text.joined(separator: " "), pending: turn.pending.joined(separator: " "))
    }
  }

  /// Markdown for an explicit Copy: speaker, time since start, text.
  func exportText(title: String) -> String {
    MeetingExport(transcript: self, title: title, duration: 0).markdown
  }

  /// The voice a merged voice now belongs to.
  private func resolved(_ voice: Int) -> Int {
    var current = voice
    var visited: Set<Int> = [current]
    while let next = mergedInto[current], visited.insert(next).inserted { current = next }
    return current
  }

  /// The others' text in parts of one voice each. With word timings a segment
  /// splits where the voice changes; words the diarizer missed stay with the
  /// words around them, and a correction overrides the diarizer for its words.
  /// Raw voice numbers; merges apply later.
  private func voiced(_ item: MeetingRecognition, _ text: String) -> [Part] {
    guard item.speaker == .others, !voiceSpans.isEmpty else {
      return [Part(start: item.start, end: item.end, voice: nil, heard: [], text: text)]
    }
    let whole = dominantVoice(item.start, item.end)
    guard !item.pieces.isEmpty else {
      let voice = corrected(at: (item.start + item.end) / 2) ?? whole
      return [Part(start: item.start, end: item.end, voice: voice, heard: whole.map { [$0] } ?? [], text: text)]
    }
    var heard = item.pieces.map { dominantVoice($0.start, $0.end) }
    if let first = heard.first(where: { $0 != nil }) {
      var last = first
      for index in heard.indices {
        if let voice = heard[index] { last = voice } else { heard[index] = last }
      }
    } else {
      heard = heard.map { _ in whole }
    }
    let voices = zip(item.pieces, heard).map { piece, voice in corrected(at: (piece.start + piece.end) / 2) ?? voice }
    func inOrder(_ voices: ArraySlice<Int?>) -> [Int] {
      var seen = Set<Int>()
      return voices.compactMap { $0 }.filter { seen.insert($0).inserted }
    }
    if voices.allSatisfy({ $0 == voices[0] }) {
      return [Part(start: item.start, end: item.end, voice: voices[0], heard: inOrder(heard[...]), text: text)]
    }
    var parts: [(start: TimeInterval, end: TimeInterval, voice: Int?, first: Int, words: [String])] = []
    for (index, (piece, voice)) in zip(item.pieces, voices).enumerated() {
      if parts.isEmpty || parts[parts.count - 1].voice != voice { parts.append((piece.start, piece.end, voice, index, [])) }
      parts[parts.count - 1].end = piece.end
      parts[parts.count - 1].words.append(piece.text)
    }
    return parts.map { part in
      let joined = part.words.joined(separator: " ")
        .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
      let heard = inOrder(heard[part.first..<(part.first + part.words.count)])
      return Part(start: part.start, end: part.end, voice: part.voice, heard: heard, text: joined)
    }
  }

  /// The voice the user gave this moment, if they corrected it.
  private func corrected(at time: TimeInterval) -> Int? {
    corrections.last { $0.start <= time && time <= $0.end }?.voice
  }

  /// The voice that spoke most during a stretch, or the nearest one just before or
  /// after it: diarizer and recogniser place word edges a little differently.
  private func dominantVoice(_ start: TimeInterval, _ end: TimeInterval) -> Int? {
    let margin = 0.1, reach = 0.6
    var low = 0, high = voiceSpans.count
    while low < high {
      let middle = (low + high) / 2
      if voiceSpans[middle].start < start - Self.longestVoiceSpan - reach { low = middle + 1 } else { high = middle }
    }
    var overlap: [Int: TimeInterval] = [:]
    var nearest: (voice: Int, distance: TimeInterval)?
    for span in voiceSpans[low...] {
      if span.start > end + reach { break }
      let shared = min(span.end, end + margin) - max(span.start, start - margin)
      if shared > 0 { overlap[span.voice, default: 0] += shared }
      let distance = max(span.start - end, start - span.end, 0)
      if distance <= reach, distance < nearest?.distance ?? .infinity { nearest = (span.voice, distance) }
    }
    return overlap.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? nearest?.voice
  }

  private func visibleText(of item: MeetingRecognition) -> String? {
    guard item.speaker == .me else { return item.text }
    var text = item.text
    if !item.pieces.isEmpty {
      let kept = item.pieces.filter { !inEcho(($0.start + $0.end) / 2) }
      if kept.count < item.pieces.count {
        // Punctuation may come as its own piece; it attaches to the word before.
        text = kept.map(\.text).joined(separator: " ")
          .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
      }
    } else if echoFraction(of: item) >= 0.8 {
      return nil
    }
    let others = othersText(near: item)
    let kept = withoutRepeatedRuns(Self.tokens(text), of: others)
    if Self.soundsLikeAnEcho(kept, of: others) { return nil }
    let result = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return result.contains(where: { $0.isLetter || $0.isNumber }) ? result : nil
  }

  /// The recogniser hears an echo through the room only roughly ("demorfest" for
  /// "Oktoberfest"), so identical runs miss it. A segment of mine is the others'
  /// echo when at least three of its words have three or more letters and 60 % of
  /// those sound like words the others said at the same moment.
  private static func soundsLikeAnEcho(_ mine: [String], of others: [String]) -> Bool {
    let words = mine.map(normalized).filter { $0.count >= 3 }
    let theirs = Set(others.map(normalized).filter { $0.count >= 3 })
    guard words.count >= 3, !theirs.isEmpty else { return false }
    let echoed = words.filter { word in theirs.contains { similar(word, $0) } }.count
    return Double(echoed) >= 0.6 * Double(words.count)
  }

  /// Equal, one a prefix of the other ("gibt", "gibts"), or a few letters apart
  /// in a longer word ("sender", "staender").
  private static func similar(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let shorter = min(a.count, b.count)
    if shorter >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
    guard shorter >= 5 else { return false }
    return editDistance(Array(a), Array(b)) <= max(a.count, b.count) / 3
  }

  private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    var previous = Array(0...b.count)
    for (i, x) in a.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: b.count)
      for (j, y) in b.enumerated() {
        current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
      }
      previous = current
    }
    return previous[b.count]
  }

  private func inEcho(_ time: TimeInterval) -> Bool {
    echoSpans.contains { $0.contains(time) }
  }

  private func echoFraction(of item: MeetingRecognition) -> Double {
    let duration = max(item.end - item.start, 0.1)
    let covered = echoSpans.reduce(0.0) { sum, span in
      sum + max(0, min(span.upperBound, item.end) - max(span.lowerBound, item.start))
    }
    return covered / duration
  }

  private func othersText(near item: MeetingRecognition) -> [String] {
    finals.filter { $0.speaker == .others && $0.start - 1.5 <= item.end && item.start <= $0.end + 1.5 }
      .flatMap { Self.tokens($0.text) }
  }

  /// Drops runs of three or more consecutive words that also appear, in order, in
  /// what the others said at the same moment. Single shared words ("ja", "und")
  /// stay: they are as likely mine.
  private func withoutRepeatedRuns(_ mine: [String], of others: [String]) -> [String] {
    guard mine.count >= 3, others.count >= 3 else { return mine }
    let a = mine.map(Self.normalized)
    let b = others.map(Self.normalized)
    var length = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        length[i][j] = !a[i].isEmpty && a[i] == b[j]
          ? length[i + 1][j + 1] + 1 : max(length[i + 1][j], length[i][j + 1])
      }
    }
    var matched = Array(repeating: false, count: a.count)
    var (i, j) = (0, 0)
    while i < a.count, j < b.count {
      if !a[i].isEmpty, a[i] == b[j] {
        matched[i] = true
        i += 1
        j += 1
      } else if length[i + 1][j] >= length[i][j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    var drop = Array(repeating: false, count: a.count)
    var runStart = 0
    for index in 0...a.count {
      if index < a.count, matched[index] { continue }
      if index - runStart >= 3 { (runStart..<index).forEach { drop[$0] = true } }
      runStart = index + 1
    }
    return mine.enumerated().filter { !drop[$0.offset] }.map(\.element)
  }

  private static func tokens(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  private static func normalized(_ token: String) -> String {
    String(token.lowercased().filter { $0.isLetter || $0.isNumber })
  }
}

enum MeetingClock {
  /// "0:59" or "1:02:05" for the live header.
  static func elapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
  }

  /// "00:01:05" next to each turn in an export.
  static func timestamp(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
  }
}

/// Places audio chunks on one gapless timeline per track. Delivery jitter of a few
/// milliseconds is absorbed; a real gap (a device change, a stall) jumps ahead.
/// Time never runs backwards, so recognition ranges stay comparable across tracks.
struct MeetingTimeline {
  private(set) var next: TimeInterval?
  var tolerance: TimeInterval = 0.05

  mutating func place(at time: TimeInterval, duration: TimeInterval) -> TimeInterval {
    let start: TimeInterval
    if let next {
      start = time > next + tolerance ? time : next
    } else {
      start = max(0, time)
    }
    next = start + duration
    return start
  }
}

/// The same rule in whole samples, for Apple's analyzer: it rejects input whose
/// stamp overlaps or precedes earlier input by even one tick.
struct MeetingFrameTimeline {
  let rate: Double
  private(set) var next: Int64?

  mutating func place(at time: TimeInterval, frames: Int) -> Int64 {
    let wanted = Int64((max(0, time) * rate).rounded())
    let tolerance = Int64(rate * 0.05)
    let start = next.map { wanted > $0 + tolerance ? wanted : $0 } ?? wanted
    next = start + Int64(frames)
    return start
  }
}
