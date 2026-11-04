import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Status first, then the primary action with its shortcut. Playback controls
/// appear only while something is reading; settings and quit stay at the bottom.
struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label(model.isPaused ? String(localized: "Paused") : model.status.title,
              systemImage: model.isPaused ? "pause.fill" : model.status.symbolName)
            .accessibilityLabel("Status")
            .accessibilityValue(model.isPaused ? String(localized: "Paused") : model.status.title)
        if let feedback = model.captureFeedback {
            Text(feedback)
        }
        if let errorMessage = model.errorMessage {
            Text(errorMessage)
            if model.errorHelp == .acceptModelTerms {
                Button("Review Model Terms…") { model.showModelTerms() }
            } else if model.errorHelp != .reinstall {
                Button("Open Setup…") { model.showSetup() }
            }
        }

        Divider()

        readButton
        if let dictation = model.dictation {
            DictationMenuContent(controller: dictation)
        }
        if let meeting = model.meeting {
            MeetingMenuContent(controller: meeting)
        }

        if model.isReadingActive {
            Divider()
            Button(model.isPaused ? String(localized: "Resume Reading") : String(localized: "Pause Reading")) { model.togglePause() }
                .disabled(!model.canPause)
            Button("Next Text") { model.enqueueSkipRequest() }
                .disabled(!model.canSkipText)
            Button("Add Screen Region to Queue…") { model.enqueueAddRequest() }
                .disabled(!model.canAddToQueue)
            Button("Playback Controls…") { model.openPlaybackControls() }
            if model.queuedTextCount > 0 {
                Text("\(model.queuedTextCount) texts waiting")
            }
            if let notice = model.queueNotice { Text(notice) }
        }

        Divider()

        Menu("Speed · \(SpeechSpeed.label(model.playbackRate))") {
            ForEach(SpeechSpeed.presets, id: \.self) { speed in
                Toggle(SpeechSpeed.label(speed), isOn: Binding(
                    get: { model.playbackRate == speed },
                    set: { if $0 { model.setPlaybackRate(speed) } }))
            }
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Set Up & Test…") { model.showSetup() }
        AppUpdateMenu(updates: model.updates, busy: model.isBusyForUpdates)

        Divider()

        Button("Quit Saywing") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// The global shortcut is shown next to the action, as macOS menus do.
    @ViewBuilder private var readButton: some View {
        let button = Button(model.readActionTitle) { model.enqueueReadRequest() }
            .help(model.isReadingActive ? String(localized: "Stop reading and clear the queue. Escape also stops.") : "")
        if !model.isReadingActive, let shortcut = model.shortcutConfiguration.keyboardShortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

struct DictationMenuContent: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        if controller.isActive {
            Text("Dictation · \(controller.statusText)")
            if controller.phase == "recording" {
                Button("Finish & Paste") { controller.finishRecording() }
            }
            Button("Discard Dictation") { controller.cancel() }
        } else {
            // Show the configured activation even when Fn gestures are disabled.
            Text("Dictate · \(controller.shortcutConfiguration.displayName)")
            Button("Try Dictation…") { controller.showWindow() }
        }
    }
}

struct MeetingMenuContent: View {
    @ObservedObject var controller: MeetingController
    var body: some View {
        if controller.isRecording {
            Text("Meeting Transcript · Running")
            Button("Show Transcript") { controller.showWindow() }
            Button("Stop Transcript") { controller.stop() }
        } else if controller.phase == .finished {
            Button("Show Meeting Transcript…") { controller.showWindow() }
        } else {
            Button("Transcribe a Meeting…") { Task { await controller.open() } }
        }
    }
}

extension ShortcutConfiguration {
    var keyboardShortcut: KeyboardShortcut? {
        guard isValid else { return nil }
        let keyEquivalent: KeyEquivalent = key == "Space" ? .space : KeyEquivalent(Character(key.lowercased()))
        var eventModifiers: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { eventModifiers.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { eventModifiers.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { eventModifiers.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { eventModifiers.insert(.shift) }
        return KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }
}

/// The menu bar glyph carries state by shape, never by colour: a dot while
/// reading, a small triangle when something failed, a ring while a meeting
/// transcript runs. Dictation needs no badge; macOS shows its microphone
/// indicator. A meeting transcript also hears other apps, so it shows its own.
@MainActor
enum MenuBarIcon {
    private static var cache: [AppModel.MenuBarIndicator: NSImage] = [:]

    static func image(for indicator: AppModel.MenuBarIndicator) -> NSImage {
        if let cached = cache[indicator] { return cached }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSImage(named: "SaywingMenuBar")?.draw(in: rect)
            guard indicator != .idle, let context = NSGraphicsContext.current?.cgContext else { return true }
            let badge = CGRect(x: rect.maxX - 9, y: 0, width: 9, height: 9)
            // A clear ring keeps the badge legible against the glyph.
            context.setBlendMode(.clear)
            context.fillEllipse(in: badge.insetBy(dx: -1.5, dy: -1.5))
            context.setBlendMode(.normal)
            context.setFillColor(NSColor.black.cgColor)
            if indicator == .reading {
                context.fillEllipse(in: badge.insetBy(dx: 1, dy: 1))
            } else if indicator == .recording {
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(1.6)
                context.strokeEllipse(in: badge.insetBy(dx: 1.3, dy: 1.3))
            } else {
                context.move(to: CGPoint(x: badge.midX, y: badge.maxY))
                context.addLine(to: CGPoint(x: badge.maxX, y: badge.minY))
                context.addLine(to: CGPoint(x: badge.minX, y: badge.minY))
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        cache[indicator] = image
        return image
    }
}
