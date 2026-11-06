# Privacy principles and requirements

## Principle

Saywing (formerly OpenScreenReader) may process highly sensitive screen data. Privacy is therefore not a marketing option but a technical invariant. The rename does not change these requirements. Since 2026-10-13, local dictation is integrated as a separate flow; the clipboard exception described below applies only to its explicitly started pasting.

## Mandatory defaults

- The official MVP includes its default model; after installation, OCR and TTS run entirely locally.
- No account and no sign-in.
- No telemetry in the official build.
- No cloud sync.
- No automatic clipboard writes while reading aloud. For an explicitly started recording, dictation may paste via Cmd+V and restore the fully backed-up clipboard after 1–2 s, as long as no new content has been copied. No retry when the outcome is unclear.
- No persistent storage of screenshots, OCR text or audio.
- No silent network fallbacks when a local model fails.
- Permissions are requested only when the corresponding feature is used.

## Network access

The MVP runtime path must not require or establish a network connection on its own. The default model ships with the signed release artifact from the project website. Before the website download, at least the following is shown:

- model name and version;
- source;
- expected size;
- license;
- installed size and system requirements;
- integrity check or SHA-256 hash.

**Exception for app updates (since 2026-10-14):** Configured release builds check for new versions over HTTPS on every app launch, immediately after the updater starts, and afterwards on Sparkle's four-hour schedule (since 2026-10-15). The launch check respects disabled automatic update checks. Only available updates that have not been skipped are offered; if there is no update or no connection, no launch dialog appears. Active reading, dictation and model installation operations keep their existing protection. Settings → General allows turning this off and checking manually. The server sees the IP address and the usual HTTP metadata; no screen, text or audio data is transmitted, and optional system profiles are turned off. Signed update files are downloaded/installed only on user action; if work is still active at relaunch, the relaunch is postponed and only resumes when the user chooses “Install Update and Restart…” again after the work has finished. Quitting the app drops a postponed relaunch. Release notes are not fetched separately. Developer builds without a valid feed configuration do not start an updater. A missing connection blocks neither reading aloud nor dictation. [Release and update procedure](release-and-updates.md).

**Exception for dictation models (since 2026-10-14):** Builds bundle only
Whisper Turbo. The app downloads Qwen3-ASR and Whisper Large v3 only when the user
chooses “Install …” in Settings → Dictation and confirms the dialog showing size and
source. The app then fetches over HTTPS only the Hugging Face revision pinned in the
bundled manifest; redirects are allowed only to
`huggingface.co`/`*.hf.co`. The request contains no user data, no cookies and uses
no cache. Before use, every file is checked against the size and SHA-256 from the
manifest, and only then moved to
`~/Library/Application Support/Saywing/DictationModels`; cancellation or a failed
check leaves nothing behind. License texts come from the app bundle. A download that delivers more bytes than
pinned or announces a different length is cancelled immediately. Verified files are
stored read-only (0444); when model management starts, leftover `.staging-*` folders
from a crashed run are deleted. The dictation worker itself stays without network
access, re-checks the hashes on load, refuses model folders containing files not
listed in the manifest (except `.DS_Store`, `VERIFIED.json` and the license copies
`LICENSE-OpenAI`/`LICENSE-Apache-2.0`), and checks after loading that device, inode,
size and modification time of all files are unchanged. This narrows, but does not
eliminate, the window between check and load against a process running with the
same user rights.
No automatic download, no download at launch, no fallback.

## Storage and lifecycle

- The new, explicitly opened playback view may show up to 100 characters per waiting text. The closed capsule stays free of text. Entries are addressed by ephemeral UUIDs; removing/reordering also replaces the prepared audio where applicable. Stop still clears everything and closes the view. Pause only holds the existing bounded RAM buffers and the active session, without writing files. Setup stores only `setupDismissed.v1`, never a supposedly passed permission result or progress; the step is derived from the current grants every time setup opens.
- A private packaging experiment may carry the existing model and the pinned runtime as program components in `Contents/Resources/Speech`. No runtime download and no fallback to the developer installation if this bundle folder exists but is damaged. Release builds never use the developer installation under `~/Library/Application Support/OpenScreenReader` and report “not installed” without the bundle folder; only Debug builds may use it. The `--dictation-smoke` check mode likewise exists only in Debug builds. Redistribution, the complete license chain and a test on a fresh Mac remain release gates.

- Reading speed is stored as a number under `speechPlaybackRate.v1`; the separate add shortcut is stored as key/modifiers under `enqueueShortcut.v1`. No audio, text or screen data is stored this way. Up to five waiting OCR texts of at most 8,000 characters/48,000 UTF-8 bytes each stay in RAM only. They are released after FIFO playback; a full stop, an error or quitting clears the list and discards late capture/OCR results. The list contains text, selection geometry and counters, never screenshots. The speech service may pre-generate audio in RAM only for the list's next entry; no pre-synthesis of the whole list. Exactly one worker stays loaded within the session and processes texts serially. The current and next transport buffers and the player are each limited to eight seconds of source audio (about 4.04 MiB combined), regardless of speed. This bounds the Swift PCM queues, not in-flight packets, transport encoding or the total memory of the audio engine and model worker. Stop/Esc/quit clear both transport buffers and the audio queue and terminate the warm worker. Without active/prepared work, keeping the worker warm ends after at most 30 s. No new file history, telemetry or runtime network connection.
- For the panel position, only `readingPanelEdge` (bottom/left/right) and `readingPanelOffset` (normalized offset 0–1) are stored locally in UserDefaults. No display ID, absolute screen coordinates or movement recordings. Dragging uses only normal mouse events of the app's own status surface and needs no additional permission; the position preview starts neither capture nor OCR nor speech.
- The chosen key combination (key and modifiers) is stored locally under `readingShortcut.v1` in UserDefaults. The shortcut field in Settings evaluates only the single key press while it is explicitly clicked and recording; it does not store keystrokes and contains no screen, OCR or audio content. While it records, the global shortcuts are briefly unregistered.
- Click instead of drag (since 2026-10-14): A single click in the selection overlay captures a bounded area of at most 1200 × 800 points around the pointer, within the clicked display. Only the paragraph under the pointer is read aloud; the rest of the recognized text is discarded immediately after local text recognition and is never shown, spoken, queued or stored. A click far from text reads nothing. This is the only exception to “only the marked region”: the click is the explicit marking.
- The selection hint only counts how often it has been shown, under `selectionHintCount.v1` (at most 5).
- Accepting the Supertonic 3 model terms (setup, or Settings › Read Aloud › Voice) stores only the SHA-256 of the bundled terms and license under `supertonicTermsAccepted.v1`. Withdrawing removes it. Reading aloud starts no capture, OCR or speech without a matching acceptance; dictation and the meeting transcript do not depend on it.
- For interface sounds, only on/off under `interfaceSoundsEnabled.v1` and the volume under `interfaceSoundsVolume.v1` are stored locally. The six fixed stereo cue sounds (open, completion, notice, some in two voicings, and since 2026-10-14 microphone on, hands-free locked and microphone off) are generated mathematically in memory at launch; they use no recording, no OCR text, no speech model and no network connection. Their reusable buffers contain only these fixed tones, no user content; no audio files are written. Since 2026-10-14 the Stop button is silent; its haptic feedback uses only the system API, without data.
- The flight window after capture draws only the geometry of the selection rectangle as a mint outline, never the image content; it is click-through and is closed after landing.
- The voice bars receive only an ephemeral level value, not an audio buffer. It is computed from 20 ms windows of the local PCM that is being played anyway and follows the playback position, not the arrival of new synthesis packets. Past level windows are discarded; the source audio queue of at most eight seconds bounds the look-ahead. Cancellation resets the queue and the display. No level history, no audio tap and no additional permission.
- Screenshots stay in process memory and are released after OCR.
- OCR text is kept only while the job and playback are running.
- Audio buffers are discarded after playback or cancellation.
- Bundled model and runtime files are permanent program components but contain no user-specific screen or speech content.
- Crash reports must not contain screenshots, OCR text or audio content.
- Diagnostic exports are opt-in and show a preview before writing.

## macOS permissions

- Screen Recording is required for region capture and must be justified in understandable terms.
- Accessibility or Input Monitoring is requested only if the chosen global hotkey or the cancellation control technically requires it.
- The app must not request broader permissions for convenience.
- Guided setup (2026-10-14): Each permission is requested only through a click on its own page. While Saywing waits for a permission, it checks its status (preflight, without a dialog) and reads from the system window list only the process ID, layer and frame of the System Settings windows, in order to place the hint next to them. Window titles or contents of other apps are not read, nothing is stored, and polling ends when the permission is granted, when the page changes or when setup closes.
- Screen capture excludes all of the app's own windows, with one exception: a visible window with the identifier `readableBySaywing`. Currently this is only the setup window with its own sample sentence, so the reading test works without private screen content. The status surface, selection overlay and hints remain excluded.
- Dictation at the cursor (2026-10-14): When a dictation starts, Saywing uses Accessibility to read only the screen position of the insertion point (`AXBoundsForRange` with length 0) or, as a fallback, the position and size of a small text field. No content is read for this, and the position is kept in RAM only until the next dictation.
- “Quit & Reopen” starts `/bin/sh` with the app's own process ID and app path; the shell waits for Saywing to exit and reopens it with `--resume-setup`. No network or file access.

## Verifiability

The current development path passes OCR text to the local Supertonic worker through an anonymous pipe, not as a command-line argument or file. PCM is played in memory. The worker runs under the shared worker profile (see “Worker sandbox”); Python runs without bytecode writes and without user-specific import paths. The installed models and dependencies are provided only in the explicit development step, never downloaded by the app. Playback and cancellation tests also check that the clipboard stays unchanged. This does not replace the still-pending verification of the fully bundled release artifact. Actual test results and limitations: [Supertonic integration](research/supertonic-integration.md); earlier Qwen measurements remain documented in the [runtime evaluation](research/swift-runtime-evaluation.md).

The repository should document how users can verify the privacy promises themselves:

1. offline functional test immediately after installing the complete release artifact;
2. network monitoring during OCR and TTS;
3. inspection of temporary files;
4. inspection of the clipboard;
5. reproducible or traceable release builds;
6. complete overview of third-party and model licenses.

## Worker sandbox — 2026-10-23

The dictation and speech workers start through `sandbox-exec` with the same profile
(`WorkerSandbox.profile` in the app, byte-identical as `Runtime/Dictation/worker.sb`
for scripts and integration checks). It is an allow-list profile (`deny default`)
based on Apple's `bsd.sb`:

- Reads only in the runtime folder, the model folder, the interpreter's prefix, the
  system libraries from `bsd.sb`/`system.sb` and the Metal shader caches; metadata
  (`stat`) stays readable everywhere, contents of the home folder do not.
- No network, no file writes except `/dev/null`, no `fork`, no `exec` other than the
  interpreter itself, no Apple Events.
- Mach services only from the base list of `system.sb` (including logging,
  read-only `cfprefsd`, `trustd`) plus `com.apple.MTLCompilerService` and the GPU
  clients `AGXDeviceUserClient`/`IOSurfaceRootUserClient` for MLX. Launch Services,
  the pasteboard (`com.apple.pasteboard.1`), TCC (`tccd`, `tccd.system`),
  WindowServer and `nsurlsessiond` are explicitly blocked.

Checked on 2026-10-23 with the installed app on Apple Silicon (macOS 26): Whisper
Turbo, Whisper Large v3 and Qwen3-ASR (installed model folder) transcribe the demos,
Supertonic reads aloud and cancels; network, writes, child processes and reads
outside the runtime/model fail.

Remaining limits: this is not a “ban on every form of exfiltration”. The worker can
still answer Saywing through its stdout pipe and talk to the permitted system
services. Apple marks `sandbox-exec` as deprecated and `bsd.sb` is a private system
interface; if macOS changes it, the worker no longer starts (it fails closed, not
open). The Intel path (whisper.cpp on the CPU, Supertonic on the CPU) has not yet
been tested under this profile on real Intel hardware. The workers inherit Saywing's
TCC responsibility (microphone, Accessibility, screen recording); they access none of
these sources themselves, and `tccd` is blocked. Detaching that responsibility would
only be possible through private API and is not used.

## Product communication

Acceptable statements include, for example:

- “No text or screenshots are uploaded.”
- “Works offline after installation.”
- “No account required.”
- “No telemetry in the official build.”

Absolute, unprovable statements such as “100 % secure” should not be used.

## Dictation (since 2026-10-13)

Microphone permission and recording are separate actions. The microphone does not start at app launch, while loading or when permission is granted. At most 60 s of PCM stay in RAM and are passed through anonymous pipes to the selected local dictation model. The worker runs under the shared worker profile (see “Worker sandbox”): no network, no file writes (except `/dev/null`), no child processes and no access to files outside the runtime and model. It loads only bundled or explicitly installed, hash-verified models; no cloud or developer-path fallback. Model choice, language and restore delay are the stored dictation settings. The visible last result/test field stays in RAM until discarded/cleared/quit, without history.

During dictation, the field content and cursor position, where available, are kept in RAM only for target validation. Password fields and unrecognized fields are rejected. All readable clipboard formats up to 16 MiB are backed up before pasting; data that cannot be fully backed up prevents automatic pasting. A new copy takes precedence. Promised files (file promises) are rejected from the type list alone, before any app has to produce data. Cancellation/normal app exit immediately restores a clipboard that is still owned by the app; a hard crash during the short paste window can prevent this. The pasted text carries the nspasteboard.org markers `ConcealedType`, `TransientType` and `AutoGeneratedType`; the text and the restore are written with `currentHostOnly` and do not reach the Universal Clipboard of other devices. Clipboard managers that ignore these markers can still see the text.

**Password managers (since 2026-10-23):** If the backed-up clipboard carries one of these three markers, for example a password copied from a password manager, it is cleared after pasting instead of restored — again only while the pasted text still belongs to Saywing; a newer copy still takes precedence. Writing it back would look like a new copy to the password manager and prevent its timed clearing; the password would stay on the clipboard indefinitely. The status line tells the user that the clipboard was cleared instead of restored. The manual “Copy Result” action keeps the explicitly requested copy.

Microphone and Accessibility are requested only through a setup button; no live recording through demos or self-tests. Reading aloud stops before a recording; starting reading aloud discards active dictation. Esc, discard, system sleep/session switch and app exit clean up active jobs and invalidate late results. [Details and evidence](research/qwen-dictation-runtime.md).

## Fn dictation control — 2026-10-13

Dictation supports holding Fn, double-pressing Fn and Fn+Space. With Accessibility permission, an event tap observes Fn/modifier transitions and key-down/key-up events so that it can take over Fn+Space and pass other Fn combinations through. It reads no characters, stores no typed text and transmits no key data; its state consists only of Fn gestures, timestamps and the associated Space key. Other key input is passed through unchanged. The tap runs while Fn control is available, is removed on sleep/session switch/quit and cancels an active Fn recording if observation is lost. Unlike the earlier Escape observation, it therefore also persists between recordings. Permissions are not requested automatically. ⌥⇧Space remains usable without Fn observation.

## Dictation model selection — 2026-10-13

Qwen3-ASR, Whisper Turbo and Whisper Large v3 use the same offline sandbox and the existing
ephemeral audio/clipboard pipeline. `dictationModel.v1` stores only the choice of
model. Loading and switching do not start the microphone. Missing or damaged
model files produce a visible error; the app does not download anything automatically from
the network and does not switch automatically to another provider. Models that are not
bundled are installed only after explicit confirmation (see
“Network access”). Switching invalidates
callbacks of the old worker. Source, revision, checksums and license of [Whisper
Turbo](research/whisper-turbo-dictation.md) and [Whisper Large
v3](research/whisper-large-v3-dictation.md).

## Default model and custom vocabulary — 2026-10-14

Whisper Turbo is the default model for new installations; a stored
choice is kept. Under Settings → Dictation, a custom vocabulary
(at most 50 terms of up to 60 characters each) can be entered. It is stored only locally under
`dictationVocabulary.v1`, contains only the terms the user entered
and is passed to the offline worker through the anonymous pipe with every dictation.
Neither the worker nor the app logs or transmits it.
Clearing the field removes the entry. Dictated texts are not
stored as a result and are not added to the vocabulary automatically.

### Setup preferences (2026-10-14)

Setup additionally saves the dictation shortcut, optional Fn setting and the model identifier of an explicitly requested installation. It never saves microphone audio, screen content or recognized text. Restoring an interrupted installation does not resume network requests automatically: another explicit download confirmation is required. Capturing a shortcut suspends activation keys, including Fn, so entering a combination cannot start recording. Downloads continue to use only the approved pinned manifests and verify every installed file before activation.

## Meeting transcript (since 2026-10-15)

[ADR 0006](decisions/0006-local-meeting-transcript.md). A narrow exception to “no recording of other content”, only for an explicitly started transcript.

- **Start only after a consent step:**
  - Before every start, a window explains what will be recorded and offers a copyable notice for the meeting chat.
  - The notice is copied only on click.
  - No automatic start, no meeting detection, no posting into other apps.
- **Two sources:**
  - the microphone (“Me”);
  - the system audio of all other apps (“Others”) through a private Core Audio process tap that excludes Saywing itself. Saywing's own reading aloud therefore does not end up in the “Others” track.
  - macOS asks for the system audio permission on first start (`NSAudioCaptureUsageDescription`); Saywing uses no private TCC interface.
- **Recognition:**
  - Apple's on-device `SpeechTranscriber` (macOS 26 or later), only for already installed languages.
  - Saywing does not request speech models from the network and has no network access of its own in this path.
  - The dictation worker is not used.
- **No files, no history:**
  - Audio exists only in short RAM buffers, for recognition and the echo gate (at most about 2 s per track at 8 kHz), and is continuously discarded.
  - No audio on disk.
  - The transcript stays only in RAM until it is discarded, replaced by a new transcript or the app quits.
  - Writing only through “Copy” (explicit click) or “Save…” (save dialog; PDF, Markdown or plain text).
  - No new settings keys.
- **End:**
  - Stop, the 2-hour limit (notice 5 min before), 10 min of silence on both tracks, system sleep, session switch and app exit end the recording. The transcript is kept until discarded.
  - Esc, reading aloud and dictation do not end it.
  - Late recognition results after the end are discarded.
- **Indicator:** During recording, the menu bar icon carries a ring, and the menu shows “Meeting Transcript · Running”.
- **Legal:** Recording other people requires their consent (e.g. Section 201 of the German Criminal Code (StGB), GDPR/DSGVO). Saywing reminds users of this but does not verify it. A legal review remains a release gate.

### Voices and PDF — project decision 2026-10-18

[ADR 0008](decisions/0008-meeting-speakers-and-pdf.md).

- **Telling voices apart:**
  - Only in builds that carry the voice model. Since 2026-11-07 that is Nemotron 3 Diarization (NVIDIA, CoreML conversion by Fluid Inference, OpenMDW-1.1); whether public builds carry it awaits the maintainer's license decision (ADR 0008). In a build without it, all other participants stay "Others" and no voice analysis runs.
  - Only the "Others" track, live on the device. The model is a CoreML model that runs inside the Saywing app process, on the Neural Engine where the Mac has one (otherwise GPU and CPU), not in the sandboxed speech or dictation worker.
  - No download, no network connection. FluidAudio's download code is linked into the app but is never called, and its offline switch is on.
  - The model starts loading when the consent step appears, so that it is ready when the transcript starts. Nothing is analysed before you start the transcript, and closing the window or discarding frees the model again.
  - Like the recognizer's input, the audio is discarded continuously. Until the model is ready, at most the last 30 s of the others' audio waits in RAM (about 6 MB) and is then analysed and discarded. If the analysis falls behind, audio is dropped instead of collected (at most about 5 s in RAM).
  - The model keeps a fixed-size state about the voices it has heard (a speaker cache and the latest frames) only in RAM, with the transcript.
  - The first time the model loads, CoreML keeps a compiled form of it (about 1 MB for Nemotron 3) in `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`, one per model location and macOS build. It is derived only from the model and contains no audio or anything about voices. The session itself adds nothing to it. Deleting the folder is safe; the next load takes a few seconds longer.
- **No voice profiles:**
  - Saywing stores no voice characteristics (no embeddings, no speaker cache) and does not recognize anyone across transcripts.
  - The model state ends with the transcript: the model is freed when the transcript ends, is discarded or fails.
  - Only the user assigns names, by hand. Like merges and turns moved to another voice or a new person, they live only in RAM with the transcript and end with it. A correction stores only a time range and a voice number, nothing about the voice itself.
- **PDF:**
  - Save offers PDF, Markdown and plain text, still only through the save dialog.
  - The PDF's document information holds only the title and "Saywing": no author, device or user name.
- **Legal:** Voices are biometric data (GDPR Art. 9) as soon as they are used to identify someone. Saywing identifies no one and keeps nothing. This belongs in the existing legal review before a public release.
