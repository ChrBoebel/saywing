# Changelog

Notable changes to Saywing (formerly OpenScreenReader). Dates are when the change was integrated during development. Version numbers will be added with public releases.

## [Unreleased]

- **Runtime for telling the others' voices apart.** The meeting transcript can now use the LS-EEND voice model through FluidAudio 0.18.2, linked with only its `Diarizer` trait, on the device and without any download. Public builds carry the model from the next release on, by maintainer decision and with the training-data risks accepted (ADR 0008). The release workflow bundles it when `SAYWING_BUNDLE_DIARIZATION_MODEL` is `true`; without it the others stay "Others". Tested on read speech; real calls are unmeasured, and similar voices or short turns can be confused.
- **Honest privacy and status texts.** Setup no longer says "no internet connection": it says reading and dictation work offline and that update checks and models you install use the internet, and the Privacy tab names the update check. Release builds show "Bundled · works offline" instead of "offline development preview", and the length limit no longer mentions a development version.
- **Speech failures say what happened.** The speech worker reports a failure code, so a damaged model asks for a reinstall, low memory asks you to close apps, and only a real length problem mentions a smaller region. A crash, a synthesis failure or a timeout retries the passage once with a new worker and continues without repeating audio, so the queue survives. If the error is final, the message says that waiting texts were cleared.
- **Comparison with Apple's features corrected.** The FAQ now says that Speak Selection can read text in images where Live Text works, and describes Saywing's actual difference.
- **Dictation runtime verified.** The dictation runtime in the public 0.1.30 build transcribed real German and English audio on an M4 Mac (see [docs/runtime-build.md](docs/runtime-build.md)). The roadmap now reflects the public beta.
- **Releases on GitHub.** After both architectures are published on the download host, the release workflow also creates a GitHub release (tag `v<version>-build<build>`, a pre-release while the beta exception applies) with both DMGs, a combined `SHA256SUMS` checked against the published `latest.json`, and notes from this changelog, so watchers are notified. Installed copies keep updating through Sparkle from the maintainer's site ([details](docs/release-and-updates.md#github-release-mirror)).
- **License review completed.** The maintainer completed the license review without external counsel and accepted the documented residual risks; both release approvals now have `license_review: true` ([ADR 0003](docs/decisions/0003-bundled-default-model.md)). Publications stay beta builds while the fresh-device test is open, and publishing still stops until the public source copies are reachable.
- **Model terms: German version equally binding.** The Supertonic 3 model terms now include a complete, equally binding German version with a German translation of Attachment A, German governing law with the consumer proviso, a warranty and liability clause for the free offering, and a non-binding note on ordinary read-aloud use. Changing the terms asks every user to accept them once more.
- **Public corresponding source next to every download.** The GNU runtime libraries' sources and the Eigen source are served publicly from the download host, and publishing stops if they are not reachable with the expected size and SHA-256. libquadmath is distributed under LGPL-3.0 (it is LGPL-2.1-or-later). See the amendment in [ADR 0007](docs/decisions/0007-gcc-runtime-libraries.md).
- **Supertonic 3 model terms need explicit acceptance.** Saywing asks you to accept the model terms before the read-aloud voice is used; the terms now name the distributor, end on a breach of Attachment A, ask you to mark shared speech as machine-generated and cover redistribution through mirrors, package managers and forks. The DMG `Licenses` folder starts with a README that limits Apache-2.0 to the source code. Existing installations, including the 0.1.17 betas after an update, ask for acceptance once before reading aloud again.
- **Source offer for the 0.1.17 betas.** The served beta DMGs were checked: they do not contain the prototype runtime of private builds 1–5. A written offer with exact source pointers now covers their GNU runtime libraries and Eigen ([notice](docs/licenses/beta-0.1.17-corresponding-source.md), [ADR 0007](docs/decisions/0007-gcc-runtime-libraries.md)).
- **Repository renamed to `ChrBoebel/saywing`.** Old `ChrBoebel/OpenScreenReader` links redirect. Technical identifiers keep the OpenScreenReader name for compatibility.
- **README overhaul.** Read aloud and dictation lead, followed by privacy, an honest install status, requirements and an FAQ (including how Saywing differs from Speak Selection). Test gaps moved into a collapsible status section, and the runtime build description now points to the one-command assembly from public sources.
- **Docs wording.** The privacy requirements and roadmap describe decisions in neutral project language with their dates. The issue chooser links to Discussions for questions and ideas.
- **Contributor and support paths.** `SUPPORT.md`, an accessibility-barrier issue form and a documentation index (`docs/README.md`, `docs/licenses/README.md`). Monthly grouped Dependabot updates for the SHA-pinned GitHub Actions.
- **Release gate records moved** from `docs/` to [`release/`](release/README.md); `scripts/release.py` reads them from there. The gates themselves are unchanged.
- **Docs wording across architecture, research and decision records** uses neutral project language; the development packaging guide has an accurate title; the roadmap starts with a Now / Next / Later overview.

## 2026-10-24

Open-source preparation.

- **Release runtimes are built from pinned public sources.** CI downloads every input, checks its size and SHA-256 and builds the speech and dictation runtimes instead of fetching a private archive. See [docs/runtime-build.md](docs/runtime-build.md).
- **Licenses in every DMG.** The DMG shows the license and the Supertonic model terms; notices and corresponding sources ship for the bundled runtimes. The license review gate is reopened for both architectures until the remaining items in [ADR 0003](docs/decisions/0003-bundled-default-model.md) are closed.
- **Worker sandbox.** Local model workers and script workers run under a deny-default macOS sandbox profile without network access or file writes.
- **Dictation hardening.** Pasted text stays off Universal Clipboard, and password-manager items on the clipboard are cleared instead of restored. Model downloads reject unlisted or swapped files and stop when they exceed their pinned size.
- **Project infrastructure.** CI is split from a dispatch-only release workflow with code owners and hash-locked CI dependencies; contributing guide, code of conduct, security policy and issue forms; documentation translated to English. `filelock` in the dictation runtime is updated to 4.2.4.

## 2026-10-15

- **Meeting transcript (macOS 26+).** An explicitly started, consented live transcript of the microphone ("Me") and other apps' audio ("Others"). It uses a private Core Audio tap and Apple's on-device `SpeechTranscriber`. Local echo suppression keeps your speakers' playback out of your side. Audio is never saved; the text stays in memory until Copy, Save or Discard. The transcript stops after 2 hours, after 10 silent minutes, on sleep, or on Stop. See [ADR 0006](docs/decisions/0006-local-meeting-transcript.md).
- Intel (x86_64) builds: reading with Supertonic 3, dictation with Whisper Turbo through whisper.cpp.

## 2026-10-14

- **Whisper large-v3-turbo is the bundled default dictation model.** Qwen3-ASR and Whisper Large v3 are installed only after the user explicitly confirms a download from a pinned Hugging Face revision, with every file SHA-256-verified before use. An optional local vocabulary was added.
- **Guided, resumable setup.** The setup flow shows one decision per page: permissions, model and shortcuts, then a real reading or dictation test. Progress survives an app restart, and restoring setup never starts a capture or recording.
- **Shared capsule.** Reading and dictation share one compact capsule. The reading capsule is 136 × 28 pt; the dictation capsule is 120 × 28 pt with separate discard and finish targets. Hover reveals Pause/Resume and the options; the same controls are available from the menu and to VoiceOver.
- **Selection gestures** like ⌘⇧4 (Space to move, Shift to lock an edge, Option to grow around the start point). A click reads the paragraph under the pointer.
- **Dictation sounds and hands-free mode.** Short local cues mark the microphone opening, hands-free latching and closing. Discarding is silent.
- **Localization.** All interface text is in string catalogs with complete English and German translations; `scripts/check-localization.py` verifies coverage.
- **Updates.** Sparkle 2.10.0 integration with disableable update checks, native update UI and protection against relaunching during an active operation. Developer ID signing and notarization scripts were added.
- Docking of the reading control with projected momentum and springs.

## 2026-10-13

- **Renamed to Saywing** with a new app icon, menu bar glyph and palette. Technical identifiers keep the OpenScreenReader name for compatibility.
- **Local dictation.** German and English dictation into the focused text field, using push-to-talk on Fn, hands-free mode, Escape to discard, and clipboard paste with ownership-checked restoration. The model prepares automatically on launch without opening the microphone.

## 2026-09-09

- Live pitch-preserving reading speed from 0.75× to 2×.
- Bounded queue: repeating the reading shortcut adds another region without interrupting playback. The queue can be edited (reorder, remove, play now) from the capsule's options.
- Pause/Resume, and a warm model session that prepares the next queued text while the current one plays.
- First-use setup with permission preflight and a real region test.

## 2026-09-05

- Supertonic 3 (voice M1) selected as the default local voice after a German listening comparison. It runs as a sandboxed local ONNX worker. Qwen3-TTS remains a comparison experiment only, never a fallback.
- Floating reading-status panel with full-pipeline Stop.

## 2026-09-04

- Project foundation: native SwiftUI/AppKit menu bar app, configurable global hotkey, multi-display region selection, in-memory ScreenCaptureKit capture and local Apple Vision OCR for German and English.
