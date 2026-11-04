import AppKit
import Carbon.HIToolbox
import SwiftUI

enum SettingsTab: Hashable { case general, reading, dictation, shortcuts, privacy }

/// Shared by Setup and Settings: a download always starts with explicit consent.
struct DictationModelSelection: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var models: DictationModelStore
    @State private var pendingInstall: DictationModel?
    @State private var showAlternatives: Bool

    init(controller: DictationController) {
        self.controller = controller
        self.models = controller.models
        _showAlternatives = State(initialValue: controller.selectedModel != .standard || controller.pendingInstallModel != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The model turns your speech into text on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            modelRow(.standard)
            DisclosureGroup("Other Models", isExpanded: $showAlternatives) {
                VStack(alignment: .leading, spacing: 14) {
                    modelRow(.qwen)
                    Divider()
                    modelRow(.whisperLargeV3)
                }.padding(.top, 10)
            }.padding(.leading, 24)
            Text(controller.statusText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(String(localized: "Install \(pendingInstall?.displayName ?? "")?"),
            isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } })) {
                Button("Download and Install") {
                    if let pendingInstall { controller.install(pendingInstall) }
                    pendingInstall = nil
                }
                Button("Cancel", role: .cancel) { pendingInstall = nil }
            } message: {
                if let model = pendingInstall {
                    Text("Download \(size(model)) from Hugging Face (\(models.downloadSource(of: model) ?? "")). Every file is checked before use. Recordings and text stay on your Mac.")
                }
            }
    }

    private func size(_ model: DictationModel) -> String {
        models.downloadSize(of: model).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? String(localized: "Size unavailable")
    }

    @ViewBuilder private func modelRow(_ model: DictationModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName).font(.body.weight(.medium))
                    if models.isBundled(model) { Text("Included with Saywing").font(.callout).foregroundStyle(.secondary) }
                    else if models.isInstalled(model) { Text("Installed").font(.callout).foregroundStyle(.secondary) }
                    else if models.canDownload(model) { Text(size(model)).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                if models.isInstalled(model) {
                    if controller.selectedModel == model && controller.pendingInstallModel == nil {
                        Label("Selected", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Use Model") { controller.selectModel(model) }
                            .disabled(!controller.canChangeModel)
                            .accessibilityIdentifier("use-\(model.rawValue)")
                    }
                } else if models.availability[model]?.isInstalling != true && models.canDownload(model) {
                    Button("Download…") { pendingInstall = model }
                        .disabled(!controller.canChangeModel)
                        .accessibilityIdentifier("download-\(model.rawValue)")
                }
            }
            if !models.isSupported(model) {
                Text("This model is not available in this version for your Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !models.isInstalled(model) && !models.canDownload(model) {
                Text("This build is missing model resources. Reinstall Saywing to restore them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DictationInstallStatus(controller: controller, model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.displayName)
    }
}

struct DictationInstallStatus: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var models: DictationModelStore
    let model: DictationModel
    init(controller: DictationController, model: DictationModel) {
        self.controller = controller; self.models = controller.models; self.model = model
    }
    var body: some View {
        switch models.availability[model] {
        case .installing(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading \(model.displayName)…").font(.callout)
                HStack {
                    ProgressView(value: fraction).accessibilityLabel("Download progress")
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.callout)
                    Button("Cancel") { controller.cancelInstall(model) }
                }
            }
        case .verifying:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking model files…").font(.callout)
                Spacer()
                Button("Cancel") { controller.cancelInstall(model) }
            }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .notInstalled where controller.pendingInstallModel == model:
            Text("The download was interrupted. Choose Download to try again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }
}

struct DictationSettingsSection: View {
    @ObservedObject var controller: DictationController
    @State private var vocabularyText: String
    init(controller: DictationController) {
        self.controller = controller
        _vocabularyText = State(initialValue: controller.vocabulary.joined(separator: "\n"))
    }
    var body: some View {
        Form {
            Section("Model") { DictationModelSelection(controller: controller) }
            Section {
                Picker("Language", selection: Binding(get: { controller.language }, set: { controller.setLanguage($0) })) {
                    ForEach(DictationLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("dictationLanguage")
                Toggle("Wait 2 seconds before restoring the clipboard", isOn: Binding(
                    get: { controller.restoresClipboardSlowly }, set: { controller.setRestoresClipboardSlowly($0) }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("dictationSlowPaste")
            } footer: {
                Text("The model loads automatically and stays ready while Saywing is open. Turn on the longer wait if an app pastes your previous clipboard instead of the dictation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $vocabularyText)
                    .font(.body)
                    .frame(minHeight: 66)
                    .accessibilityLabel("Vocabulary")
                    .accessibilityIdentifier("dictationVocabulary")
                    .onChange(of: vocabularyText) { _, text in controller.setVocabulary(text) }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("One name or term per line, up to \(DictationVocabulary.maximumTerms). They help the model spell words it rarely hears. The list stays on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text(controller.activationInstructions).fixedSize(horizontal: false, vertical: true)
                Button("Try Dictation…") { controller.showWindow() }
            }
        }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
    }
}

/// The same native keystroke fields in Setup and Settings; no second set of preferences.
struct ActivationShortcutsView: View {
    @ObservedObject var model: AppModel
    @State private var rejected = false
    @State private var pending: ShortcutConfiguration?
    @State private var pendingDictation = false
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            shortcutRow(title: String(localized: "Read screen region"), configuration: model.shortcutConfiguration,
                        dictation: false, identifier: "shortcutRecorder")
            if let notice = model.shortcutNotice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let dictation = model.dictation {
                shortcutRow(title: String(localized: "Start or finish dictation"), configuration: dictation.shortcutConfiguration,
                            dictation: true, identifier: "dictationShortcutRecorder")
                if let notice = dictation.shortcutNotice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true) }
                Toggle("Also dictate with Fn", isOn: Binding(get: { dictation.fnEnabled }, set: { dictation.setFnEnabled($0) }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("dictationFnEnabled")
                if dictation.fnEnabled {
                    Text("Hold Fn to speak and release to paste. Press Fn twice for hands-free dictation.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Click a shortcut field and press your combination. Escape cancels the change; activation shortcuts are paused while you choose.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rejected {
                Text("Use a letter, digit or Space with ⌘, ⌥ or ⌃. Shift is optional.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("Escape always stops reading or discards dictation.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .disabled(!model.canChangeShortcut)
        .onDisappear { model.setRecordingShortcut(false) }
        .alert("Override app commands?", isPresented: $confirm) {
            Button("Use Shortcut") { if let pending { apply(pending, dictation: pendingDictation) } }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("\(pending?.displayName ?? "") may replace a familiar command in other apps while Saywing is running. Use it anyway?")
        }
    }
    private func shortcutRow(title: String, configuration: ShortcutConfiguration, dictation: Bool, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 10)
            ShortcutRecorder(shortcut: configuration, identifier: identifier,
                onRecordingChange: { recording in rejected = false; model.setRecordingShortcut(recording) },
                onRecord: { value in
                    if value.modifiers == UInt32(cmdKey) { pending = value; pendingDictation = dictation; confirm = true }
                    else { apply(value, dictation: dictation) }
                }, onRejected: { rejected = true })
                .frame(width: 150, height: 24).accessibilityLabel(title)
            Button { apply(dictation ? .dictationDefault : .default, dictation: dictation) } label: {
                Image(systemName: "arrow.counterclockwise")
            }.help("Restore Default").accessibilityLabel(String(localized: "Restore Default") + " · " + title)
                .disabled(configuration == (dictation ? .dictationDefault : .default))
        }
    }
    private func apply(_ value: ShortcutConfiguration, dictation: Bool) {
        if dictation { model.enqueueDictationShortcutChange(value) }
        else { model.enqueueShortcutChange(value) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var permissions = PermissionStatus()
    @State private var pendingShortcut: (shortcut: ShortcutConfiguration, queue: Bool)?
    @State private var confirmCommonShortcut = false
    @State private var rejectedKeystroke = false
    @State private var tab: SettingsTab

    init(model: AppModel, initialTab: SettingsTab = .general) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }
    @AppStorage(InterfaceSoundPlayer.preferenceKey, store: InterfaceSoundPlayer.defaults)
    private var interfaceSoundsEnabled = true
    @AppStorage(InterfaceSoundPlayer.volumeKey, store: InterfaceSoundPlayer.defaults)
    private var interfaceSoundsVolume = InterfaceSoundPlayer.defaultVolume
    @AppStorage(ReadingPanelPlacement.edgeKey, store: InterfaceSoundPlayer.defaults)
    private var readingPanelEdge = ReadingPanelEdge.bottom.rawValue

    /// macOS settings convention: one toolbar tab per activity, grouped forms,
    /// the common choices first and explanations only where they prevent a mistake.
    var body: some View {
        TabView(selection: $tab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            readingTab
                .tabItem { Label("Read Aloud", systemImage: "speaker.wave.2") }.tag(SettingsTab.reading)
            dictationTab
                .tabItem { Label("Dictate", systemImage: "mic") }.tag(SettingsTab.dictation)
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
        }
        .frame(width: 540)
        .accessibilityLabel("Saywing settings")
        .onAppear { takeRequestedTab() }
        .onChange(of: model.requestedSettingsTab) { _, _ in takeRequestedTab() }
        // Validation and notices appear without focus moving to them; say them aloud.
        .onChange(of: rejectedKeystroke) { _, rejected in
            if rejected { AccessibilityNotification.Announcement(String(localized: "Use a letter, digit or Space with ⌘, ⌥ or ⌃. Shift is optional.")).post() }
        }
        .onChange(of: model.shortcutNotice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
        .onChange(of: model.queueShortcutNotice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
        .alert("Override app commands?", isPresented: $confirmCommonShortcut, presenting: pendingShortcut) { pending in
            Button("Use Shortcut") {
                if pending.queue { model.enqueueQueueShortcutChange(pending.shortcut) }
                else { model.enqueueShortcutChange(pending.shortcut) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("\(pending.shortcut.displayName) may replace a familiar command in other apps while Saywing is running. Use it anyway?")
        }
    }

    private func takeRequestedTab() {
        guard let requested = model.requestedSettingsTab else { return }
        tab = requested
        model.requestedSettingsTab = nil
    }

    private var generalTab: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saywing").font(.title2.weight(.semibold))
                        Text("Read aloud and dictate on your Mac.").foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up & Test…") { model.showSetup() }
                }
                .padding(.vertical, 4)
            }
            AppUpdateSettings(updates: model.updates, busy: model.isBusyForUpdates)
            Section {
                Toggle("Interface sounds", isOn: $interfaceSoundsEnabled)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("interfaceSoundsEnabled")
                Slider(value: $interfaceSoundsVolume, in: 0...1) { Text("Volume") }
                    .disabled(!interfaceSoundsEnabled)
                    .accessibilityIdentifier("interfaceSoundsVolume")
            } footer: {
                Text("Short cues when the control opens, when reading is done, when the microphone opens, latches hands-free or closes, and when something needs attention. Never during speech.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var readingTab: some View {
        Form {
            Section {
                Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                    ForEach(SpeechSpeed.presets, id: \.self) { speed in Text(SpeechSpeed.label(speed)).tag(speed) }
                }
                .accessibilityIdentifier("readingSpeed")
                Picker("Control position", selection: $readingPanelEdge) {
                    ForEach(ReadingPanelEdge.allCases, id: \.rawValue) { edge in
                        Text(edge.title).tag(edge.rawValue)
                    }
                }
                .accessibilityIdentifier("readingPanelPosition")
                .onChange(of: readingPanelEdge) { _, value in
                    // Keep the offset from dragging when Settings synchronizes the selected edge.
                    let placement = ReadingPanelPlacement.load(from: InterfaceSoundPlayer.defaults)
                    guard placement.edge.rawValue == value else { return }
                    NotificationCenter.default.post(name: ReadingPanelPlacement.changed, object: InterfaceSoundPlayer.defaults)
                }
                LabeledContent("") {
                    Button("Preview & Move Control") { model.previewReadingPanelPosition() }
                        .disabled(!model.canChangeShortcut)
                        .accessibilityIdentifier("previewReadingPanelPosition")
                }
            } footer: {
                Text("Speed changes immediately, without changing pitch. Drag the control to the left, right or bottom edge; its position is remembered.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Voice") {
                LabeledContent("Model", value: SpeechRuntimeConfiguration(root: LocalSpeechService.developmentRoot).modelName)
                LabeledContent("Voice", value: String(localized: "Machine-generated voice M1"))
                LabeledContent("License", value: "BigScience Open RAIL-M")
                ModelTermsNotice()
                ModelTermsAcceptanceToggle(model: model)
                LabeledContent("Runtime", value: LocalSpeechService.installationSummary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var dictationTab: some View {
        if let dictation = model.dictation {
            DictationSettingsSection(controller: dictation)
        } else {
            Form { Text("Dictation is not available in this build.").foregroundStyle(.secondary) }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyTab: some View {
        Form {
            Section {
                Label("Text recognition, speech and dictation run on this Mac. Nothing is sent to a server.", systemImage: "lock.laptopcomputer")
                Label("Additional dictation models are downloaded from Hugging Face only when you choose to install one.", systemImage: "arrow.down.circle")
                Label("Saywing checks for updates over the internet. This sends no screen content, text or audio, and you can turn it off in General.", systemImage: "arrow.triangle.2.circlepath")
                Label("Screenshots, recognized text and audio are never saved.", systemImage: "externaldrive.badge.xmark")
                Label("Reading never touches the clipboard. Dictation uses it briefly to paste and then restores it.", systemImage: "doc.on.clipboard")
                Label("A meeting transcript starts only after you confirm that everyone is informed. It hears your microphone and other apps, saves no audio and keeps the text in memory until you copy, save or discard it. macOS asks for system audio the first time.", systemImage: "person.2.wave.2")
            }
            .fixedSize(horizontal: false, vertical: true)
            Section("Permissions") {
                ForEach(SaywingPermission.allCases) { PermissionRow(permission: $0, status: permissions) }
                if let errorMessage = model.errorMessage {
                    // Colour on the symbol only; the text keeps full contrast.
                    Label { Text(errorMessage) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutsTab: some View {
        Form {
            Section { ActivationShortcutsView(model: model) }
            Section {
                DisclosureGroup("Advanced") {
                    HStack {
                        Text("Add to queue")
                        Spacer()
                        recorder(for: model.queueShortcutConfiguration, queue: true, identifier: "queueShortcutRecorder",
                                 label: String(localized: "Add to queue"))
                    }
                    Text("Optional. Pressing the reading shortcut again already adds a region.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let notice = model.queueShortcutNotice { Text(notice).font(.callout) }
                    LabeledContent("") {
                        Button("Restore Default") { apply(.queueDefault, queue: true) }
                            .disabled(model.queueShortcutConfiguration == .queueDefault)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!model.canChangeShortcut)
    }

    private func recorder(for shortcut: ShortcutConfiguration, queue: Bool, identifier: String, label: String) -> some View {
        ShortcutRecorder(shortcut: shortcut, identifier: identifier, label: label,
                         onRecordingChange: { recording in
                             if recording { rejectedKeystroke = false }
                             model.setRecordingShortcut(recording)
                         },
                         onRecord: { apply($0, queue: queue) },
                         onRejected: { rejectedKeystroke = true })
            .frame(width: 150, height: 24)
    }

    /// Command alone replaces familiar app commands, so it needs confirmation.
    private func apply(_ shortcut: ShortcutConfiguration, queue: Bool) {
        if shortcut.modifiers == UInt32(cmdKey) {
            pendingShortcut = (shortcut, queue)
            confirmCommonShortcut = true
        } else if queue {
            model.enqueueQueueShortcutChange(shortcut)
        } else {
            model.enqueueShortcutChange(shortcut)
        }
    }

}

struct PlaybackControlsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.isPaused ? String(localized: "Paused") : model.status.title, systemImage: model.isPaused ? "pause.fill" : "waveform")
                    .font(.headline)
                Spacer()
                Button { model.enqueueStopRequest() } label: { Image(systemName: "stop.fill") }
                    .help("Stop everything and clear the queue")
                    .accessibilityLabel("Stop everything")
            }
            HStack(spacing: 12) {
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? String(localized: "Resume") : String(localized: "Pause"), systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }.disabled(!model.canPause)
                    .accessibilityIdentifier("togglePlaybackPause")
                Button { model.enqueueSkipRequest() } label: { Label("Next", systemImage: "forward.end.fill") }
                    .disabled(!model.canSkipText)
            }
            Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                ForEach(SpeechSpeed.presets, id: \.self) { Text(SpeechSpeed.label($0)).tag($0) }
            }
            Divider()
            HStack {
                Text("Up Next · \(model.queuedTextCount)").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.enqueueAddRequest() } label: { Image(systemName: "plus") }
                    .disabled(!model.canAddToQueue).help("Select another screen region")
                    .accessibilityLabel("Add Screen Region to Queue…")
            }
            if model.queueEntries.isEmpty {
                Text("Press \(model.shortcutConfiguration.displayName) again to add a text.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.queueEntries.enumerated()), id: \.element.id) { index, entry in
                    // Each row is one group named by its text, so "Move up" says which text moves.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.preview).lineLimit(2)
                        HStack {
                            Button("Read Now") { model.playQueueEntry(entry.id) }
                            Spacer()
                            Button { model.moveQueueEntry(entry.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).accessibilityLabel("Move up")
                            Button { model.moveQueueEntry(entry.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == model.queuedTextCount - 1).accessibilityLabel("Move down")
                            Button { model.removeQueueEntry(entry.id) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove from queue")
                        }.controlSize(.small)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(entry.preview)
                }
            }
            Text("This session only · nothing is saved").font(.callout).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 340)
        .tint(Color("AccentColor"))
        .accessibilityIdentifier("playbackControls")
    }
}

/// Opened from the question mark of a failed reading: the concrete reason and
/// one next step, anchored to the control that failed.
struct ReadingErrorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Can’t read aloud", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text(model.errorMessage ?? String(localized: "Reading did not work."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                switch model.errorHelp {
                case let .allow(permission):
                    Button("Open Setup…") {
                        model.closeErrorHelp()
                        model.showSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(Text("\(permission.systemName) is not allowed"))
                case .acceptModelTerms:
                    Button("Review Model Terms…") {
                        model.closeErrorHelp()
                        model.showModelTerms()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .shortcut:
                    Button("Shortcut Settings…") {
                        model.closeErrorHelp()
                        model.openSettings(.shortcuts)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .reinstall:
                    // Trying again cannot restore damaged files; the message is the next step.
                    Button("Close") { model.closeErrorHelp() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .retry:
                    Button("Try Again") {
                        model.closeErrorHelp()
                        model.enqueueReadRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
        .tint(Color("AccentColor"))
        .accessibilityIdentifier("readingErrorHelp")
    }
}

/// The Supertonic 3 terms and its unchanged Open RAIL-M license are plain resources of
/// every build (see docs/licenses/SUPERTONIC-MODEL-TERMS.md); release packaging adds the full notice index.
enum ModelTerms {
    /// SHA-256 of LICENSE at Supertone/supertonic-3 revision 3cadd1ee6394adea1bd021217a0e650ede09a323.
    static let pinnedLicenseSHA256 = "0d944a9110fed9a9602d60e0423a272903e7bd21ab060490774efc77c2275e9f"

    static func licenseURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "Supertonic-3-Open-RAIL-M", withExtension: "txt")
    }

    /// The binding terms followed by the complete license, or `nil` if either is missing.
    static func document(in bundle: Bundle) -> String? {
        guard let termsURL = bundle.url(forResource: "SUPERTONIC-MODEL-TERMS", withExtension: "md"),
              let licenseURL = licenseURL(in: bundle),
              let terms = try? String(contentsOf: termsURL, encoding: .utf8),
              let license = try? String(contentsOf: licenseURL, encoding: .utf8) else { return nil }
        return terms + "\n\n" + license
    }
}

/// Opens only locally packaged documents; no runtime request or web fallback.
struct ModelTermsNotice: View {
    @State private var openFailed = false
    @State private var termsDocument: String?
    private var noticeURL: URL? { Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "html") }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Supertonic 3 is subject to the Open RAIL-M model terms and use restrictions.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Model Terms…") { termsDocument = ModelTerms.document(in: .main) }
                    .disabled(ModelTerms.licenseURL(in: .main) == nil)
                    .accessibilityIdentifier("showSupertonicModelTerms")
                Button("Licenses & Model Terms…") {
                    guard let noticeURL else { return }
                    openFailed = !NSWorkspace.shared.open(noticeURL)
                }
                .disabled(noticeURL == nil)
                .accessibilityIdentifier("openModelTerms")
            }
            if openFailed { Text("The license document could not be opened.").font(.callout) }
        }
        .sheet(isPresented: Binding(get: { termsDocument != nil }, set: { if !$0 { termsDocument = nil } })) {
            ModelTermsSheet(text: termsDocument ?? "")
        }
    }
}

/// Shared by Setup and Settings: the explicit acceptance that Open RAIL-M §4(a) and §5
/// require before Supertonic 3 reads aloud. The state is always said in words.
struct ModelTermsAcceptanceToggle: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("I have read and accept the Supertonic 3 model terms.", isOn: Binding(
                get: { model.modelTermsState == .accepted }, set: { model.setModelTermsAccepted($0) }))
                .toggleStyle(.checkbox)
                .disabled(model.modelTermsState == .unavailable)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("acceptSupertonicModelTerms")
            Label { Text(note).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("supertonicModelTermsState")
        }
    }

    private var note: String {
        switch model.modelTermsState {
        case .accepted: String(localized: "Accepted. Reading aloud is available. Uncheck to withdraw your acceptance; reading aloud then stops.")
        case .notAccepted: String(localized: "Reading aloud starts only after you accept the model terms.")
        case .changed: String(localized: "The model terms have changed since you accepted them. Read them and accept them again.")
        case .unavailable: model.modelTermsMessage
        }
    }

    private var symbol: String {
        switch model.modelTermsState {
        case .accepted: "checkmark.seal"
        case .notAccepted, .changed: "info.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

private struct ModelTermsSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supertonic 3 Model Terms").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("The binding terms and the complete, unchanged license text. They apply to the model and its voices, not to the Saywing source code.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .accessibilityIdentifier("supertonicModelTermsText")
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 720, minHeight: 420, idealHeight: 600)
        .tint(Color("AccentColor"))
    }
}
