import AppKit
import Combine
import OpenScreenReaderCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isPaused = false
    struct QueueEntry: Identifiable {
        let id: UUID
        let preview: String
    }
    var queueEntries: [QueueEntry] {
        queuedTexts.map { QueueEntry(id: $0.id, preview: String($0.result.text.prefix(100)).replacingOccurrences(of: "\n", with: " ")) }
    }
    private var controlsPopover: NSPopover?
    private var setupWindow: NSWindow?
    private var setupFlow: SetupFlowController?
    private var setupCloseObserver: NSObjectProtocol?
    private var offeredSetup = false
    private let missingReadingPermission: @MainActor () -> SaywingPermission?
    func offerSetupIfNeeded() {
        guard !offeredSetup else { return }
        offeredSetup = true
        let arguments = ProcessInfo.processInfo.arguments
        // A relaunch requested by setup itself (Screen Recording) continues it.
        let resume = preferences.dictionary(forKey: SetupFlowController.checkpointKey)?["resume"] as? Bool ?? false
        let testing = arguments.contains("--uitesting") || ProcessInfo.processInfo.environment["OSR_SHORTCUT_TEST_SUITE"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !testing || arguments.contains("--test-setup"),
              resume || !preferences.bool(forKey: "setupDismissed.v1") || arguments.contains("--resume-setup") else { return }
        showSetup()
    }
    func finishSetup() {
        preferences.removeObject(forKey: SetupFlowController.checkpointKey)
        preferences.set(true, forKey: "setupDismissed.v1")
        closeSetup()
    }
    /// Closing without Done is "later": setup returns at the next launch.
    func closeSetup() {
        setupWindow?.close()
        tearDownSetup()
    }
    func deferSetup() {
        setupFlow?.persistCheckpoint(resume: false)
        preferences.set(true, forKey: "setupDismissed.v1")
        closeSetup()
    }
    @Published private(set) var setupRestartError: String?
    @Published private(set) var isRestartingSetup = false
    var isSetupOpen: Bool { setupWindow?.isVisible == true }
    private func tearDownSetup() {
        setupFlow?.stop()
        setupFlow = nil
        if let setupCloseObserver { NotificationCenter.default.removeObserver(setupCloseObserver) }
        setupCloseObserver = nil
        setupWindow?.contentViewController = nil
        setupWindow = nil
    }
    func restartSetup(
        launch: () throws -> Process? = { try SetupRelauncher.launchAfterExit() },
        terminate: () -> Void = { NSApp.terminate(nil) }
    ) {
        guard canRestartSetup, !isRestartingSetup else { return }
        setupFlow?.persistCheckpoint()
        setupRestartError = nil
        isRestartingSetup = true
        do {
            let helper = try launch()
            terminate()
            // This app has no deferred termination. If terminate returns, quit
            // was cancelled: cancel the helper so a later quit cannot relaunch.
            if let helper, helper.isRunning { helper.terminate() }
            isRestartingSetup = false
        } catch {
            isRestartingSetup = false
            setupRestartError = String(localized: "Saywing could not restart. Quit and reopen it to continue here.")
        }
    }
    var canRestartSetup: Bool {
        canChangeShortcut && !isRecordingShortcut && !(dictation?.models.availability.values.contains(where: \.isInstalling) ?? false)
    }
    var canPause: Bool { status == .speaking && activeContext != nil }
    func enqueueStopRequest() {
        dictation?.cancelForReading()
        guard let context = activeContext else { return }
        enqueue { await $0.cancel(context: context) }
    }

    func togglePause() {
        guard canPause, let context = activeContext else { return }
        isPaused.toggle()
        speechService.setPaused(isPaused)
        if isPaused {
            timeoutTask?.cancel()
            speechTimeoutGeneration &+= 1
            readingPanel?.updateLevel(0)
        } else { armSpeechTimeout(.seconds(30), context: context) }
        readingPanel?.updatePaused(isPaused)
    }

    func removeQueueEntry(_ id: UUID) {
        guard let index = queuedTexts.firstIndex(where: { $0.id == id }) else { return }
        queuedTexts.remove(at: index)
        queueWasEdited()
    }

    func moveQueueEntry(_ id: UUID, offset: Int) {
        guard let index = queuedTexts.firstIndex(where: { $0.id == id }),
              queuedTexts.indices.contains(index + offset) else { return }
        queuedTexts.swapAt(index, index + offset)
        queueWasEdited()
    }

    func playQueueEntry(_ id: UUID) {
        enqueue { model in
            guard let index = model.queuedTexts.firstIndex(where: { $0.id == id }),
                  let context = model.activeContext else { return }
            let selected = model.queuedTexts.remove(at: index)
            model.queuedTexts.insert(selected, at: 0)
            model.queueWasEdited()
            await model.finishSpeech(context: context)
        }
    }

    private func queueWasEdited() {
        updateQueuePresentation()
        if status == .speaking { speechService.prepareNext(queuedTexts.first?.result.speechText) }
    }

    /// What the question mark offers after a failure: the reason and a retry in place,
    /// the setup step when a grant is what is missing, or no action when only a
    /// reinstall can help.
    enum ErrorHelp: Equatable { case retry, allow(SaywingPermission), acceptModelTerms, shortcut, reinstall }
    var errorHelp: ErrorHelp {
        if let missing = missingReadingPermission() { return .allow(missing) }
        guard hotkeyRegistration == .registered else { return .shortcut }
        guard modelTermsState == .accepted else { return .acceptModelTerms }
        return lastFailureNeedsReinstall ? .reinstall : .retry
    }
    private var lastFailureNeedsReinstall = false
    /// Settings opens on this tab next time, e.g. Shortcuts from a shortcut conflict.
    @Published var requestedSettingsTab: SettingsTab?
    func openSettings(_ tab: SettingsTab) {
        requestedSettingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    var isShowingErrorHelp: Bool { status == .error && controlsPopover?.isShown == true }
    func closeErrorHelp() {
        controlsPopover?.close()
        controlsPopover = nil
    }

    enum MenuBarIndicator { case idle, reading, attention, recording }
    /// A running meeting transcript wins: it hears other apps, so it must stay visible.
    var menuBarIndicator: MenuBarIndicator {
        meeting?.isRecording == true ? .recording : status == .error ? .attention : isReadingActive ? .reading : .idle
    }
    /// Updates wait for reading, dictation, model installs and meeting transcripts.
    var isBusyForUpdates: Bool {
        !canChangeShortcut || meeting?.isRecording == true
            || dictation?.models.availability.values.contains(where: { $0.isInstalling }) == true
    }

    func showPlaybackControls(from view: NSView) {
        controlsPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = status == .error
            ? NSHostingController(rootView: AnyView(ReadingErrorView(model: self)))
            : NSHostingController(rootView: AnyView(PlaybackControlsView(model: self)))
        controlsPopover = popover
        // Open toward the desktop, including the upright left/right capsule layouts.
        var ancestor: NSView? = view
        while let current = ancestor, !(current is ReadingControlView) { ancestor = current.superview }
        let edge = (ancestor as? ReadingControlView)?.dockEdge.popoverEdge ?? .maxY
        (ancestor as? ReadingControlView)?.holdControls(for: popover)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        // A click on the capsule keeps the user's app in front. Opened from the menu
        // (the keyboard path), the popover takes focus so Tab, Return and Escape work.
        if popoverTakesFocus {
            popoverTakesFocus = false
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private var popoverTakesFocus = false
    func openPlaybackControls() {
        popoverTakesFocus = true
        readingPanel?.openControls()
        // Without a visible control there is nothing to anchor to; do not keep the request.
        popoverTakesFocus = false
    }

    /// Each opening starts from the live grants, so it lands on what is still missing.
    func showSetup(entry: SetupEntry = .automatic) {
        if entry == .modelTerms { setupFlow?.showModelTerms() }
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = String(localized: "Set Up Saywing")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // The reading test reads Saywing's own sample sentence from this window.
            window.identifier = .readableBySaywing
            var initialStep: SetupStep?
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-setup"),
               preferences.dictionary(forKey: SetupFlowController.checkpointKey) == nil {
                initialStep = ProcessInfo.processInfo.environment["OSR_SETUP_INITIAL_STEP"].flatMap(SetupStep.init(checkpoint:))
            }
            #endif
            let flow = SetupFlowController(model: self, entry: entry, start: initialStep)
            flow.onReturn = { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.setupWindow?.makeKeyAndOrderFront(nil)
            }
            window.contentViewController = NSHostingController(rootView: SetupView(model: self, flow: flow))
            window.setContentSize(SetupView.size)
            window.center()
            setupCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.tearDownSetup() } }
            setupFlow = flow
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
    lazy var updates = AppUpdateController(disabled: ProcessInfo.processInfo.arguments.contains("--uitesting")
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["OSR_SHORTCUT_TEST_SUITE"] != nil) { [weak self] in
            guard let self else { return true }
            return self.isReadingActive || self.dictation?.isActive == true || self.isBusyForUpdates
        }

    @Published private(set) var status: AppStatus = .ready
    /// Reading aloud with Supertonic 3 needs this to be `.accepted`; dictation and meetings do not.
    @Published private(set) var modelTermsState: ModelTermsAcceptance.State
    private let modelTerms: ModelTermsAcceptance
    /// The explanation shown when reading was refused for the terms; accepting clears it.
    private var modelTermsError: String?
    @Published private(set) var hotkeyRegistration: HotkeyRegistration = .inactive
    @Published private(set) var lastSelection: ScreenRegionSelection?
    @Published private(set) var lastCaptureSize: CGSize?
    @Published private(set) var lastOCRSummary: OCRSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var shortcutConfiguration: ShortcutConfiguration
    @Published private(set) var shortcutNotice: String?
    @Published private(set) var playbackRate: Double
    @Published private(set) var queueShortcutConfiguration: ShortcutConfiguration
    @Published private(set) var queueShortcutNotice: String?
    @Published private(set) var queueNotice: String?
    @Published private(set) var queuedTextCount = 0
    @Published private(set) var isAddingToQueue = false

    static let queueLimit = 5
    private struct QueuedText {
        let id = UUID()
        let result: OCRResult
        let selection: ScreenRegionSelection
        let size: CGSize
    }
    private var queuedTexts: [QueuedText] = []
    private var queueInputID: UUID?
    private var queueInputTask: Task<Void, Never>?
    private var queueInputTimeout: Task<Void, Never>?
    private var queueOverlayVisible = false
    private var sessionGeneration: UInt64 = 0
    private var dictationObservation: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private let appNotifications: NotificationCenter
    private var meetingObservation: AnyCancellable?
    var activityTitle: String {
        if let dictation, dictation.isActive { return dictation.statusText }
        if meeting?.isRecording == true, activeContext == nil { return String(localized: "Transcribing a meeting") }
        return isPaused ? String(localized: "Paused") : status.title
    }
    let dictation: DictationController?
    let meeting: MeetingController?
    let preferences: UserDefaults
    private let queueHotkeyManager: (any HotkeyManaging)?
    private let queueShortcutStore: any ShortcutStoring

    let pipelineCoordinator: PipelineCoordinator
    private let hotkeyManager: any HotkeyManaging
    private let shortcutStore: any ShortcutStoring
    private let selectionController: any RegionSelectionControlling
    private let captureService: any ScreenCapturing
    private let escapeMonitor: any EscapeMonitoring
    private let ocrService: any TextRecognizing
    private let speechService: any SpeechReading
    private let readingPanel: (any ReadingStatusPresenting)?
    private let interfaceSounds: (any InterfaceSoundPlaying)?
    private let operationTimeout: Duration
    private let waitForQueueTimeout: @Sendable (Duration) async throws -> Void
    private let speechStartupTimeout: Duration
    private var activeContext: PipelineOperationContext?
    private var interactionTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var speechTimeoutGeneration: UInt64 = 0

    isolated deinit {
        if let terminationObserver { appNotifications.removeObserver(terminationObserver) }
        dictation?.shutdown()
        readingPanel?.hide()
        stopResources()
        hotkeyManager.unregister()
        queueHotkeyManager?.unregister()
    }

    init(
        modelTerms: ModelTermsAcceptance = ModelTermsAcceptance(),
        shortcutStore: any ShortcutStoring = UserDefaultsShortcutStore(),
        pipelineCoordinator: PipelineCoordinator = PipelineCoordinator(),
        hotkeyManager: any HotkeyManaging = GlobalHotkeyManager(),
        selectionController: any RegionSelectionControlling = RegionSelectionOverlayController(),
        captureService: any ScreenCapturing = ScreenCaptureService(),
        escapeMonitor: any EscapeMonitoring = EscapeMonitor(),
        ocrService: any TextRecognizing = VisionOCRService(),
        speechService: any SpeechReading = LocalSpeechService(),
        readingPanel: (any ReadingStatusPresenting)? = nil,
        interfaceSounds: (any InterfaceSoundPlaying)? = nil,
        operationTimeout: Duration = .seconds(15),
        waitForQueueTimeout: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        speechStartupTimeout: Duration = .seconds(90),
        preferences: UserDefaults = InterfaceSoundPlayer.defaults,
        queueHotkeyManager: (any HotkeyManaging)? = nil,
        queueShortcutStore: any ShortcutStoring = UserDefaultsShortcutStore(preferenceKey: "enqueueShortcut.v1"),
        dictation: DictationController? = nil,
        meeting: MeetingController? = nil,
        missingReadingPermission: @escaping @MainActor () -> SaywingPermission? = { nil },
        appNotifications: NotificationCenter = .default
    ) {
        self.appNotifications = appNotifications
        self.modelTerms = modelTerms
        self.modelTermsState = modelTerms.state
        self.dictation = dictation
        self.meeting = meeting
        self.missingReadingPermission = missingReadingPermission
        self.pipelineCoordinator = pipelineCoordinator
        self.shortcutStore = shortcutStore
        self.shortcutConfiguration = shortcutStore.load() ?? .default
        self.hotkeyManager = hotkeyManager
        self.selectionController = selectionController
        self.captureService = captureService
        self.escapeMonitor = escapeMonitor
        self.ocrService = ocrService
        self.speechService = speechService
        self.readingPanel = readingPanel
        self.interfaceSounds = interfaceSounds
        self.operationTimeout = operationTimeout
        self.waitForQueueTimeout = waitForQueueTimeout
        self.speechStartupTimeout = speechStartupTimeout
        self.preferences = preferences
        self.queueHotkeyManager = queueHotkeyManager
        self.queueShortcutStore = queueShortcutStore
        self.queueShortcutConfiguration = queueShortcutStore.load() ?? .queueDefault
        self.playbackRate = SpeechSpeed.validated(preferences.object(forKey: SpeechSpeed.preferenceKey) as? Double ?? 1)
        speechService.playbackRate = playbackRate
        readingPanel?.configureControls { [weak self] view in self?.showPlaybackControls(from: view) }
        readingPanel?.configurePause { [weak self] in self?.togglePause() }
        hotkeyManager.onPress = { [weak self] in self?.enqueuePrimaryShortcut() }
        hotkeyRegistration = hotkeyManager.register(shortcutConfiguration.resolvedShortcut())
        if hotkeyRegistration != .registered {
            status = .error
            errorMessage = Self.registrationErrorMessage(for: hotkeyRegistration, shortcut: shortcutConfiguration)
        }
        queueHotkeyManager?.onPress = { [weak self] in self?.enqueueAddRequest() }
        if queueShortcutConfiguration == shortcutConfiguration {
            queueShortcutNotice = String(localized: "Choose an additional shortcut different from the primary shortcut. The primary shortcut and menu action remain available.")
        } else if let result = queueHotkeyManager?.register(queueShortcutConfiguration.resolvedShortcut()), result != .registered {
            queueShortcutNotice = Self.registrationErrorMessage(for: result, shortcut: queueShortcutConfiguration)
        }
        if let dictation {
            dictationObservation = Publishers.Merge(dictation.objectWillChange, dictation.models.objectWillChange)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        // A meeting transcript runs beside reading and dictation; neither stops it.
        meetingObservation = meeting?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Quitting must not leave the speech worker running. The dictation controller
        // and the meeting transcript stop their own processes and devices on this notification.
        terminationObserver = appNotifications.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.speechService.stop() } }
        dictation?.onOpenSetup = { [weak self] in self?.showSetup(entry: .dictation) }
        dictation?.onActivation = { [weak self] start in
            self?.enqueue { model in
                if let context = model.activeContext { await model.cancel(context: context) }
                model.interfaceSounds?.stop()
                model.readingPanel?.hide()
                start()
            }
        }

    }

    var readActionTitle: String {
        activeContext == nil ? String(localized: "Read Screen Region…") : String(localized: "Stop Reading")
    }
    /// Playback controls appear in the menu only while there is something to control.
    var isReadingActive: Bool { activeContext != nil }
    var canChangeShortcut: Bool { activeContext == nil && dictation?.isActive != true }
    var canAddToQueue: Bool {
        !isAddingToQueue && queuedTextCount < Self.queueLimit
            && (activeContext == nil || status == .synthesizing || status == .speaking || status == .waiting)
    }
    var canSkipText: Bool { activeContext != nil && queuedTextCount > 0 }

    /// Only an explicit choice in Setup or Settings changes the acceptance. Withdrawing
    /// it stops reading at once; dictation and meeting transcripts are unaffected.
    func setModelTermsAccepted(_ accepted: Bool) {
        modelTermsState = modelTerms.setAccepted(accepted)
        if modelTermsState == .accepted {
            if status == .error, let modelTermsError, errorMessage == modelTermsError {
                status = .ready
                errorMessage = nil
            }
            modelTermsError = nil
        } else if activeContext != nil {
            enqueue { model in
                guard !model.modelTerms.isAccepted, let context = model.activeContext else { return }
                await model.cancel(context: context)
            }
        }
    }

    /// Opens Setup on the reading voice page, where the terms are shown and accepted.
    func showModelTerms() { showSetup(entry: .modelTerms) }

    /// The setup page currently shown, if Setup is open.
    var setupStep: SetupStep? { setupFlow?.step }

    var modelTermsMessage: String {
        switch modelTermsState {
        case .unavailable:
            String(localized: "The Supertonic 3 model terms are missing from this copy of Saywing, so reading aloud is unavailable. Reinstall Saywing to restore them.")
        case .changed:
            String(localized: "The Supertonic 3 model terms have changed. Accept them again to read aloud. Nothing was captured.")
        case .accepted, .notAccepted:
            String(localized: "Saywing reads aloud only after you accept the Supertonic 3 model terms. Nothing was captured.")
        }
    }

    /// Nothing is captured, recognized or spoken: the explanation appears in the menu
    /// and Setup opens on the terms, as it does for a missing permission.
    private func requireModelTerms() {
        modelTermsState = modelTerms.state
        status = .error
        errorMessage = modelTermsMessage
        modelTermsError = errorMessage
        AccessibilityNotification.Announcement(modelTermsMessage).post()
        showModelTerms()
    }

    func setPlaybackRate(_ value: Double) {
        playbackRate = SpeechSpeed.validated(value)
        speechService.playbackRate = playbackRate
        preferences.set(playbackRate, forKey: SpeechSpeed.preferenceKey)
    }

    /// While a shortcut field records, the global shortcuts must not swallow the
    /// keystroke the user is trying to assign. Recording ends before a change applies.
    private var isRecordingShortcut = false
    func setRecordingShortcut(_ recording: Bool) {
        guard !recording || canChangeShortcut else { return }
        guard recording != isRecordingShortcut else { return }
        isRecordingShortcut = recording
        dictation?.setShortcutsSuspended(recording)
        if recording {
            hotkeyManager.unregister()
            queueHotkeyManager?.unregister()
            return
        }
        hotkeyRegistration = hotkeyManager.register(shortcutConfiguration.resolvedShortcut())
        if queueShortcutConfiguration != shortcutConfiguration {
            _ = queueHotkeyManager?.register(queueShortcutConfiguration.resolvedShortcut())
        }
    }

    func enqueueQueueShortcutChange(_ configuration: ShortcutConfiguration) {
        enqueue { model in
            guard configuration != (model.dictation?.shortcutConfiguration ?? .dictationDefault) else {
                model.queueShortcutNotice = String(localized: "This shortcut is already assigned to dictation.")
                return
            }
            guard model.canChangeShortcut else { return }
            guard configuration.isValid, configuration != model.shortcutConfiguration else {
                model.queueShortcutNotice = String(localized: "Choose a valid additional shortcut different from the primary shortcut.")
                return
            }
            guard let manager = model.queueHotkeyManager else { return }
            let result = manager.register(configuration.resolvedShortcut())
            guard result == .registered else {
                model.queueShortcutNotice = Self.registrationErrorMessage(for: result, shortcut: configuration)
                return
            }
            model.queueShortcutConfiguration = configuration
            model.queueShortcutStore.save(configuration)
            model.queueShortcutNotice = String(localized: "Add shortcut \(configuration.displayName) is active and saved.")
        }
    }

    func enqueueShortcutChange(_ configuration: ShortcutConfiguration) {
        enqueue { $0.changeShortcut(configuration) }
    }

    func enqueueDictationShortcutChange(_ configuration: ShortcutConfiguration) {
        enqueue { model in
            guard model.canChangeShortcut, !model.isRecordingShortcut, let dictation = model.dictation else { return }
            guard configuration != model.shortcutConfiguration, configuration != model.queueShortcutConfiguration else {
                dictation.rejectShortcut(String(localized: "This shortcut is already assigned to reading. Choose another combination."))
                return
            }
            dictation.changeShortcut(configuration)
        }
    }

    private func changeShortcut(_ configuration: ShortcutConfiguration) {
        guard canChangeShortcut else {
            shortcutNotice = String(localized: "Stop the current operation before changing its shortcut.")
            return
        }
        guard configuration != (dictation?.shortcutConfiguration ?? .dictationDefault) else {
            shortcutNotice = String(localized: "This shortcut is already assigned to dictation.")
            return
        }
        guard configuration.isValid else {
            shortcutNotice = String(localized: "Choose a key and at least Command, Option, or Control. Escape is reserved for cancellation.")
            return
        }
        guard configuration != queueShortcutConfiguration else {
            shortcutNotice = String(localized: "Primary and additional shortcut combinations must be different.")
            return
        }
        let result = hotkeyManager.register(configuration.resolvedShortcut())
        guard result == .registered else {
            shortcutNotice = Self.registrationErrorMessage(for: result, shortcut: configuration)
            return
        }
        if hotkeyRegistration != .registered {
            status = .ready
            errorMessage = nil
        }
        hotkeyRegistration = .registered
        shortcutConfiguration = configuration
        shortcutStore.save(configuration)
        shortcutNotice = String(localized: "Shortcut \(configuration.displayName) is active and saved.")
    }

    func previewReadingPanelPosition() {
        guard canChangeShortcut,
              let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        readingPanel?.show(.positioning, displayID: number.uint32Value, onStop: nil)
    }

    /// Only what the status line cannot say: how to add or stop while reading,
    /// and what the last recognition found. Nil keeps the idle menu short.
    var captureFeedback: String? {
        switch status {
        case .speaking:
            return String(localized: "Press \(shortcutConfiguration.displayName) to add text. Escape stops.")
        case .waiting:
            return String(localized: "Waiting for the next text. Escape stops.")
        case .selecting, .capturing, .recognizing, .synthesizing:
            return nil
        case .ready, .stopped, .error:
            guard let summary = lastOCRSummary else { return nil }
            if summary.characterCount == 0 { return String(localized: "No readable text found. Select a clearer region.") }
            return String(localized: "Recognized \(summary.characterCount) characters in \(summary.lineCount) lines.")
        }
    }

    // Serialize only short control transitions. Never queue cancellation behind capture.
    private func enqueue(_ action: @escaping @MainActor (AppModel) async -> Void) {
        let previous = interactionTask
        interactionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await action(self)
        }
    }

    // The shortcut always selects/adds; the menu's explicit Stop Reading action
    // remains separate so it never opens a selection instead of stopping.
    func enqueuePrimaryShortcut() { guard !isRecordingShortcut else { return }; dictation?.cancelForReading(); enqueue { await $0.addToQueue() } }
    func enqueueReadRequest() { dictation?.cancelForReading(); enqueue { await $0.processReadRequest() } }
    func enqueueAddRequest() { guard !isRecordingShortcut else { return }; dictation?.cancelForReading(); enqueue { await $0.addToQueue() } }
    func enqueueSkipRequest() {
        enqueue { model in
            guard model.canSkipText, let context = model.activeContext else { return }
            model.stopSpeechResources()
            await model.finishSpeech(context: context)
        }
    }
    func waitForQueueInputToSettle() async {
        await interactionTask?.value
        await queueInputTask?.value
        await interactionTask?.value
    }

    func handleReadRequest() async {
        enqueueReadRequest()
        await waitForInteractionToSettle()
    }

    func waitForInteractionToSettle() async { await interactionTask?.value }

    func waitForTimeoutToSettle() async {
        await timeoutTask?.value
        await interactionTask?.value
    }

    func waitForCaptureToSettle() async {
        await captureTask?.value
        await interactionTask?.value
        await recognitionTask?.value
        await interactionTask?.value
    }

    func waitForSpeechToSettle() async {
        await speechTask?.value
        await interactionTask?.value
    }

    private func processReadRequest() async {
        interfaceSounds?.stop()
        guard hotkeyRegistration == .registered else {
            status = .error
            errorMessage = Self.registrationErrorMessage(for: hotkeyRegistration, shortcut: shortcutConfiguration)
            return
        }
        if let activeContext {
            await cancel(context: activeContext)
            return
        }
        // Dragging a region that can only fail afterwards wastes the gesture.
        if missingReadingPermission() != nil {
            showSetup()
            return
        }
        guard modelTerms.isAccepted else {
            requireModelTerms()
            return
        }
        sessionGeneration &+= 1
        queueNotice = nil
        switch await pipelineCoordinator.start() {
        case let .started(context):
            readingPanel?.hide()
            activeContext = context
            status = .selecting
            lastSelection = nil
            lastCaptureSize = nil
            lastOCRSummary = nil
            errorMessage = nil
            selectionController.start(
                onSelection: { [weak self] selection in
                    self?.enqueue { await $0.beginCapture(selection, context: context) }
                },
                onCancel: { [weak self] _ in
                    self?.enqueue { await $0.cancel(context: context) }
                }
            )
        case let .cleanupRequired(directive):
            readingPanel?.hide()
            stopResources()
            _ = await pipelineCoordinator.finishCleanup(for: directive.context)
            activeContext = nil
            status = .stopped
        }
    }

    private func beginCapture(_ selection: ScreenRegionSelection, context: PipelineOperationContext) async {
        guard context == activeContext,
              await pipelineCoordinator.accept(.capturing, for: context) else { return }
        lastSelection = selection
        readingPanel?.hide()
        selectionController.cancel()
        do {
            let session = sessionGeneration
            try escapeMonitor.start(
                onEscape: { [weak self] in
                    self?.enqueue {
                        guard $0.sessionGeneration == session, let active = $0.activeContext else { return }
                        await $0.cancel(context: active)
                    }
                },
                onUnavailable: { [weak self] in
                    self?.enqueue {
                        guard $0.sessionGeneration == session, let active = $0.activeContext else { return }
                        await $0.fail(context: active, message: EscapeMonitorFailure.unavailable.localizedDescription)
                    }
                }
            )
        } catch {
            await fail(context: context, message: error.localizedDescription)
            return
        }
        status = .capturing
        let service = captureService
        captureTask = Task { @MainActor [weak self] in
            do {
                let image = try await service.capture(selection)
                try Task.checkCancellation()
                let size = CGSize(width: image.width, height: image.height)
                self?.enqueue { await $0.beginRecognition(image, size: size, context: context) }
            } catch is CancellationError {
                self?.enqueue { await $0.cancel(context: context) }
            } catch {
                let message = (error as? ScreenCaptureFailure)?.localizedDescription
                    ?? ScreenCaptureFailure.failed.localizedDescription
                self?.enqueue { await $0.fail(context: context, message: message) }
            }
        }
        let timeout = operationTimeout
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.enqueue {
                guard $0.status == .capturing || $0.status == .recognizing else { return }
                await $0.fail(context: context, message: String(localized: "Capture or text recognition timed out. Please try a smaller region."))
            }
        }
    }

    private func beginRecognition(
        _ image: CGImage, size: CGSize, context: PipelineOperationContext
    ) async {
        guard context == activeContext,
              await pipelineCoordinator.accept(.recognizing, for: context) else { return }
        status = .recognizing
        showReadingPanel(.recognizing, context: context)
        let service = ocrService
        let selection = lastSelection
        recognitionTask = Task { @MainActor [weak self] in
            do {
                let recognized = try await service.recognize(image)
                // A click keeps only its paragraph; the surrounding text is dropped here.
                let result = selection?.focusedText(recognized) ?? recognized
                try Task.checkCancellation()
                self?.enqueue { await $0.finishRecognition(result: result, size: size, context: context) }
            } catch is CancellationError {
                self?.enqueue { await $0.cancel(context: context) }
            } catch {
                let message = (error as? OCRFailure)?.localizedDescription
                    ?? OCRFailure.recognitionFailed.localizedDescription
                self?.enqueue { await $0.fail(context: context, message: message) }
            }
        }
    }

    private func finishRecognition(
        result: OCRResult, size: CGSize, context: PipelineOperationContext
    ) async {
        guard context == activeContext else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        lastCaptureSize = size
        lastOCRSummary = OCRSummary(characterCount: result.characterCount, lineCount: result.lineCount)
        guard !result.text.isEmpty else { await finishSpeech(context: context); return }
        // Withdrawn while this region was recognized: stop, as the withdrawal itself does.
        guard modelTerms.isAccepted else {
            await cancel(context: context)
            return
        }
        guard await pipelineCoordinator.accept(.synthesizing, for: context) else { return }
        status = .synthesizing
        showReadingPanel(.preparing, context: context)
        armSpeechTimeout(speechStartupTimeout, context: context)
        let service = speechService
        let text = result.speechText
        speechTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                try await service.read(text) { [weak self] in
                    self?.enqueue { await $0.speechPlaybackStarted(context: context) }
                }
                try Task.checkCancellation()
                self?.enqueue { await $0.finishSpeech(context: context) }
            } catch is CancellationError {
                self?.enqueue { await $0.cancel(context: context) }
            } catch {
                let failure = error as? SpeechFailure ?? .failed
                self?.enqueue { await $0.fail(context: context, message: failure.localizedDescription, needsReinstall: failure.needsReinstall) }
            }
        }
    }

    private func speechPlaybackStarted(context: PipelineOperationContext) async {
        guard context == activeContext else { return }
        if status == .synthesizing {
            interfaceSounds?.stop()
            guard await pipelineCoordinator.accept(.speaking, for: context) else { return }
            status = .speaking
            showReadingPanel(.speaking, context: context)
            levelTask?.cancel()
            levelTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        guard let self, self.activeContext == context, self.status == .speaking else { return }
                        self.readingPanel?.updateLevel(self.isPaused ? 0 : self.speechService.playbackLevel)
                    }
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
        }
        speechService.prepareNext(queuedTexts.first?.result.speechText)
        if !isPaused { armSpeechTimeout(.seconds(30), context: context) }
    }

    private func armSpeechTimeout(_ duration: Duration, context: PipelineOperationContext) {
        timeoutTask?.cancel()
        speechTimeoutGeneration &+= 1
        let timerGeneration = speechTimeoutGeneration
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.enqueue {
                guard $0.speechTimeoutGeneration == timerGeneration else { return }
                await $0.fail(context: context, message: SpeechFailure.timedOut.localizedDescription)
            }
        }
    }

    private func finishSpeech(context: PipelineOperationContext) async {
        guard context == activeContext else { return }
        if !queuedTexts.isEmpty {
            guard await pipelineCoordinator.complete(context) else { return }
            stopSpeechResources()
            // Settings edits the queue directly, so it may have been emptied while
            // this was suspended. Re-check instead of assuming the earlier state.
            guard !queuedTexts.isEmpty else {
                await finishAfterQueueEmptied(context: context)
                return
            }
            let next = queuedTexts.removeFirst()
            updateQueuePresentation()
            guard case let .started(nextContext) = await pipelineCoordinator.start() else {
                await fail(context: context, message: String(localized: "The next text could not start. Please select it again."))
                return
            }
            activeContext = nextContext
            lastSelection = next.selection
            _ = await pipelineCoordinator.accept(.capturing, for: nextContext)
            _ = await pipelineCoordinator.accept(.recognizing, for: nextContext)
            await finishRecognition(result: next.result, size: next.size, context: nextContext)
            return
        }
        if isAddingToQueue {
            stopSpeechResources()
            status = .waiting
            showReadingPanel(.waiting, context: context)
            return
        }
        guard context == activeContext, await pipelineCoordinator.complete(context) else { return }
        stopResources()
        activeContext = nil
        status = .ready
        showReadingPanel(lastOCRSummary?.characterCount == 0 ? .noText : .finished, context: context)
        interfaceSounds?.play(lastOCRSummary?.characterCount == 0 ? .attention : .completion)
    }

    /// The coordinator already completed `context`; nothing is left to read.
    private func finishAfterQueueEmptied(context: PipelineOperationContext) async {
        guard context == activeContext else { return }
        updateQueuePresentation()
        if isAddingToQueue {
            // An added region is still being recognized: wait for it under a fresh generation.
            guard case let .started(waiting) = await pipelineCoordinator.start() else {
                await fail(context: context, message: String(localized: "The next text could not start. Please select it again."))
                return
            }
            activeContext = waiting
            status = .waiting
            showReadingPanel(.waiting, context: waiting)
            return
        }
        stopResources()
        activeContext = nil
        status = .ready
        showReadingPanel(lastOCRSummary?.characterCount == 0 ? .noText : .finished, context: context)
        interfaceSounds?.play(lastOCRSummary?.characterCount == 0 ? .attention : .completion)
    }

    private func fail(context: PipelineOperationContext, message: String, needsReinstall: Bool = false) async {
        guard context == activeContext else { return }
        speechService.stop()
        _ = await pipelineCoordinator.fail(context)
        activeContext = nil
        // The list ends with the run (docs/privacy.md), so the message has to say so.
        let clearedQueue = !queuedTexts.isEmpty
        stopResources()
        status = .error
        lastFailureNeedsReinstall = needsReinstall
        errorMessage = clearedQueue ? "\(message) \(String(localized: "The waiting texts were cleared. Select them again to read them."))" : message
        showReadingPanel(.failed, context: context)
        interfaceSounds?.play(.attention)
    }

    private func cancel(context: PipelineOperationContext) async {
        guard context == activeContext else { return }
        interfaceSounds?.stop()
        speechService.stop()
        let directive = await pipelineCoordinator.cancel()
        activeContext = nil
        stopResources()
        if let directive { _ = await pipelineCoordinator.finishCleanup(for: directive.context) }
        status = .stopped
        showReadingPanel(.stopped, context: context)
    }

    private func showReadingPanel(_ state: ReadingPanelState, context: PipelineOperationContext) {
        guard !queueOverlayVisible else { readingPanel?.hide(); return }
        guard let selection = lastSelection else { readingPanel?.hide(); return }
        let stop: (() -> Void)? = state.isActive ? { [weak self] in
            self?.enqueue { await $0.cancel(context: context) }
        } : nil
        readingPanel?.show(state, displayID: selection.displayID,
                           origin: state == .recognizing ? selection.flightOrigin : nil, onStop: stop)
        readingPanel?.updateQueueCount(queuedTextCount)
    }

    private func stopSpeechResources() {
        isPaused = false
        readingPanel?.updatePaused(false)
        levelTask?.cancel()
        levelTask = nil
        readingPanel?.updateLevel(0)
        interfaceSounds?.stop()
        speechService.stopCurrent()
        speechTask?.cancel()
        timeoutTask?.cancel()
        timeoutTask = nil
        speechTimeoutGeneration &+= 1
    }

    private func stopResources() {
        controlsPopover?.close()
        controlsPopover?.contentViewController = nil
        controlsPopover = nil
        stopSpeechResources()
        speechService.stop()
        sessionGeneration &+= 1
        queueInputID = nil
        queueInputTask?.cancel()
        queueInputTimeout?.cancel()
        queueInputTimeout = nil
        isAddingToQueue = false
        queueOverlayVisible = false
        queuedTexts.removeAll(keepingCapacity: false)
        updateQueuePresentation()
        captureTask?.cancel()
        recognitionTask?.cancel()
        timeoutTask?.cancel()
        timeoutTask = nil
        selectionController.cancel()
        escapeMonitor.stop()
    }

    private func addToQueue() async {
        controlsPopover?.close()
        guard canAddToQueue else {
            queueNotice = queuedTextCount >= Self.queueLimit ? String(localized: "Queue full (5 texts). Wait for a text to finish.")
                : String(localized: "Finish the current selection or recognition before adding another text.")
            return
        }
        guard activeContext != nil else { await processReadRequest(); return }
        let id = UUID()
        queueInputID = id
        isAddingToQueue = true
        queueOverlayVisible = true
        queueNotice = String(localized: "Select another region. Playback continues; Escape stops everything.")
        readingPanel?.hide()
        let session = sessionGeneration
        selectionController.start(onSelection: { [weak self] selection in
            self?.enqueue { $0.captureQueueInput(selection, id: id) }
        }, onCancel: { [weak self] reason in
            self?.enqueue {
                guard $0.queueInputID == id, $0.sessionGeneration == session, let active = $0.activeContext else { return }
                // Only Escape stops everything. A too-small drag or a display change
                // ends this added selection alone; playback continues.
                switch reason {
                case .escape: await $0.cancel(context: active)
                case .invalidSelection:
                    await $0.rejectQueueInput(id: id, message: String(localized: "The additional region was too small to read. Press the shortcut to select it again."))
                case .displaysChanged:
                    await $0.rejectQueueInput(id: id, message: String(localized: "The displays changed. Press the shortcut to select the additional region again."))
                }
            }
        })
    }

    private func captureQueueInput(_ selection: ScreenRegionSelection, id: UUID) {
        guard queueInputID == id else { return }
        selectionController.cancel()
        queueNotice = String(localized: "Recognizing the next text locally…")
        let capture = captureService, ocr = ocrService
        queueInputTask = Task { @MainActor [weak self] in
            do {
                let image = try await capture.capture(selection)
                try Task.checkCancellation()
                guard self?.queueInputID == id else { return }
                let size = CGSize(width: image.width, height: image.height)
                self?.enqueue { model in
                    guard model.queueInputID == id else { return }
                    model.queueOverlayVisible = false
                    model.restoreReadingPanel()
                }
                let result = selection.focusedText(try await ocr.recognize(image))
                try Task.checkCancellation()
                self?.enqueue { await $0.finishQueueInput(result, selection: selection, size: size, id: id) }
            } catch is CancellationError {
                self?.enqueue { await $0.rejectQueueInput(id: id, message: String(localized: "The additional capture was cancelled.")) }
            } catch {
                self?.enqueue { await $0.rejectQueueInput(id: id, message: String(localized: "The additional region could not be recognized. Select it again.")) }
            }
        }
        queueInputTimeout?.cancel()
        queueInputTimeout = Task { @MainActor [weak self, operationTimeout, waitForQueueTimeout] in
            do { try await waitForQueueTimeout(operationTimeout); try Task.checkCancellation() } catch { return }
            self?.enqueue { await $0.rejectQueueInput(id: id, message: String(localized: "The additional capture or text recognition timed out.")) }
        }
    }

    private func finishQueueInput(_ result: OCRResult, selection: ScreenRegionSelection, size: CGSize, id: UUID) async {
        guard queueInputID == id else { return }
        guard !result.text.isEmpty else {
            await rejectQueueInput(id: id, message: String(localized: "No readable text in the additional region."))
            return
        }
        guard result.text.count <= 8_000, result.text.utf8.count <= 48_000 else {
            await rejectQueueInput(id: id, message: SpeechFailure.tooLong.localizedDescription)
            return
        }
        queuedTexts.append(QueuedText(result: result, selection: selection, size: size))
        endQueueInput()
        queueNotice = String(localized: "Added to queue.")
        updateQueuePresentation()
        if status == .speaking { speechService.prepareNext(queuedTexts.first?.result.speechText) }
        if status == .waiting, let context = activeContext { await finishSpeech(context: context) }
        else { restoreReadingPanel() }
    }

    private func rejectQueueInput(id: UUID, message: String) async {
        guard queueInputID == id else { return }
        endQueueInput()
        queueNotice = message
        if status == .waiting, let context = activeContext { await finishSpeech(context: context) }
        else { restoreReadingPanel() }
    }

    private func endQueueInput() {
        queueInputID = nil
        queueInputTask?.cancel()
        queueInputTimeout?.cancel()
        queueInputTimeout = nil
        isAddingToQueue = false
        queueOverlayVisible = false
    }

    private func updateQueuePresentation() {
        queuedTextCount = queuedTexts.count
        readingPanel?.updateQueueCount(queuedTextCount)
    }

    private func restoreReadingPanel() {
        guard let context = activeContext, let selection = lastSelection, !queueOverlayVisible else { return }
        let state: ReadingPanelState = status == .speaking ? .speaking : status == .waiting ? .waiting : .preparing
        readingPanel?.restore(state, displayID: selection.displayID, onStop: { [weak self] in
            self?.enqueue { await $0.cancel(context: context) }
        })
        readingPanel?.updateQueueCount(queuedTextCount)
        readingPanel?.updatePaused(isPaused)
    }

    static func registrationErrorMessage(
        for registration: HotkeyRegistration, shortcut: ShortcutConfiguration
    ) -> String? {
        switch registration {
        case .inactive, .registered: nil
        case .conflict: String(localized: "The shortcut \(shortcut.displayName) is already in use. Quit any other Saywing or OpenScreenReader copy, then choose it again under Settings › Shortcuts, or record a different one.")
        case let .failed(status): String(localized: "The global shortcut could not be registered (error \(status)).")
        }
    }
}
