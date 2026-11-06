import AppKit
import SwiftUI

/// The meeting transcript window: consent first, then the live conversation,
/// then copy, save or discard. It shares Setup's page layout, Petrol accent and
/// critically damped motion, and the capsules' level bars.
struct MeetingView: View {
  @ObservedObject var controller: MeetingController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      page
        .id(pageID)
        .transition(.opacity)
    }
    .frame(minWidth: 400, minHeight: 420)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(Color("AccentColor"))
    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1), value: pageID)
  }

  @ViewBuilder private var page: some View {
    switch controller.phase {
    case .idle:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .consent:
      MeetingConsentView(controller: controller)
    case let .unavailable(message):
      MeetingUnavailableView(message: message) { controller.discard() }
    case .starting, .live, .stopping, .finished:
      MeetingTranscriptView(controller: controller)
    }
  }

  /// Pages cross-fade; the live and finished states are one page that changes in place.
  private var pageID: String {
    switch controller.phase {
    case .idle: "idle"
    case .consent: "consent"
    case .unavailable: "unavailable"
    case .starting, .live, .stopping, .finished: "transcript"
    }
  }
}

/// The step symbol on a tinted disc, as on Setup's pages.
private struct MeetingHero: View {
  let symbol: String

  var body: some View {
    ZStack {
      Circle().fill(Color("AccentColor").opacity(0.14)).frame(width: 88, height: 88)
      Image(systemName: symbol)
        .font(.system(size: 36, weight: .medium))
        .foregroundStyle(Color("AccentColor"))
    }
    .accessibilityHidden(true)
  }
}

/// A short "done" confirmation that replaces a button's title for a moment.
private struct Confirmable: View {
  let title: LocalizedStringKey
  let confirmation: LocalizedStringKey
  var prominent = false
  let action: () -> Bool
  @State private var confirmed = false
  @State private var reset: Task<Void, Never>?

  var body: some View {
    let button = Button {
      guard action() else { return }
      confirmed = true
      reset?.cancel()
      reset = Task {
        try? await Task.sleep(for: .seconds(1.6))
        if !Task.isCancelled { confirmed = false }
      }
    } label: {
      // Both titles keep their width so the row does not jump.
      ZStack {
        Text(title).opacity(confirmed ? 0 : 1)
        Label(confirmation, systemImage: "checkmark").opacity(confirmed ? 1 : 0)
      }
    }
    .accessibilityLabel(confirmed ? Text(confirmation) : Text(title))
    if prominent { button.buttonStyle(.borderedProminent) } else { button }
  }
}

private struct MeetingConsentView: View {
  @ObservedObject var controller: MeetingController

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 0) {
          MeetingHero(symbol: "person.2.wave.2").padding(.top, 36)
          Text("Transcribe a Meeting")
            .font(.title.weight(.semibold))
            .padding(.top, 18)
            .accessibilityAddTraits(.isHeader)
          Text("Let everyone know before you start. Recording other people usually requires their consent.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360)
            .padding(.top, 8)
          VStack(alignment: .leading, spacing: 10) {
            Label("Me: your microphone.", systemImage: "mic")
            Label("Others: the sound of every other app, such as Zoom, Teams or a browser call.", systemImage: "speaker.wave.2")
            Label("Recognized on this Mac. No audio is saved; the text stays here until you copy, save or discard it.", systemImage: "lock")
          }
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 380, alignment: .leading)
          .padding(.top, 22)
          // The notice for the meeting chat, next to the button that copies it.
          HStack(alignment: .center, spacing: 12) {
            Text(MeetingController.consentNotice)
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Confirmable(title: "Copy for Chat", confirmation: "Copied") {
              controller.copyConsentNotice()
              return true
            }
          }
          .padding(12)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .frame(maxWidth: 400)
          .padding(.top, 18)
          if let notice = controller.notice {
            MeetingNotice(text: notice).frame(maxWidth: 400).padding(.top, 14)
          }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
      }
      HStack(spacing: 10) {
        Button("Cancel") { controller.discard() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Everyone Is Informed – Start") { controller.confirmConsent() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
    }
  }
}

private struct MeetingUnavailableView: View {
  let message: String
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      MeetingHero(symbol: "waveform.slash")
      Text("Meeting transcripts are not available")
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
        .padding(.top, 18)
        .accessibilityAddTraits(.isHeader)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360)
        .padding(.top, 8)
      Spacer(minLength: 24)
      HStack {
        Spacer()
        Button("Close", action: close).keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.vertical, 18)
      .padding(.horizontal, -8)
    }
    .padding(.horizontal, 32)
  }
}

/// Warnings carry their colour on the symbol only; the words keep full contrast.
private struct MeetingNotice: View {
  let text: String

  var body: some View {
    Label {
      Text(text).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
    .font(.callout)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MeetingTranscriptView: View {
  @ObservedObject var controller: MeetingController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Follows new text only while the user is at the bottom; scrolling up to
  /// reread stops it, and "Latest" brings it back.
  @State private var following = true
  /// The voice whose name is being edited, and the name typed so far.
  @State private var renaming: MeetingVoice?
  @State private var newName = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      if controller.microphoneMissing && controller.phase == .live {
        microphoneHint.transition(.opacity)
      }
      if controller.systemAudioMissing && controller.phase == .live {
        systemAudioHint.transition(.opacity)
      }
      Divider()
      transcript
      Divider()
      footer
    }
    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: controller.systemAudioMissing)
    .alert(
      "Name This Voice",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
      presenting: renaming
    ) { voice in
      TextField("Name", text: $newName)
      Button("Rename") { controller.renameVoice(voice.voice, to: newName) }
        .keyboardShortcut(.defaultAction)
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The name is used in every turn of this voice and in the export. It is kept only with this transcript.")
    }
    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: controller.microphoneMissing)
  }

  private var header: some View {
    HStack(spacing: 10) {
      switch controller.phase {
      case .live:
        // Recording is a shape and a word, not colour alone; red is what macOS uses for it.
        Image(systemName: "record.circle").foregroundStyle(.red).accessibilityHidden(true)
        Text("Recording").font(.headline)
        Text(MeetingClock.elapsed(controller.elapsed))
          .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityLabel(Text("Elapsed \(MeetingClock.elapsed(controller.elapsed))"))
      case .starting:
        ProgressView().controlSize(.small)
        Text("Starting…").font(.headline)
      case .stopping:
        ProgressView().controlSize(.small)
        Text("Finishing the last words…").font(.headline)
      default:
        Text("Transcript").font(.headline)
        if controller.elapsed > 0 {
          Text(MeetingClock.elapsed(controller.elapsed))
            .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if controller.phase == .live {
        MeetingLevel(speaker: .me, level: controller.levels[.me] ?? 0)
        MeetingLevel(speaker: .others, level: controller.levels[.others] ?? 0)
      }
    }
    .frame(height: 24)
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var microphoneHint: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      MeetingNotice(text: String(localized: "Nothing is coming from your microphone. Check that it is not muted, that the right input is selected, and that Saywing may use the microphone."))
      Button("Open Settings…") { SaywingPermission.microphone.openSettings() }
    }
    .padding(12)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
  }

  private var systemAudioHint: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      MeetingNotice(text: String(localized: "Nothing is coming from other apps. If the meeting is playing, allow Saywing under Screen & System Audio Recording."))
      Button("Open Settings…") { SaywingPermission.screenRecording.openSettings() }
    }
    .padding(12)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if controller.transcript.isEmpty {
            Text(controller.phase == .finished ? "Nothing was recognized." : "Text appears here as people speak.")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.top, 48)
          }
          ForEach(controller.transcript.entries) { entry in
            MeetingTurn(
              entry: entry, voices: controller.transcript.voices,
              newPersonLabel: controller.transcript.newPersonLabel,
              rename: { voice in
                newName = voice.label
                renaming = voice
              },
              merge: { controller.mergeVoice($0.voice, into: $1.voice) },
              reassign: { controller.reassignTurn(entry, to: $0.voice) },
              reassignToNewPerson: { controller.reassignTurnToNewPerson(entry) })
              .id(entry.id)
              .transition(reduceMotion ? .identity : .opacity)
          }
          Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.transcript.entries.count)
      }
      .modifier(FollowsBottom(following: $following))
      .overlay(alignment: .bottom) {
        if !following, controller.phase == .live || controller.phase == .stopping {
          Button {
            following = true
            proxy.scrollTo("end", anchor: .bottom)
          } label: {
            Label("Latest", systemImage: "arrow.down")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .padding(.bottom, 12)
          .transition(.opacity)
        }
      }
      .onChange(of: controller.transcript) {
        guard following, controller.phase == .live || controller.phase == .stopping else { return }
        proxy.scrollTo("end", anchor: .bottom)
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      // After a recording four buttons share the row, so a note gets its own line.
      if controller.phase == .finished, let note = controller.footerNote {
        Text(note).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 10) {
        switch controller.phase {
        case .starting, .live:
          if let note = controller.footerNote {
            Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(note)
          }
          Spacer()
          // ⌘. is the Mac's stop; Return stays harmless while the window has focus.
          Button("Stop") { controller.stop() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(".", modifiers: .command)
        case .stopping:
          Spacer()
        default:
          // Leaving this transcript on the left, keeping it on the right.
          Button("Discard", role: .destructive) { controller.requestDiscard() }
          Button("New Transcript") { Task { await controller.startNew() } }
          Spacer()
          Confirmable(title: "Copy", confirmation: "Copied") { controller.copy() }
            .disabled(controller.transcript.isEmpty)
          Confirmable(title: "Save…", confirmation: "Saved", prominent: true) { controller.save() }
            .disabled(controller.transcript.isEmpty)
        }
      }
      .frame(minHeight: 32)
    }
    .controlSize(.large)
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }
}

/// Stops following when the user scrolls away from the bottom (macOS 15+; on
/// macOS 14 the transcript is unavailable anyway, so it simply keeps following).
private struct FollowsBottom: ViewModifier {
  @Binding var following: Bool

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
      } action: { _, atBottom in
        following = atBottom
      }
    } else {
      content
    }
  }
}

private struct MeetingTurn: View {
  let entry: MeetingTranscriptEntry
  let voices: [MeetingVoice]
  let newPersonLabel: String
  let rename: (MeetingVoice) -> Void
  let merge: (MeetingVoice, MeetingVoice) -> Void
  /// Moves only this turn, to another voice or to a new person.
  let reassign: (MeetingVoice) -> Void
  let reassignToNewPerson: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if let voice = entry.voice {
          voiceLabel(MeetingVoice(voice: voice, label: entry.label))
        } else {
          // "Me" carries the Petrol accent so your own turns stand out while scanning;
          // the label says it, so colour is never the only cue.
          Text(entry.label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(entry.speaker == .me ? Color("AccentColor") : Color.primary)
        }
        Text(MeetingClock.timestamp(entry.start))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      (Text(entry.text) + Text(entry.text.isEmpty || entry.pending.isEmpty ? "" : " ")
        + Text(entry.pending).foregroundStyle(.secondary))
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  /// One of the others: a coloured mark for scanning, the name or number for
  /// meaning, and a menu to name the voice, join it with another, or give only
  /// this turn to someone else when the diarizer mixed two people up.
  private func voiceLabel(_ voice: MeetingVoice) -> some View {
    Menu {
      let others = voices.filter { $0.voice != voice.voice }
      Button("Rename…") { rename(voice) }
      if !others.isEmpty {
        Menu("Same Person As") {
          ForEach(others) { target in
            Button(target.label) { merge(voice, target) }
          }
        }
      }
      Divider()
      Menu("Different Person") {
        ForEach(others) { target in
          Button(target.label) { reassign(target) }
        }
        if !others.isEmpty { Divider() }
        Button("New Person (\(newPersonLabel))") { reassignToNewPerson() }
      }
    } label: {
      HStack(spacing: 5) {
        Circle()
          .fill(MeetingVoicePalette.color(for: entry.number ?? voice.voice))
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text(voice.label)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.primary)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(String(localized: "Name this voice, join it with another, or give this turn to a different person"))
    .accessibilityLabel(voice.label)
    .accessibilityHint(Text("Name this voice, join it with another, or give this turn to a different person"))
  }
}

/// Distinct, calm system colours for up to six voices, by their number, so a new
/// person never borrows the colour of a voice next to it. They repeat after six,
/// which is fine because the label, not the colour, says who it is.
enum MeetingVoicePalette {
  private static let colors: [Color] = [.blue, .orange, .purple, .pink, .teal, .brown]

  static func color(for number: Int) -> Color { colors[abs(number - 1) % colors.count] }
}

/// Five bars in the capsules' geometry (2.5 pt wide, 3 pt apart) per track, in the
/// Petrol accent, so a silent source shows at a glance.
private struct MeetingLevel: View {
  let speaker: MeetingSpeaker
  let level: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let shape: [Double] = [0.55, 0.85, 1, 0.75, 0.5]

  var body: some View {
    let loudness = min(1, sqrt(max(0, level)) * 3)
    HStack(spacing: 6) {
      Text(speaker.label).font(.caption).foregroundStyle(.secondary)
      HStack(alignment: .center, spacing: 3) {
        ForEach(Self.shape.indices, id: \.self) { index in
          Capsule()
            .fill(Color("AccentColor").opacity(loudness > 0.02 ? 1 : 0.35))
            .frame(width: 2.5, height: 3 + 11 * Self.shape[index] * loudness)
        }
      }
      .frame(height: 14)
      .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 1), value: loudness)
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(speaker.label)
    .accessibilityValue(level > 0.002 ? Text("Sound") : Text("Silent"))
  }
}
