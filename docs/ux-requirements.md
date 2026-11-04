# UX requirements

## Primary flow

Update 2026-09-09: Pause/Resume, an editable queue and setup were approved. The capsule stays free of text; its small ···/+N button opens a native controls view with Pause/Resume, speed, Next and the waiting texts. Only this explicit click shows at most 100 characters per entry. Remove, Move Up/Down and Read Now use stable entry IDs, not stale indexes. Esc/Stop also ends a pause. Earlier statements “no preview”/“pause outside” apply to the closed capsule, not to this new explicit view.

Setup appears the first time the menu bar item is shown and is reachable later through “Set Up & Test…”. Permissions are requested only on click. Since 2026-10-14 (project decision), it is a guided flow with one decision per page; details under “Guided setup”. A granted permission is labelled only “Allowed”; “It works” appears only after the real reading test has played speech. Errors offer direct access to setup and to the specific error message through ?.

1. The user presses a freely configurable global hotkey.
2. An unobtrusive transparent selection overlay appears over all screens.
3. The user drags out a rectangular region.
4. On release, the overlay disappears immediately.
5. The app captures only the selected region.
6. Apple Vision recognizes the text locally, initially focused on German and English.
7. The text is normalized and split into short speakable segments.
8. Local TTS starts automatically; no additional click is necessary.
9. Pressing the hotkey again during speech/preparation opens another region selection for the queue. `Esc` or an explicit Stop button immediately stops OCR, synthesis, the queue and audio playback. During a selection/capture/OCR that is already running, further key presses create neither duplicates nor a cancellation.

The official MVP includes a verified default model. The user does not have to select or separately download a model before reading aloud for the first time. Model name, version, source, installed size and license remain viewable in Settings.

## Interaction requirements

- The app lives primarily in the menu bar and does not open a permanent main window.
- The hotkey is configurable and must not override common system shortcuts without asking.
- The selection frame works on every monitor and with different scaling factors. In the MVP, a single drag stays limited to the monitor on which it started; combining across displays is a later candidate.
- `Esc` already cancels the region selection.
- The mouse pointer and the overlay must not appear in the screenshot.
- Status indicators for “Recognizing”, “Speaking” and “Stopped” stay small and non-modal.
- Errors are shown in an understandable and actionable way.
- An empty or unreadable result does not start TTS.
- Keyboard operation and VoiceOver labels are considered from the start.

## Small reading panel

- Selection 2026-09-22: The interaction area measures 136 × 44 pt (at the sides 44 × 136 pt); since 2026-10-13 the visible surface inside it is 136 × 28 pt. At rest it shows nine wave bars and Stop; hover cross-fades the wave to Pause/Resume and ···/+N. Size and Stop position remain unchanged. Both secondary buttons have separate 40 × 44 pt targets, Stop 44 × 44 pt. From 5 pt of movement on, the secondary buttons also drag instead of click; cancellation suppresses pending clicks. Pause is active only during playback. While the popover is open, the buttons stay visible. The “Playback Controls…” menu item and VoiceOver actions provide access without hover. Popovers open toward the center of the screen. Error help (?) stays visible; normal end states hide the secondary buttons. The discarded 160 pt variant and the earlier hover widening with an Esc keycap are dropped.

- A non-activating, non-modal panel appears only after capture has finished: “Recognizing text…”, “Preparing…”, “Reading aloud”.
- It stays at the bottom center of the selected display, within its usable area with a margin to the Dock. It follows neither the mouse nor the selection rectangle.
- The Stop button and `Esc` end the complete job. Pressing the hotkey again adds text instead of cancelling (project decision of 2026-09-09). No additional confirmation click before reading aloud.
- “Done” and “Stopped” stay for 1.1 seconds and then retract within 240 ms. “No text recognized” and errors stay visible with a close button; error details are in the app menu. A new job removes any old panel immediately before the selection, without waiting for an animation.
- Reading control: visible capsule 136 × 28 pt, transparent interaction area 136 × 44 pt, fixed drawing surface 300 × 92 pt. Hover does not change the size; end states are 100 pt wide, hints temporarily wider. Deep blue material, a fine light petrol edge and a soft shadow match the dictation bar. Apricot is reserved for hints.
- Both activities use nine rounded light petrol bars: 2.5 pt wide, 3 pt apart, 2–18 pt high; with gently lighter petrol tips and subtle light scattering at speech level. Their height follows the actual level with a fast rise and a slower decay. Silence stays flat. Recognizing, preparing and waiting show the same brightness sweep across flat dots. No artificial breathing or syllable animation, no fake progress. CADisplayLink and time-based smoothing keep the response consistent across different refresh rates.
- After capture, the selection frame visibly falls as a light petrol ghost into a glowing dot at the stored edge position on the selected display and springs open into the capsule there; the open sound coincides with the landing. The flight window is click-through; a new job or cancellation removes it immediately.
- End states replace the bars with a drawn symbol (checkmark, stop square, amber ring with exclamation mark) that draws itself. No additional pulse or glow ring. The button becomes a close cross. Hints show two words for about two seconds, then only the symbol; hover shows the text again. Full titles and details are always in the Accessibility labels, and every state change is posted as a VoiceOver announcement.
- Position: horizontal at the bottom or vertical at the left/right edge (92 × 300 point drawing surface); symbols and the 44 × 44 point Stop button stay upright. Drag the waveform or status surface; from 5 points of movement on, the panel follows directly. Since 2026-10-14, the throw direction determines the edge on release: the pointer velocity of the last 100 ms is projected forward with Apple's deceleration rate 0.998, and the edge nearest to that point wins. One spring per axis (response 0.3 s) takes over the velocity without a transition edge; a calm drop is critically damped, and only a throw may overshoot slightly. Beyond the usable area, the capsule gives way progressively (rubber band) instead of stopping hard. When switching between horizontal and vertical, the capsule reshapes; the haptic feedback comes on snapping. Reduce Motion skips this movement. The Dock and menu bar are left out through the usable screen area. Edge and relative offset are kept locally. Settings offers the same three positions and a preview without OCR/TTS. Side hints use a tooltip and VoiceOver instead of rotated text.
- Continuous motion: the same native view persists for the duration of the job. Both capsules appear with a 140 ms fade-in and critically damped scaling from 96 to 100 percent. Size changes follow a critically damped spring without decorative overshoot or deformation. Reading aloud retracts within 240 ms on normal completion. Buttons give visual feedback directly on press; the Stop target stays 44 × 44 pt. The flight from the selection frame to the capsule starts fast (ease-out, 380 ms). Cancellation starts immediately and never waits for motion.
- With “Reduce motion”, spatial and running animations are dropped; the bars stand still, and opening keeps only a short fade-in. “Reduce transparency” or “Increase contrast” makes the body opaque; increased contrast additionally strengthens the outline.
- Three original, locally synthesized stereo sounds (since 2026-10-14 without the button tick and tock: stopping is a cancellation and stays silent) from a family of wood and water: marimba bars with 1 : 4 : 10 partials, water drops as a rising bubble chirp, a deep log drum hit underneath and a small synthetic room. Open on landing (900 ms, two rising bars G3 → C4 with a drop), natural completion (1.0 s, deliberately subtle: a quiet low marimba fundamental and three rising drops, peak level 0.36 instead of 0.5), missing text/error (800 ms, two muted falling wood hits). The spectral centroid of the main sounds lies around 250 to 280 Hz, with a supporting mid layer for laptop speakers. Open and completion alternate between two voicings. Since 2026-10-14, three short microphone sounds for dictation have been added (see “Sounds during dictation”). Enabled by default, effect volume 70 %, separately adjustable and switchable off via “Interface sounds”. No sound for stopping itself; cue sounds that are playing are stopped before speech playback and on cancellation. Sound is never the only cue.
- The panel shows only status, never OCR text or a preview. Status changes and the Stop click must not take focus from the app currently in use.
- Speed: 0.75× to 2× in the menu and Settings, live and stored locally; pitch unchanged. Pause and voice selection stay outside the capsule.
- Additional texts: press the same reading hotkey again or choose “Add Screen Region to Queue…”, without interrupting the current voice. The previous separate shortcut remains an optional extra but is not needed. At most five waiting texts, FIFO, a subtle +N on the capsule; “Next Text” in the menu skips the current text. Esc/the Stop button always clear the complete queue, including during an additional selection. Full queues and empty/failed additions show a message without interrupting the current voice. No caching on disk, no history. If the voice ends during an additional selection/OCR, the app waits, cancellably, for the next text.

## Performance targets

- Queue: one speech process stays loaded for the session. As soon as the current synthesis has finished, at most the next text is precomputed while playback is still running (at most eight seconds of source audio in the preparation buffer). A prepared handoff gets a short 120 ms gap, no additional loading animation or cue sounds. Texts added late may still require waiting. Stop/Esc also clear the preparation and the warm model. Skipping keeps the prepared successor; if a current synthesis that is still running has to be cancelled hard, a worker restart may be necessary.

- With a warm default model, the first audio block should be ready in less than 500 ms after the OCR text is complete, where possible. This is a target, not evidence for the current Supertonic development path.
- The first sentence is played while later sentences are still being synthesized.
- Cancellation response: target under 100 ms until audio falls silent.
- The model is kept warm for a limited time; the exact duration is set based on energy and RAM measurements.
- An economy mode may use a smaller model.
- The larger installation file caused by the bundled model is clearly stated on the website before download.

## Text fidelity

The pipeline needs test cases and, where appropriate, a fidelity mode for:

- numbers, dates and amounts of money;
- abbreviations and initials;
- URLs and email addresses;
- product codes and identifiers;
- mixed-language texts;
- OCR line breaks and hyphens;
- tables, columns and source code.

Pleasant prosody must not justify omitted words or paraphrasing.

## Not in the first MVP

- cloud voices;
- translation;
- summaries or chat;
- voice cloning;
- document library;
- persistent history;
- full screen reader navigation;
- Windows or iOS versions.

## Later candidates

- read the previous region again;
- repeatedly monitor the same region;
- repeat a sentence;
- optional copying;
- sentence or word highlighting;
- custom pronunciation corrections;
- additional local TTS providers.

## Dictation — integrated after approval 2026-10-13

Since 2026-10-14: permissions in the shared setup (“Set Up & Test…”); model, language (Automatic/German/English) and 1/2 s clipboard restore under Settings → Dictation; test window via “Try Dictation…” with its own test field; demo audio samples only in debug builds. ⌥⇧Space starts/ends dictation in the previously focused field; Esc discards. The non-activating status surface shows recording/recognition/pasting and offers Discard. Text appears after stopping, not during recording. A cold start may keep PCM in RAM, bounded, until the selected model is ready. Reading aloud ends before recording; starting reading aloud discards dictation. No automatic recording after the permission dialog and no Return key press to submit. If the target changed, the result is kept in the dictation window for manual copying. An exact read-back check distinguishes “Pasted” from “Paste sent”. Universal text field compatibility is not guaranteed.

## Keyboard decision 2026-10-13

Reading aloud uses **⌥R** by default (explicitly only two keys); repeating it still adds another region to the queue. Stored combinations are kept, including the earlier default ⌘⇧Y. An explicitly chosen ⌘⇧Y (as on the maintainer's own installation) must not be overwritten on relaunch. Dictation uses **hold/release Fn**, **double Fn** or **Fn+Space** for hands-free, Fn again to finish and Esc to discard. Single short Fn taps are discarded; a third quick tap also discards. Since 2026-10-14, locking in is audible and visible (the “hands-free locked” sound, a filled finish button), and the test window names both ways: hold or press twice. Other Fn combinations should remain usable unchanged. ⌥⇧Space remains the alternative without Fn. Fn requires available global keyboard control with Accessibility permission.

## Dictation model selection — 2026-10-13

Settings → Dictation offers Qwen3-ASR, Whisper Turbo and (since 2026-10-14) Whisper Large v3 in the “Model” field (until 2026-10-13 in the dictation window). The default is Whisper Turbo, which every build includes. Models that are not installed are listed there as “Install *model*… (size)”; selecting one opens a confirmation with download size and source, after which the row shows progress and “Cancel”, and on errors “Try Again”. After installation, the model is selected.
The choice is kept after a relaunch. The selected model loads automatically;
the loading status names it and does not start a recording. During an active dictation,
the selection is locked. On a loading error, the selected option stays visible,
without an automatic switch or download. Language, shortcuts and paste behavior
are the same for both models.

Since 2026-10-14, Whisper Turbo is listed first and is preselected when no choice
has been stored. Below it, the “Vocabulary” field takes one name or term per line
(also comma-separated, at most 50). Changes apply from the next
dictation on; empty lines and duplicates are ignored.

The integrated dictation capsule shares Saywing’s reading material and motion language, with distinct discard and finish/paste controls.

## Apple design refinement — 2026-10-14

Approved: implement all points of the review of 2026-10-14.

- **One language per surface:** English source strings, a complete German String Catalog; the app follows the system language.
- **Menu:** status first; hints only when they add information; “Read Screen Region…” shows the global shortcut; Pause, Next Text, Add and Playback Controls appear only while reading aloud; errors offer “Open Setup…”.
- **Settings:** tabs General, Read Aloud, Dictation, Shortcuts, Privacy. Shortcuts are pressed in a recording field instead of being built from checkboxes; the additional queue shortcut is under “Advanced”. Permissions show their status and open their own section in System Settings.
- **Setup:** one flow for reading aloud and dictation; since 2026-10-14 as a guided setup (below). The earlier note that the reading test needed only Screen Recording was wrong: capture does not start without Input Monitoring (ADR 0005).
- **Selection:** Space moves, Shift locks the edge that was initially unmoved, Option grows the selection from the center – as with ⌘⇧4. The dimming fades in over 90 ms, input takes effect immediately, and the overlay still closes immediately. A short hint appears for the first five selections.
- **Click reads a paragraph:** a click without dragging recognizes a bounded area (max. 1200 × 800 pt) around the pointer and reads only the paragraph under it; the rest is discarded immediately. Details under [Privacy](privacy.md).

## Guided setup

Approved on 2026-10-14 after the proposal based on the Apple design skill (“ask at the right moment, only for what's needed”).

- **One decision per page**, fixed window (500 × 560 pt). Symbol and title are in the same place on every page. The main action is at the bottom right (Return), “Back” at the bottom left, and “Later”/“Not Now” is always reachable with equal weight.
- **Order:** Welcome → Screen Recording → Input Monitoring → reading test → “Write with your voice too?” → (if yes) Microphone → Accessibility → dictation test → Done. The order follows only from the current permissions. Granted steps are skipped, and a test that could only fail without its permission is dropped. Anyone who comes back lands on the first missing step and never on Welcome again. Nothing about progress is stored.
- **Titles by benefit, not by system term** (“Read the text you mark”, “Stop anytime with Escape”). The name used in System Settings is shown small underneath so that it can be found again.
- **Waiting for System Settings:** After “Allow…”, Saywing checks every 300 ms, and only while this step is waiting. Once the permission is there, a checkmark draws itself, Saywing brings its window to the front and pages forward after 0.9 s. If Screen Recording is turned on but not yet effective, the page offers “Quit & Reopen”; setup then continues (`--resume-setup`).
- **Hint next to System Settings:** while waiting and while System Settings is in front, a small card floats next to its window: “Turn on Saywing”, with the app icon, which can be dragged into the list. The card can be closed and disappears as soon as the permission is there.
- **Reading test in the window:** the shortcut is shown as a key, with a dedicated sample sentence below it. The user drags a frame around it as usual; the real pipeline reads it aloud. The setup window is the only one of the app's own windows that capture may read, so no private screen content is needed. Esc while reading aloud counts as success.
- **Dictation** is offered, not required. The test uses the existing dictation test field.
- **Done** shows the menu bar with the Saywing icon highlighted, and “Saywing lives here” appears under the real menu bar icon, because the app has no Dock icon. Missing permissions are listed there, each with one action.
- **Ask at the right time:** if a reading permission is missing, the shortcut opens setup directly instead of first allowing a selection that would then fail. The dictation hint “Open Setup…” jumps directly to the dictation steps.
- **Motion:** the new page slides in from the direction of movement, critically damped (`response 0.35`, without overshoot); the old one fades out. With reduced motion there is only a cross-fade, and the checkmark then appears without drawing. Every page and result change is announced for VoiceOver.

## Feedback where it happens

Approved on 2026-10-14 after the third review with the Apple design skill.

- **Error help at the capsule:** after an error, the “?” of the reading capsule opens a popover directly at the capsule, with the specific reason and exactly one next step: “Try Again”; “Shortcut Settings…” if the shortcut is taken (opens the Shortcuts tab); and “Open Setup…” if a permission is missing (jumps to the missing step).
- **Dictation at the cursor:** the dictation capsule appears directly below the insertion point, above it if space is lacking, and always on screen. If no insertion point can be determined, it appears where the user docked the reading capsule. It does not jump during a dictation.
- **Dictation test window:** one sentence of instructions, status, test field, Record/Discard. “Not pasted” with the result and Copy appears only if pasting failed or was not confirmed. Permissions go through setup.
- **Sounds during dictation:** the same cue sounds as for reading aloud and the same setting: “done” on confirmed pasting, “attention” on unconfirmed pasting or a problem. The sound coincides with the visible state. Status messages during a recording stay silent and are not announced.
- **Microphone sounds and hands-free (project decision 2026-10-14):** dictation used to be silent; now it has three short sounds of its own from the wood-and-water family, each under 450 ms, quieter than the reading sounds and with almost all of the energy in the first 150 ms.
  - **Microphone on** (Fn pressed): a soft marimba hit on C4 with a small rising drop. It sounds as the capsule appears, as soon as the microphone is open.
  - **Hands-free locked** (double Fn or Fn + Space): the same hit a fifth higher, on G4. Following “microphone on”, this makes a rising fifth. The capsule's finish button fills with light petrol and snaps in once with a critically damped spring from 86 to 100 %; without text, timer or additional glow. Starts via ⌥⇧Space or the record button in the test window are hands-free from the beginning and sound only this one sound.
  - **Microphone off** (release, Fn, finish button or the 60 s limit): a muted hit on G3 without water. It sounds only after the microphone has closed and is therefore never part of the recording.
  - Discarding (Esc, cross, third quick tap, discarded single tap) stays silent and immediately ends a microphone sound that is still playing. A sound that follows another fades the previous one out over 30 ms instead of cutting it off hard.
  - Confirmed pasting is read back as early as 150 ms after pasting. If the text is there, the checkmark and completion sound appear together with the text instead of a second later; the clipboard is still restored only after 1 s or 2 s. Otherwise, as before, the check at that point decides.
  - Deliberately open: microphone on and hands-free locked sound while the microphone is already recording. Over speakers, the short sound can end up in the first roughly 150 ms of the recording. A measurement with the real models is pending; with headphones this does not occur.
- **Menu bar icon:** a dot while reading aloud, a small triangle after an error. The state can be recognized by shape, not by color, and the icon stays a template. For recordings, macOS shows its own microphone indicator.
- **Accessibility (audit 2026-10-14):**
  - Dictation results, Pause/Resume, new texts in the queue, the selection overlay, shortcut hints and waiting for System Settings are announced. Errors are announced with high priority. The start of speech and ongoing recordings are not announced, so that VoiceOver neither speaks over the voice nor gets recorded.
  - In the selection overlay, Return reads the paragraph under the pointer.
  - Tab leaves the dictation test field.
  - Pause and Options of the reading capsule are visible while VoiceOver or Switch Control is active.
  - Queue rows carry the text as their name.
  - The shortcut fields are named after their task and report changes.
  - Status texts use the full-contrast color; color carries only the symbol.
  - The selection frame has a dark outer line; with increased contrast it is black and white.
  - In setup, VoiceOver focus lands on the new page title.
  - The menu offers “Finish & Paste” during a recording and “Try Dictation…”.
  - Opening Playback Controls from the menu gives it keyboard focus; a click on the capsule keeps the active app in front.


### Setup: model and shortcuts (2026-10-14)

- Between permissions and trying it out, the guided flow adds model and shortcut steps for each activity. Welcome, permission help and the optional dictation offer are kept. The current step is kept even across relaunches. Model and shortcuts can be configured without permissions; tests re-check the required permissions.
- For dictation, the bundled Whisper Turbo comes first; further models can be expanded. Installed models can be used, and missing approved models can be downloaded after confirmation. The confirmation states size and source. Download progress and the subsequent file verification are shown separately and can be cancelled.
- An interrupted download keeps the desired selection but does not restart automatically at the next app launch. “Download…” offers a confirmed new attempt. The new model is not activated until verification is complete; the dictation test stays locked while a selection is pending.
- Reading aloud and dictation get their own recording fields for key combinations. Conflicts with the other one or with the additional queue shortcut are explained. A failed registration does not overwrite a stored choice. Fn gestures can be disabled separately. Escape remains cancel.
- While a key is being recorded, reading aloud, the queue, the dictation shortcut and Fn are paused. After completion or cancellation, the stored shortcuts are registered again. Setup and Settings use the same components and preferences.

## Meeting transcript — 2026-10-15

Project decision of 2026-10-15 ([ADR 0006](decisions/0006-local-meeting-transcript.md)).

- **Start:**
  - The menu item “Transcribe a Meeting…” opens the transcript window with the consent step.
  - The step explains in three lines what will be recorded. It contains a copyable sentence for the meeting chat and the button “Everyone Is Informed – Start”.
  - If the feature is not available (macOS older than 26 or language not installed), the window says exactly that instead of offering a start.
- **Live:**
  - The window shows “Me” and “Others” as a conversation.
  - Volatile text is shown in the secondary color and is replaced as soon as it is final.
  - The view scrolls along while you are at the bottom.
  - Two small level meters show that both tracks are arriving. If no sound comes from other apps for 20 s, a hint about the system audio permission appears.
  - Stop is the only button (⌘. as everywhere on the Mac; Return does not end anything by accident). Closing only hides the window; the menu brings it back.
  - Following along only while you are at the bottom: anyone who scrolls up to reread stays there; “Latest” jumps back.
- **Afterwards:** on the left “Discard” and “New Transcript” (leave the transcript), on the right “Copy” and “Save…” (keep it, main action). Copy and Save confirm briefly with a checkmark in the button. Discard and New Transcript ask for confirmation only as long as the text has been neither copied nor saved.
- **Sounds:** start with “microphone on”, end with “microphone off”, both from the existing family and with the same setting.
- **Menu:**
  - During recording, “Meeting Transcript · Running” with “Show Transcript” and “Stop Transcript”.
  - The menu bar icon carries a ring, i.e. a shape of its own. Unlike with dictation, the system's microphone indicator is not enough here, because system audio is recorded as well.
- Esc, reading aloud and dictation leave a running transcript untouched.

### Meeting transcript design review — 2026-10-16

Reviewed against the Apple design skill and the [Saywing brand system](brand-identity/BRAND_SYSTEM.md).

- Same language as setup: symbol on a petrol-tinted circle, centered title with one explanatory sentence, footer with large controls and the main action on the right, petrol as the accent (`AccentColor`), critically damped page transitions or a cross-fade with reduced motion.
- Level meters in the capsule vocabulary: five 2.5 pt bars with 3 pt spacing per track in petrol, updated five times per second and smoothed with critical damping; silence as flat, muted dots.
- “Me” is shown in petrol, “Others” in the primary color; the label says which is which, and color is never the only distinguishing feature. Warnings color only their symbol (as in setup and Settings).
- Deliberate deviation from the dictation capsule: the window shows “Recording” with a red recording symbol and the duration. The rule “no text, no timer” applies to the small capsule at the cursor; a transcript of up to two hours that hears other people needs a visible state and the time remaining until the limit.
- Menu bar: the ring as a fourth shape next to the dot and triangle, with the same size, position and inset.

### Voices and PDF — 2026-10-18

Project decision ([ADR 0008](decisions/0008-meeting-speakers-and-pdf.md)).

- **Voices:**
  - When Saywing tells the others' voices apart, their turns are labelled "Speaker 1", "Speaker 2" and so on ("Person 1", "Person 2" in German), numbered in the order of their first words.
  - A calm color mark precedes the label. The color only helps scanning; the label says who is speaking.
  - Clicking the label opens "Rename…" (a dialog with a name field) and "Same Person As ▸" (merge, when one person was heard as two voices).
  - Names apply immediately to every turn and to the export. A change counts as unsaved.
  - Voices appear only in builds that carry the optional model, which is off by default.
  - Without a model or after an error, the turns stay "Others"; an error during recording is mentioned once in the footer.
  - The label follows the speech by about one second. Similar voices can be heard as one; "Same Person As" fixes only the opposite case.
- **Saving:**
  - The save dialog has a "Format:" menu with PDF (preselected), Markdown and plain text. Switching changes the file extension in the name field.
  - Nothing is remembered between two saves.
- **PDF:**
  - A4, title, duration and participants, the note "Transcribed on this Mac with Saywing", name and time for each turn, page numbers "1 / 3".
  - Fixed colors (black, gray) regardless of the Mac's appearance.
  - Tagged for screen readers.
