# Proposed architecture

> This architecture is a reasoned starting hypothesis. The process boundaries and packaging strategy will be validated through technical spikes before the complete MVP is built.

Current development status: Following the project's listening decision of 2026-09-05, Supertonic 3 is the default model, initially with M1. A local Python/ONNX process is connected to OCR and AVAudioEngine through the same `SpeechReading` interface; see [Supertonic integration](research/supertonic-integration.md). The earlier Swift/MLX Qwen spike is kept as a comparison, but the app neither starts it nor uses it as a fallback. This does not yet determine the portable production runtime or the release packaging.

## System overview

### Everyday controls update — 2026-09-09

`SpeechReading.setPaused` pauses the native player without discarding scheduled buffers. `SpeechAudioPlayer` suppresses both prebuffer auto-start and short-tail start while paused; its bounded producer/drain waits remain cancellable. `AppModel.isPaused` is orthogonal to the core speaking phase, so adding regions remains available. The app-level speech watchdog is suspended during a user pause; worker packet watchdogs still cover actual inference, excluding channel backpressure. Resume restores the watchdog; Stop/skip clear pause state.

Queue rows have stable UUIDs. Removal/reordering refreshes only the next prepared text; play-now moves the selected row to the head and uses the existing generation-protected skip/handoff. A transient `NSPopover` hosts `PlaybackControlsView` only after a capsule-button click. Its previews are presentation-only and remain session-local; the closed capsule gets only status/count/level and a callback. `SetupView` offers explicit permission requests and read-only preflight, not a fabricated end-to-end result. Since 2026-10-14 it is a paged flow: `SetupPlan` derives the next step from live grants only, `ReadingTrial` maps the real pipeline status to the in-window reading test (success only after speech played), and `SetupFlowController` owns cancellable grant polling, a stale-protected auto-advance and the `SystemSettingsGuide`/`MenuBarPointer` panels. `AppModel` owns the window and flow and tears both down on close. `ScreenCaptureService` excepts only visible own windows with the `readableBySaywing` identifier from its own-app exclusion. An injected `missingReadingPermission` check opens setup before a selection that could only fail. After a failure, `AppModel.errorHelp` (`retry`, `shortcut`, `allow(permission)`) drives `ReadingErrorView` in the capsule's popover instead of opening setup. `DictationCapsulePlacement` anchors the dictation capsule below `InsertionTarget.caretRect()` and otherwise uses the reading control's `ReadingPanelPlacement`. `DictationController` takes the shared `InterfaceSoundPlaying` and derives result cues from the capsule presentation; the microphone cues (`listening`, `handsFree`, `captured`) are played at the recording's own events, the closing one only after `DictationRecording.finish()`. `DictationRecording` abstracts `MicrophoneRecorder` so tests can drive a recording without a microphone. `MenuBarIcon` composes cached template glyphs from `AppModel.menuBarIndicator`.

`SpeechTextNormalizer` repairs explicit soft hyphens and non-breaking spaces without rewriting ordinary hyphens, numbers or codes. The Python segmenter preserves abbreviation/initial/ordinal context, honors explicit paragraph boundaries and retains the existing 240-character cap. This is deterministic segmentation, not an LLM text rewrite or a proof of audible linguistic fidelity.

`LocalSpeechService.installedConfiguration` selects bundled Speech resources when present, otherwise the explicit development installation. Bundled Python is under `SupertonicRuntime/python/bin/python3`; its standard library and pinned package closure are private build resources. The offline `package-development-app.rb` spike verifies model/installed-runtime hashes before copying, excludes unrelated base-interpreter packages and build-time pkgconfig links, checks symlink containment, ad-hoc signs nested native code and the app, and retains licenses. It is intentionally not a release/signing/notarization pipeline.

```text
GlobalHotkeyManager
        │
        ▼
SelectionOverlay ──► ScreenCaptureService
                            │
                            ▼
                      VisionOCRService
                            │
                            ▼
                 TextNormalizer / Segmenter
                            │
                            ▼
                         TTSService
                      ┌─────┴─────┐
                      ▼           ▼
               QwenProvider  SupertonicProvider
                      │
                      ▼
                 AudioPlayback
```

## Native macOS app

Planned stack:

- SwiftUI for settings and the menu bar interface;
- AppKit for global windows, the selection overlay and event handling;
- ScreenCaptureKit or CoreGraphics for region capture;
- Vision with `VNRecognizeTextRequest` for local OCR;
- AVFoundation for audio buffers and playback.

### Proposed modules

- `AppShell`: lifecycle, menu bar and settings;
- `GlobalHotkeyManager`: registers read/add and prevents conflicts; full stop stays with Esc and explicit Stop controls;
- `SelectionOverlay`: multi-monitor selection and cancellation;
- `ScreenCaptureService`: captures only the selected rectangle;
- `VisionOCRService`: OCR, language and reading order;
- `TextPipeline`: normalization, segmentation and fidelity mode;
- `TTSService`: model-independent job and cancellation control;
- `AudioPlaybackController`: buffered playback with immediate stop;
- `ModelManager`: manifest and hash verification of the bundled model, version and storage policy;
- `PrivacyAudit`: central place for optional network and file system events.

### Implemented status panel

Update 2026-09-22: On hover, two native `ReadingInlineButton` targets replace the wave inside the 136 pt capsule: Pause/Resume and Options. `controlsBlend` cross-fades without a layout change. Custom responder mouse events distinguish a click from a drag starting at 5 pt, without a blocking tracking loop. A weakly referenced popover keeps the buttons visible; opening from the menu/Accessibility shows the anchor synchronously. `present`, retract and hide protect against stale clicks; on hide, the popover delegate is detached before closing so that it does not restart the drawing tick. The menu item and Accessibility actions remain reachable without hover. `dockEdge` determines the inward-facing popover side; side glyphs stay upright. The pipeline, providers, audio and storage do not change. This supersedes the earlier Esc-layer details below.

`ReadingPanelPlacement` computes the position relative to the `visibleFrame` of the selected display. At the bottom, the drawing surface stays 300 × 92 pt; at the sides it is 92 × 300 pt: layout coordinates are mapped, while text/symbols/button are not rotated. The controller handles drag callbacks from the decorative status surface, separately from the Stop button; from 5 pt on, the window follows directly, and on release the nearest allowed edge is stored together with the normalized offset. The 220 ms snap task is cancellable and generation-protected; Reduce Motion positions immediately. Display changes re-clamp the geometry. The Settings preview is an explicit, purely presentational `positioning` state, not a simulated pipeline. A new job clears it through the same `hide()` path.

The app shell injects `ReadingPanelController` into `AppModel` through `ReadingStatusPresenting`. The controller receives a closed status value, the selected display ID, a Stop callback limited to the current pipeline generation and, during playback, an ephemeral scalar level. Screenshot, OCR text, audio and technical error payloads do not cross this boundary.

The reading control (`ReadingControlView`) is a layer-based native `NSView` on a fixed 300 × 92 pt drawing surface; the visible capsule is 44 pt high and between 44 pt (dot) and about 250 pt (hint text) wide, and the rest is room for the drawn shadow. The capsule is a container with an `NSVisualEffectView` (material `hudWindow`, behind the window), a very dark tint, depth and sheen gradients, rim light, a radial glow, nine `CAShapeLayer` bars with their own glow, a travelling light for recognition, a symbol layer, a bloom ring and two secondary buttons that fade in on hover. An `NSTextField` shows text only briefly for hints; the Stop button is a real 44 pt `NSButton`. For the first visible state, `ReadingStatusPresenting.show` additionally receives the selection rectangle in screen points; `SelectionFlightWindow` (click-through, only on the selected display) lets a mint ghost of the frame fall into the landing point via a Core Animation path morph. Only then does the panel appear, and at the same time the controller plays the open sound; `hide()` cancels the flight immediately. State changes are also posted as VoiceOver announcements. There is no Auto Layout and no SwiftUI host; all frames are set by hand per frame, so no constraint loop can arise. A `CADisplayLink` from `NSView.displayLink(target:selector:)` drives a hand-integrated spring (opening with overshoot, closing critically damped) and the state cross-fades; its target is a weakly referencing proxy so the view can be released. In resting end states the link pauses. When pressed, the Stop button plays a tap sound through the controller and triggers `NSHapticFeedbackManager`; this path is decoupled from the pipeline and is not cut off by the cancellation cleanup. `PlaybackEnvelope` computes 20 ms level windows from the existing PCM outside the audio thread. `AppModel` queries the level for the rendered sample position every 33 ms; job protection and resource teardown end this tick. Providers without level support return the default value zero through `SpeechReading`.

`AppModel` hides the panel before selection/capture and publishes visible work states only after capture. The existing ScreenCaptureKit filter additionally excludes the app itself. The `NSPanel` is non-activating, never becomes key/main window and stays visible when switching to other apps. Its own generations and cancelled timers prevent a stale button or an old hide from affecting a new job. Display changes reposition it, or hide it if its display is missing.

## TTS process

### Speed and text queue

`SpeechReading.playbackRate` is a provider-independent property that can be changed live. `SpeechAudioPlayer` connects player → `AVAudioUnitTimePitch` → mixer; the rate is clamped to 0.75–2, pitch stays at 0 cents. Model parameters and weights remain unchanged. The prebuffer corresponds to at least one second at the current start speed. Intel builds increase the start lead during fast playback up to three playback seconds at 2× (six source seconds) so that the next sentence synthesis does not drain the buffer prematurely; ARM keeps its previous start behavior. Short texts below this threshold are played immediately when synthesis completes. The fixed capacity is eight seconds of source PCM (44,100 Hz mono Float32: about 1.35 MiB), so that at 2× up to four seconds of lead remain for the next sentence synthesis. When slowing down live, the limit does not shrink below already scheduled buffers. [Apple API](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch).

`AppModel` manages at most five additional OCR results in RAM. Since the project decision of 2026-09-09, the primary Carbon hotkey leads through `enqueuePrimaryShortcut` to the existing `addToQueue` path: when idle, a new selection; during speech/preparation, an additional selection/capture/OCR. If a selection/capture/OCR is already running or the queue is full, the session continues and a message explains the state. A second Carbon key combination is kept only as an optional compatible alias. The explicit menu Stop still uses `enqueueReadRequest` and is separate from the hotkey. The existing selection interface is reused; the status panel stays hidden during selection/capture and returns afterwards without the open sound. A UUID discards stale additional results; a separate timeout bounds capture/OCR. An empty, too long or failed addition is rejected with a status message, without stopping current speech or already waiting texts.

The core coordinator still owns only the current speech job. On the FIFO switch, this job is completed, a new generation is created and the already recognized result is started through the same synthesis/playback logic. The Escape monitor's session generation stays stable across this switch but is invalidated on a full stop/new manual start. If only a still-running additional selection/OCR remains, the old context remains as a cancellable owner; `waiting` is a presentation state, not a new core phase. “Next Text” ends only the current speech job and starts the next ready entry; a full stop and errors clean up both task paths and the entire text list. No additional speech worker is started in advance.

Since 2026-09-09 the queue uses a single Python/ONNX process per session. `SpeechReading.prepareNext` prepares at most one successor, `stopCurrent` keeps it during a normal transition/skip, and `stop` discards all jobs and terminates the process. Other providers may continue to work without preparation through the default implementations. `AppModel` updates the preparation only after the current playback has started, or when adding during speech; on dequeue, the existing successor is not replaced before it is taken over.

`SpeechWorkerSession` runs exactly one synthesis job at a time. The new explicit `--session` protocol tags ready/audio/end with version 2 and the UUID of the text job; mismatching IDs/versions are rejected. The model and voice are loaded/verified once, and the random seed is reset per text. The legacy single job without the flag stays compatible with earlier development apps. After the current text's end packet, the same worker may synthesize the successor while the player plays the remaining buffers. There is no parallel second model and no pre-synthesis of the whole list.

Per job, `SpeechPreparationBuffer` limits the RAM packets to eight source seconds and blocks the producer at full capacity. The current transport buffer, the next transport buffer and the player together amount to at most 24 source seconds of scheduled/buffered PCM (about 4.04 MiB), plus bounded in-flight packets, transport encoding and engine/model memory. Both waiting sides are woken on cancellation. A prepared handoff pauses for a cancellable 120 ms. Stop cleans up both jobs, readers, timers, audio and the process. If a current passage that has not finished synthesizing is skipped, its worker is terminated hard and the waiting successor is started with a new worker. Preparation that is already running after the current synthesis has completed is kept when skipping.

The app ends the session on a full stop, an error or an empty queue. A separate generation-protected 30 s idle timer bounds keeping the worker warm without an active/prepared job, for example while waiting for an additional selection. Packet watchdogs (90 s until audio, then 30 s without a worker packet) do not run during regular buffer backpressure. Before every process start and after every asynchronous transition, cancellation and job identity are checked.

A worker failure ends that worker with one fixed error code and never with text or a path: `load_failed`, `out_of_memory`, `synthesis_failed`, `too_long` or `invalid_request`. A packet without a code, from an older runtime, counts as generic. Losing a worker before its first `ready` is a load failure, afterwards it is a crash. A crash, a synthesis failure, a generic error or a packet timeout retries that passage exactly once with a new worker on new pipes, for the first text as well as for queued and prepared ones. The retry continues after the PCM already delivered, because the per-text seed reproduces the same audio. A load failure, missing memory or a refused request is not retried, and Stop, `Esc` or a skip never count as failures. If the retry fails too, the error is shown. A prepared passage reports it at its handoff, after the current text has finished. The waiting list is then cleared and the message says so.

Text and PCM travel over anonymous pipes; playback happens in the app process. The worker may neither open network connections nor write files (except `/dev/null`). Python runs isolated and without bytecode writes. `scripts/update-supertonic-worker.rb` explicitly updates only the project's own worker together with its receipt hash, refuses local deviations and downloads neither models nor packages.

Keeping the worker warm beyond completed sessions remains a comparison option that is not yet implemented. A possible variant would have the following properties:

- the app starts the worker in a controlled way;
- the model is loaded once and kept warm for a limited time;
- communication through a local interface that is not bound externally;
- audio is transferred in blocks;
- every job gets an ID and a cancellation signal;
- process exit deletes temporary state.

Before the MVP, two variants must be compared:

1. a portable bundled Python/ONNX worker;
2. native ONNX integration; the earlier MLX path remains a comparison.

Evaluation criteria: startup time, signing/notarization, package size, fault tolerance, energy use, license chain and maintainability.

## Model delivery in the official MVP

The default model should be part of the signed release artifact, so that no separate model selection or runtime download step is needed after installing the app. Before this strategy becomes binding, a packaging spike must show that the app, worker, runtime and model can be signed and notarized together and started offline on a clean Mac.

- Model weights are not checked into Git.
- Release builds use an allowlist-based manifest with immutable revisions and SHA-256 hashes.
- Model, tokenizer, conversion, runtime, voices and transitive dependencies require a documented license approval.
- Local inference needs no network. Project decisions allow the explicitly confirmed optional dictation models and, since 2026-10-14, disableable Sparkle update checks with installation on user action; see Privacy and the [release procedure](release-and-updates.md).
- The provider abstraction is kept so that later platforms and local models are not coupled to an MLX artifact.

## Provider abstraction

`TTSProvider` should support at least:

- `load()` and `unload()`;
- querying capabilities and languages;
- starting streaming synthesis;
- cancelling a job;
- reporting model and license metadata;
- checking health status.

Primary:

- Supertonic 3, selected after a direct listening comparison (project decision 2026-09-05); M1, eight steps, normal synthesis speed. Sentence-by-sentence synthesis, bounded audio packets and eight seconds of source PCM in the playback buffer; live speed 0.75–2×.

Comparison, not used automatically:

- Qwen3-TTS 0.6B 4-bit Swift/MLX. The evaluated voices were judged too inconsistent.

The Supertonic OpenRAIL-M terms, the announced end of official support and the complete Python/ONNX license and packaging chain must be reviewed before distribution.

Not for the first path:

- Chatterbox because of startup latency and memory requirements;
- Thorsten/Piper until the runtime and phonemizer license chain are settled in practice.

## Concurrency and cancellation

- A new speech job gets a generation ID; a repeated hotkey press to add text does not revoke the generation that is still speaking.
- Results of older generations are discarded.
- `Esc` ends the overlay, OCR task, TTS task, audio queue and active worker job.
- Only the current job may send audio buffers to playback.
- Errors of a TTS provider must not terminate the menu bar app.

## Privacy boundary

The default path must not persistently store screenshots, OCR text or generated audio. Diagnostic exports are opt-in, show their exact content before writing and remove screen data by default.

## Open technical spikes

1. Minimal multi-monitor selection frame with ScreenCaptureKit.
2. OCR reading order for running text and two columns.
3. Native Swift/MLX integration: first audio blocks and cancellation passed locally; warm start, memory requirements and long runs still open.
4. Code signing and notarization of a worker bundle.
5. Demonstrate that the fully installed release app makes no network access.
6. Determine the energy and RAM policy for keeping the model warm.

## Local dictation — 2026-10-13

`DictationController` is integrated alongside the reading coordinator, with its own Swift 6 MainActor state machine, microphone RAM buffer, target validation, short-lived clipboard transaction and a `DictationTranscribing` provider. `DictationWorker` runs the explicitly selected ASR model over isolated anonymous pipes; Supertonic stays TTS. `AppModel` serializes the reading→dictation switch, stops speech playback before the microphone starts and synchronously discards dictation before reading starts. The process session and recording ID prevent late results. During a cold start, audio is kept in RAM for at most 60 s; inference and model start have time limits. The worker is prepared automatically at app launch and stays available while idle and while reading aloud. Only active dictation inference is ended when switching to reading aloud; the next dictation start reloads automatically if needed. Sleep, an inactive user session and quitting unload the worker. After wake and with an active session, it is prepared again automatically. Repeated load requests are idempotent; quitting blocks late warm starts. This preparation does not start the microphone. The bundle contains the pinned ASR runtime under `Contents/Resources/Dictation`; missing resources lead to a visible error message. [Manifest, protocol, packaging and limitations](research/qwen-dictation-runtime.md).

## Dictation model selection — 2026-10-13

By project decision, Qwen3-ASR and Whisper Turbo are available as explicit local
models to choose from. The choice is stored under `dictationModel.v1` and
restored at launch and after sleep. Switching is blocked during a
dictation; when idle, the previous worker is terminated and its late
callbacks are discarded. The selected model loads automatically without starting the microphone.
Missing or damaged models produce an error, not an automatic
fallback or download. Both use the existing offline sandbox and the same
ephemeral audio/clipboard pipeline. Source, revision, size, checksum and license:
[Whisper Turbo](research/whisper-turbo-dictation.md).

Since 2026-10-14, Whisper Large v3 (8-bit, `whisper-large-v3`) is additionally available
for selection. It uses the same mlx-whisper runtime as Whisper Turbo, is designed to be more
accurate but slower; only the selected model is loaded. [Source, revision,
checksum and license](research/whisper-large-v3-dictation.md).

### Installing models on demand — 2026-10-14

By default, builds bundle only Whisper Turbo; it is the default model. Qwen3-ASR
and Whisper Large v3 appear in the model selection as “Install … (size)”.
`DictationModelStore` knows bundled (`Contents/Resources/Dictation/<folder>`)
and installed models (`~/Library/Application Support/Saywing/DictationModels/<folder>`).
After confirmation, `URLSessionModelFetcher` downloads the files pinned in the bundled manifest
(ephemeral session, HTTPS to Hugging Face only, including redirects) into
a staging folder. The size and SHA-256 of every file are checked, and only then is
the folder moved atomically into place. Cancellation and errors remove the
staging folder; a new installation attempt discards results of a cancelled one.
After a successful installation, the model is selected and loaded.
`DictationWorker` then passes `--model-root`; `worker.py` still reads the manifest
from the bundle and re-checks the hashes on load. A stored selection
of a model that is not installed is kept, but Whisper Turbo is started.
`bundle-dictation-runtime.py` bundles Qwen only with `--with-qwen` and Large v3 only with
`--whisper-large-model`.

## Default model and vocabulary — 2026-10-14

By project decision, Whisper Turbo is the default model when
no choice has been stored yet; Qwen3-ASR remains selectable. Every request to the worker
optionally carries `vocabulary` (≤ 50 terms, each ≤ 60 characters, without control characters;
otherwise error `processing_failed`). Whisper receives the terms as `initial_prompt`
(“A, B, C.”), truncated to the prompt's token budget, and Qwen3-ASR as `hotwords`.
If recognition produces a repetition loop or only the list of terms, the same
worker decodes the same recording once more without the vocabulary. This is not a switch of
model or provider.

### Setup configuration (2026-10-14)

`SetupStep` adds model and shortcut stages for each activity while retaining existing raw checkpoint values. `DictationModelSelection` and `ActivationShortcutsView` are shared by setup and settings. `dictationShortcut.v1` stores the validated combination; `dictationFnEnabled.v1` controls Fn gestures. Registration succeeds before saving. `AppModel` checks collisions across reading, enqueue and dictation and suspends all activation paths while recording a key.

`dictationInstallIntent.v1` persists only the requested model identifier. Relaunch restores an interrupted choice without network activity. Installation completion is checked against a selection generation so a later user choice wins. Verification has its own observable phase; cancellation propagates to file hashing. Completed atomic installs are recovered on relaunch before clearing the intent. Explicit retry uses the existing pinned manifest and installer. No new model source or runtime network endpoint is introduced.

## Release and update preparation — 2026-10-14

`AppUpdateController` encapsulates Sparkle 2.10.0, is independent of the local workers and starts only with a valid HTTPS feed/key configuration. `UpdateRelaunchGate` holds an installation continuation during active work and invalidates it on cancellation/app exit. Model installations also block. Signed feeds and archives are verified before extraction; system profiles and automatic installation are turned off. `scripts/release.py` first checks resources, signs code from the inside out, only then updates binary hashes, optionally notarizes the app and DMG and finally generates the feed. The GitHub workflow checks main/PRs; public delivery waits for hosting and the release gates. Details: [Release and updates](release-and-updates.md).

## Local meeting transcript — 2026-10-15

[ADR 0006](decisions/0006-local-meeting-transcript.md). A separate module `OpenScreenReaderApp/Meeting`, independent of the reading pipeline and the dictation worker:

| Component | Responsibility |
|---|---|
| `MeetingMicrophoneSource` | Its own `AVAudioEngine` on the default microphone (“Me”), mono float with host timestamp |
| `SystemAudioTapSource` | Private Core Audio process tap (`CATapDescription(monoGlobalTapButExcludeProcesses:)` without Saywing, macOS 14.2 and later) in a private aggregate device containing only the tap, as in Apple's sample (“Others”) |
| `MeetingAudioRouter` | Places both sources on a shared timeline (`MeetingTimeline`), passes them to recognition, keeps level/silence/signal per track and resamples to 8 kHz for the echo gate on its own queue |
| `AppleMeetingRecognizer` | One `SpeechAnalyzer` with `SpeechTranscriber` (`.volatileResults`, `.fastResults`, `.audioTimeRange`) per track, macOS 26 only and installed languages only (`AssetInventory.reserve`, no download). Input is stamped in whole samples of the analyzer rate (`MeetingFrameTimeline`) because the analyzer rejects any overlap. Stop finalizes with a deadline and cancels an analyzer without input (otherwise it hangs) |
| `EchoGate` | Every 0.5 s, FFT cross-correlation (Accelerate) of the last ~2 s of both tracks; a stable delay in 5 of 8 analyses or a known room delay → echo spans only where “Others” had sound, shifted by the delay plus 0.5 s of reverberation |
| `MeetingTranscript` | Volatile/final per track, conversation turns in chronological order. “Me” loses words whose time falls within an echo span, and sequences of ≥ 3 words that “Others” said at the same time. Markdown export |
| `MeetingController` | Consent → start (recognition first, then sources) → live → stop → done/discard; `GenerationGate` against late results; limits of 2 h (notice after 1 h 55 min), 10 min of silence, sleep/session switch; copy/save only on click |
| `MeetingView` | SwiftUI window: consent, conversation view with levels, notice when system audio is missing, completion actions |

`AppModel` holds the controller only for display: the menu bar ring takes precedence over all other states, and updates wait. Reading aloud, Esc and dictation do not interfere. No part of the module writes files except through the explicit save dialog, and none opens a network connection. The one exception is outside its control: in a build with the voice model, CoreML caches a compiled form of that model in the app's caches folder when it loads.

### Voices and PDF export — 2026-10-18

[ADR 0008](decisions/0008-meeting-speakers-and-pdf.md). Adds to the module:

| Component | Responsibility |
|---|---|
| `MeetingVoiceDiarizing` | Interface for a diarizer on the "Others" track. One queue, times in seconds of the audio fed in; each call returns only new spans |
| `MeetingVoiceTracker` | Feeds "Others" into the diarizer on its own queue and places the spans on the meeting timeline through anchors, also across gaps. If the diarizer falls more than 5 s behind, audio is dropped instead of queued. Stop drains the look-ahead, Discard silences late results, and an error ends only the voice separation |
| `MeetingTranscript` (voices) | Each word of "Others" goes to the voice that spoke most during it (otherwise to the nearest one within 0.6 s); a change of voice splits the segment. Numbers follow the order of first words and stay stable across merges. Names and merges live only in RAM |
| `MeetingVoiceModel` | Reads `nemotron-3-manifest.json` in `Contents/Resources/Diarization`: the preset it names must match FluidAudio's and every file it lists must be there. Without a model, "Others" stays one person |
| `MeetingVoicePreload` | Created when the consent step appears; loads the model in a background task (about 6 s the first time CoreML sees it, under 0.1 s afterwards). Until it is ready, up to 30 s of the others' audio waits (oldest dropped first) and is fed in first, so early words get their voices; Stop waits at most 30 s for a model still loading. Releasing it cancels the load and frees a loaded or late model; the controller does so when the window closes before a transcript, on Discard and on quit |
| `NemotronMeetingDiarizer` | The only file importing FluidAudio (exact 0.18.2, `traits = (Diarizer)`). Runs `Nemotron3Diarizer` (Nemotron 3 Diarization, up to 8 voices, 10 ms frames) with CoreML compute units `.all` in the app process, on the Neural Engine where there is one. Loads only from the bundle, resamples to 16 kHz through one long-lived converter, keeps no frames or segments (`MeetingVoiceFrames`), and reports a voice still speaking once a second. Released as soon as the tracker finishes, is cancelled or fails |
| `MeetingExport` | Visible turns with their labels; Markdown (also used by Copy), plain text and PDF. The PDF is set with Core Text on numbered A4 pages and carries a structure tree (heading, paragraphs) for screen readers. Document info holds only the title and "Saywing" |
| `MeetingView` | A color mark plus name or number per voice; the label opens "Rename…" and "Same Person As". The save panel has a format menu, PDF first |

Separation quality is measured with `scripts/diarization-eval`, a local harness outside CI that compiles the adapter against the pinned FluidAudio and scores it on speaker-split public-domain conversations. On its frozen test split (2026-11-07, Nemotron 3 `fast`): 94.9 % of attributed time correct over all runs and the exact number of voices in 94 % (LS-EEND: 84.2 % and 57 %); 98.5 % for two or three readers without similar voices, 94.9 % for four or five, 95.8 % with a similar pair, 94.2 % with turns of 1.5-4 s, 88.1 % for system voices (ADR 0008).

The adapter is in every build. The model is only in builds made with `scripts/release.py --diarization-model`; the release workflow passes that when the repository variable `SAYWING_BUNDLE_DIARIZATION_MODEL` is exactly `true`, and a public build with the model also needs the maintainer's license decision for exactly that model, which is pending for Nemotron 3 (ADR 0008). Without the model, `makeVoiceDiarizer` returns no diarizer and the others stay "Others"; PDF export and echo handling work either way.
