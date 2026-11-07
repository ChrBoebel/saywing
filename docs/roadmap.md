# Saywing roadmap

## At a glance

**Now — public beta**

- Saywing 0.1.30 (2026-10-27) is a signed and notarized beta for Apple Silicon and Intel, on the [download page](https://www.christopherboebel.com/en/saywing), [GitHub Releases](https://github.com/ChrBoebel/saywing/releases) and through a [Homebrew tap](https://github.com/ChrBoebel/homebrew-tap).
- Hotkey → region selection → local Apple Vision OCR → automatic local speech with Supertonic 3; `Esc` and Stop cancel the whole pipeline.
- Live speed (0.75–2×), a bounded queue fed by repeating the shortcut, pause/resume and on-demand capsule controls.
- Guided first-use setup with a real reading test.
- Local dictation: Whisper Turbo by default with an optional vocabulary; Qwen3-ASR selectable.
- Local meeting transcript with a consent step, a RAM-only transcript and PDF, Markdown or plain-text export.

**Next — before a non-beta release**

- Fresh-Mac (clean-Mac) walkthrough, including the dictation target-app matrix; this is the `clean_mac` gate that keeps releases in beta.
- Blind listening comparison with Apple's voices, voice selection, and memory/latency/energy measurement on an M4 with 16 GB RAM.
- Live VoiceOver/keyboard walkthrough ([#46](https://github.com/ChrBoebel/saywing/issues/46)) and a full real UI regression.
- A guide to verify offline behavior yourself ([#48](https://github.com/ChrBoebel/saywing/issues/48)).
- Telling the others' voices apart in meeting transcripts: the code now uses Nemotron 3 Diarization; public builds carry it by maintainer decision of 2026-11-07 ([ADR 0008](decisions/0008-meeting-speakers-and-pdf.md)); measuring it on real calls is still open.
- Physical macOS 14/15 and Intel reports ([#47](https://github.com/ChrBoebel/saywing/issues/47), [#31](https://github.com/ChrBoebel/saywing/issues/31)).
- Name comprehension and trademark review; demo GIF/video and screenshots.

**Later — candidates, each needing its own decision**

- Repeated capture of the previous region, automatic language switching, sentence or word highlighting and custom pronunciation rules.
- Additional local providers (if justified by listening tests) and an optional plugin interface for them.
- Meeting transcript extensions such as Whisper refinement, summaries and macOS 14–15 support.
- An official homebrew/cask entry, once the project meets Homebrew's notability rules.

## Brand and product direction — 2026-10-14

- [x] Renamed the product to Saywing (formerly OpenScreenReader) with the tagline “Vorlesen & Diktieren für macOS” (2026-10-13); adopted the **Text to Voice / concept B** identity with the selected Ink Navy, Paper, Petrol and Apricot palette (2026-10-14).
- [x] Update native product name, app icon, template menu glyph, UI palette and current brand documentation.
- [ ] Validate name comprehension with real participants; no results are implied by the naming decision.
- [ ] Complete trademark similarity review and confirm desired domain with a registrar.
- [x] Qwen3-ASR dictation with clipboard restore integrated in the app (2026-10-13).
- [x] Whisper Turbo becomes the default dictation model with an optional local vocabulary (2026-10-14).
- [ ] Complete dictation target-app matrix, real microphone/Hotkey walkthrough in the integrated bundle, clean-Mac packaging and distribution gates.
- [x] Local meeting transcript (2026-10-15, [ADR 0006](decisions/0006-local-meeting-transcript.md)): system audio tap + microphone, on-device `SpeechTranscriber`, echo gate, consent step, RAM-only transcript with explicit copy/save.
- [ ] Meeting transcript gates: real call over speakers and headphones on the signed build, permission prompt, echo duplicates, word errors on real speech, 60-minute CPU/memory, no files written.
- [x] Meeting speakers and PDF export (project decision 2026-10-18, [ADR 0008](decisions/0008-meeting-speakers-and-pdf.md)): voices of the others told apart and nameable, tagged PDF/Markdown/text export.
- [x] Meeting speakers adapter: FluidAudio 0.18.2 with only its `Diarizer` trait, tested with the real model on read speech.
- [x] Meeting speakers model change to Nemotron 3 Diarization (2026-11-07): adapter, preload from the consent step, manifest, notice, evaluation on dev and test.
- [x] Meeting speakers model: maintainer license decision on Nemotron 3 Diarization (OpenMDW-1.1, LDC data in training), recorded 2026-11-07.
- [ ] Meeting speakers: the gates of ADR 0008 on recorded calls.
- [ ] Meeting transcript candidates, each needing its own decision: Whisper refinement with the vocabulary, summaries, meeting detection, mixed-language meetings, macOS 14–15 support.

## Current delivery — 2026-09-09

- [x] Live pitch-preserving speed (0.75–2×), bounded FIFO queue and same-shortcut additions.
- [x] Warm model session and bounded preparation of the next queued text.
- [x] Pause/resume with bounded audio backpressure and stop while paused.
- [x] On-demand capsule controls: speed, next text, queue preview, remove, move and play now; previews remain RAM-only.
- [x] First-use setup view with permission preflight, explicit requests and a real-region test entry point. Preflight is not presented as an end-to-end success.
- [x] Conservative soft-hyphen/spacing repair and abbreviation/ordinal-aware speech segmentation.
- [ ] Subjective German/English listening review of numbers, headings and abbreviations; no automatic speculative number expansion.
- [ ] Complete real UI regression: installed build, queue editing while speaking/paused, all three panel edges, full screen/Spaces and external display.
- [x] Private self-contained packaging spike: model/runtime bundled, isolated imports, relocated real speech/pause/cancellation and deep signature verification. Public release and clean-Mac validation remain separately gated below.

## Phase 0 — Foundation

- [x] Establish product vision, UX constraints, privacy principles, architecture hypothesis, and research summary.
- [x] Initialize local Git repository.
- [x] Confirm the pre-signing baseline bundle identifier and minimum macOS version.
- [x] Choose an Xcode application project with unit and UI test targets.
- [x] Choose a native SwiftUI/AppKit macOS implementation with Windows-ready provider boundaries.
- [x] Select a bundled default-model policy for the macOS MVP, subject to the packaging and license gates.

## Phase 1 — Technical spikes

- [x] Native menu bar shell with an automated UI smoke test.
- [x] Configurable global hotkey registration, local preference persistence, and transactional conflict handling. Broader layout/system-shortcut coverage remains experimental.
- [x] Implement multi-monitor region-selection overlay; broad physical display/Space verification remains open.
- [x] Implement selected-region capture with ScreenCaptureKit; permission-dependent tests remain separate gates.
- [x] Basic Apple Vision OCR for German and English; broader layout checks remain open.
- [x] Development-only native Qwen MLX worker with streamed first chunk ([pinned runtime and real checks](research/swift-runtime-evaluation.md)); warm performance and release packaging remain open.
- [x] Select Supertonic 3 as default after a listening comparison and implement a local ONNX development worker; [integration and verification](research/supertonic-integration.md). Qwen remains comparison-only, not a fallback.
- [x] Cancellation from `Esc` and explicit Stop controls; broader device/layout stress coverage remains open. Historical repeated-shortcut cancellation was superseded by same-shortcut queueing on 2026-09-09.
- [x] Packaged worker and bundled-model signing/notarization: shipped in the signed 0.1.30 beta.
- [ ] Offline and temporary-file privacy verification.

Each spike needs a small reproducible test or benchmark and a written decision before it becomes production architecture.

## Phase 2 — MVP

- [ ] Production-ready hotkey → overlay → screenshot → OCR → TTS → playback (development integration works; distribution, broader reliability, and performance gates remain).
- [x] Add bounded sentence segmentation and conservative text normalization; text-fidelity listening matrix remains open.
- [x] Add menu bar settings for the hotkey, including restore-default and conflict feedback.
- [x] Add a small branded reading-status panel with full-pipeline stop, without taking focus; broader display/accessibility checks remain open.
- [x] Add speed settings and session-bounded model lifecycle.
- [ ] Add voice selection after listening review.
- [x] Add explicit permissions onboarding; real installed-app walkthrough remains to be verified.
- [x] Guided one-decision-per-page setup with in-window reading test, System Settings hint and just-in-time setup (2026-10-14); some manual checks remain open.
- [ ] Add bundled-model manifest, source/license display, and integrity checks.
- [x] Add worker packet watchdogs, fail-closed cleanup and direct setup/error help; broader recovery stress tests remain open.
- [x] Add automated unit and integration tests; do not equate skipped permission/UI paths with success.
- [ ] Validate memory, latency, and energy use on an M4 with 16 GB RAM.

## Phase 3 — First public release (beta shipped 2026-10-27)

- [ ] Accessibility review and VoiceOver labels. Code audit and fixes done on 2026-10-14; a live VoiceOver/keyboard walkthrough remains open.
- [ ] Privacy verification guide ([#48](https://github.com/ChrBoebel/saywing/issues/48)).
- [x] Third-party notices and model license review: completed by the maintainer on 2026-10-25, with accepted residual risks in [ADR 0003](decisions/0003-bundled-default-model.md).
- [x] Signed and notarized builds for Apple Silicon and Intel (0.1.30, 2026-10-27).
- [ ] Demo GIF/video and screenshots.
- [x] GitHub issue templates, security policy, code of conduct and contribution guide.
- [x] First public beta after the licensing review; `clean_mac` stays open, so releases remain beta.

## Later candidates

- repeated capture of the previous region;
- automatic language switching;
- additional local providers, if justified by listening tests;
- sentence or word highlighting;
- custom pronunciation rules;
- optional plugin interface for additional local providers;
- an official homebrew/cask entry ([the tap](https://github.com/ChrBoebel/homebrew-tap) is live).
