# ADR 0008: Telling meeting speakers apart, and PDF export

- Status: accepted. The runtime adapter is integrated and pinned. By maintainer decision of 2026-11-04, public builds carry the DIHARD III variant from the next release on (see "Model decision"). Release 0.1.30 does not carry it.
- Date: 2026-10-18
- Decision: project maintainer, on a proposal to tell the voices of the other participants apart locally, let the user name them, and export the transcript as PDF.
- Extends: [ADR 0006](0006-local-meeting-transcript.md). That ADR listed speaker diarisation as out of scope until separately decided. This ADR is that decision.

## Context

A meeting transcript has two tracks:

- the microphone, labelled "Me";
- the system audio of every other app, labelled "Others".

Everybody on the other side of a call therefore ends up as "Others". Meeting apps mix all remote participants into one stream before it reaches the Mac. Participant names are only available through a bot, a vendor SDK, or by reading the app's user interface through the accessibility API. Wispr Flow does the last of these; it is fragile and app-specific.

Apple's `SpeechTranscriber` does not tell speakers apart.

The "Others" track is clean digital audio from the meeting app, without room reverb. That is a good case for acoustic speaker diarisation. "Me" is already known and is not diarised.

## Decision

1. **Diarise only the "Others" track, live, on the device.**
   - The model is LS-EEND, a streaming end-to-end diarisation model, as CoreML exports. It needs no separate embedding or clustering step and tracks up to 10 speakers at 10 Hz.
   - The runtime is FluidAudio's `LSEENDDiarizer`, in the app's own process on the CPU, not in the sandboxed Python worker.
   - Voices are shown as "Speaker 1", "Speaker 2" and so on, numbered in the order they first speak.
2. **No audio kept for diarisation.**
   - The audio is fed in as it arrives and discarded, like the recogniser's input.
   - An offline pass after Stop (pyannote Community-1) would need the whole track in memory: about 230–460 MB for two hours. It was rejected for that reason.
3. **Names come only from the user.**
   - A click on a speaker label renames that voice in every turn and in the export.
   - Two voices can be merged when the model split one person.
   - Names and merges live only in memory with the transcript.
4. **No voice profiles.**
   - Saywing never stores speaker embeddings or attractors.
   - It never recognises a person across meetings and never tries to identify anyone.
   - Model state dies with the transcript.
5. **Assignment.**
   - Recognised words carry audio time ranges. Each word of "Others" goes to the voice that spoke most during it.
   - A change of voice starts a new turn.
   - Words without a voice stay "Others".
6. **Fallback.** If the model is missing or fails, the transcript works as before with "Others". The window says once that voices are not told apart.
7. **PDF export.**
   - Save offers PDF (first), Markdown and plain text.
   - The PDF is laid out on A4 with Core Text.
   - It is tagged (heading and paragraphs) so screen readers can follow it.
   - Its document info holds only the title and "Saywing".
   - Writing still happens only through the explicit save panel.

## Model and code

| Item | Value |
|---|---|
| Model | LS-EEND, variant set only by `bundled_variant` in the manifest (see Open), 100 ms step, 8 kHz input |
| Source | `FluidInference/ls-eend-coreml`, revision `28ce1b1f8ef186729df63b3886fbaae7bc10c4a1`, folder `optimized/<variant>/100ms/` |
| Upstream | [Audio-WestlakeU/FS-EEND](https://github.com/Audio-WestlakeU/FS-EEND), Di Liang & Xiaofei Li, IEEE TASLP 2025 |
| License | The exporter publishes the model as MIT, and upstream code is MIT. The upstream authors have not answered whether MIT covers the checkpoints. |
| Training data | Every variant was pretrained on simulated mixtures from Switchboard-2 (Phases I–III), Switchboard Cellular (Parts 1–2) and NIST SRE 2004–2008 (Linguistic Data Consortium), with MUSAN noise and simulated room impulse responses ([paper, IV-A](https://arxiv.org/html/2410.06670v2)). The variant only changes the fine-tuning: AMI Train, CALLHOME Part 1 (`LDC2001S97`), DIHARD II Dev or DIHARD III Dev. No variant is free of LDC data. Datasets keep their own terms. |
| Size | 44.4 MB per variant (`weights/weight.bin`) plus about 0.2 MB of graph and metadata |
| Hashes | Every file is pinned in `Runtime/Diarization/ls-eend-manifest.json` with size and SHA-256 |
| Runtime code | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.2 (revision `e396cf780c4abf8e395087467c0585d3b0d17f68`), Apache-2.0, exact-version reference with `traits = (Diarizer)` in the Xcode project. Linked with it: `FastClusterWrapper` (fastcluster, BSD 2-Clause), `MachTaskSelfWrapper`, and VBx-derived clustering (Apache-2.0). Not linked: TTS code, G2P resources, the prebuilt NeMo binary. Notices: `docs/licenses/FluidAudio-0.18.2.txt`. |
| Delivery | Only in builds that carry it: `scripts/release.py --diarization-model`, which the release workflow passes only when the repository variable `SAYWING_BUNDLE_DIARIZATION_MODEL` is exactly `true`. Never downloaded at runtime. Weights are not committed to Git. |

## Consequences

- One new third-party Swift package in every build: about 7.3 MB more binary (Apple Silicon: 4.85 to 12.10 MB). A build with the model is about 43.6 MB larger on top.
- No new network path. The model is loaded from the app bundle with `LSEENDModel(modelURL:)`. FluidAudio's download code (`ModelHub`, `AssetDownloader`, `URLSession`) is linked but never called; the one file that imports FluidAudio sets `ModelHub.offlineMode`, which makes those paths throw, and a release test rejects download helpers in app sources. A run with all network denied by `sandbox-exec` works.
- Resolving packages also downloads the unused `NemoTextProcessing` binary artifact at build time, because SwiftPM fetches declared binary targets regardless of traits. It is checksum-pinned by FluidAudio and is not linked.
- On the first load, CoreML writes a compiled form of the model (about 43 MB, derived only from the model) to `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`, one copy per model path and macOS build: loading the same model from a second path added another 43 MB, and Saywing does not remove old copies. It appears during loading only; the session adds nothing to it and writes no audio or voice state.
- Diarisation costs CPU next to the two speech transcribers. It must be measured in the 60-minute gate of ADR 0006.
- The project's own LS-EEND documentation states recordings up to one hour. Transcripts may run two hours; the second hour must be checked in the gate.
- Speaker voices are biometric data under GDPR Art. 9 as soon as they are used to identify someone. Saywing does not identify anyone, keeps nothing, and the user names voices by hand. This belongs in the legal review that ADR 0006 already makes a release gate.

## Model decision — 2026-11-04

Public builds carry the DIHARD III variant (`dih3`, up to 10 speakers), by maintainer decision, deliberately without external counsel and without written answers from LDC or the authors.

- **Why this variant:** it separated the most readers in the measurements below. AMI has the least burdened last training stage but no clean chain, and it measured weakest with three and five readers.
- **What the analysis of 2026-11-04 found (not legal advice):** no variant is free of LDC data, because all share the pretraining above; the LDC agreements do not settle whether trained weights are covered; and the authors' MIT grant does not explicitly name the weights. It recommended asking LDC and the authors in writing before bundling. The maintainer decided to go ahead and accepts this risk.
- **If a rights holder objects:** turn `SAYWING_BUNDLE_DIARIZATION_MODEL` off and publish a new release. Without the model the others stay "Others", and nothing else depends on it.

## Open

- **Real calls.** Recorded multi-speaker calls are still missing; the numbers below are read speech only. Similar voices and short turns can be confused.

## Validation gates

- Real calls with 2, 3 and 5 remote participants:
  - wrongly attributed words;
  - voices split or merged;
  - latency of labels.
- CPU and memory over 60 and 120 minutes with both transcribers running.
- A file-system check that no audio or model state is written during a session.
- License chain of the bundled variant, including its training datasets, before a public release.

## Verification so far

- Unit tests cover voice assignment, numbering, renaming and merging, the voice tracker's queueing and late-result handling, the save panel's format menu, and the Markdown, text and PDF export. One test runs synthetic speech of three voices through Apple's recognizer and the voice tracker, with a stand-in diarizer that knows who spoke, and checks that a named voice reaches the saved PDF.
- Echo on "Me" (found in a call over laptop speakers, 2026-10-21): a segment of "Me" now counts as an echo when at least three of its words with three or more letters exist and 60 % of them sound like words the others said at the same moment. The signal threshold of the echo gate is now 0.12, measured with synthetic speech in a simulated room: different voices reached at most 0.085, a quiet, reverberant, distorted echo at least 0.14. A real room measurement with laptop speakers and microphone is still open.
- Adapter (2026-11-04, Apple M4 unless noted): `LSEENDMeetingDiarizer` keeps one resampler per stream, because FluidAudio's `sourceSampleRate:` restarts its converter on every chunk. It keeps no frames or segments and reports a voice still speaking once a second. The tracker releases it on finish, cancel and failure. A model that will not load reports through the existing "no longer told apart" path.
- The opt-in test suite (`TEST_RUNNER_SAYWING_DIARIZATION_MODELS=<folder>`) uses the committed fixtures, A-B-A with 28.9 s of two readers, one female, one male, read speech at the model's own 8 kHz: both readers got their own voice in all three variants, with 100 % of attributed time correct. Time attributed: AMI 95 %, CALLHOME 88 %, DIHARD III 86 %. The same audio at 48 kHz through the tracker gave the same result.
- **That suite also has a failing test.** Three synthetic system voices (Anna, Eddy, Flo), two turns each: no variant separates them. CALLHOME and DIHARD III hear Anna and Flo as one voice (67 % correct), AMI confuses more (61 %). The test stays red; the bar of 80 % was set before measuring.
- Further readers, measured locally and not committed: public-domain LibriVox readers of the same project, in turns without overlap, levelled to the same loudness. Each cell: share of attributed time correct, with readers and voices paired one to one. `X` means fewer voices than readers were found.

  | Readers | Turn | AMI | CALLHOME | DIHARD III |
  |---|---|---:|---:|---:|
  | Elli, Karlsson (F, M) | 15 s | 99.6 | 99.5 | 99.7 |
  | Elli, Jessi (F, F; similar pitch) | 15 s | 50.6 X | 80.2 | 52.0 X |
  | Renate, Crln (F, F) | 15 s | 95.6 | 98.7 | 90.6 |
  | Petra, Julia (F, F) | 15 s | 98.8 | 96.8 | 98.1 |
  | Karlsson, Bjoern (M, M) | 15 s | 99.3 | 99.1 | 99.5 |
  | Elli, Renate, Karlsson | 15 s | 66.7 | 99.4 | 99.1 |
  | Petra, Crln, Bjoern | 15 s | 99.4 | 99.2 | 99.1 |
  | Five readers | 15 s | 79.9 X | 82.3 X | 98.9 |
  | Elli, Karlsson | 5 s | 97.8 | 98.0 | 98.3 |
  | Elli, Jessi | 5 s | 50.9 X | 51.4 X | 52.2 X |
  | Renate, Crln | 5 s | 79.1 | 94.5 | 62.8 |
  | Petra, Julia | 5 s | 94.9 | 92.4 | 94.5 |
  | Karlsson, Bjoern | 5 s | 95.7 | 97.1 | 98.4 |
  | Elli, Renate, Karlsson | 5 s | 77.8 | 97.7 | 97.6 |
  | Petra, Crln, Bjoern | 5 s | 97.4 | 97.9 | 97.9 |
  | Five readers | 5 s | 59.9 X | 79.2 X | 79.8 X |

  Similar voices can merge, short turns are harder, and five readers were separated only once. These rows do not predict a real call: they have no call codec, no overlap and no interruptions.
- Cost, one model in a standalone Release program: load 0.35 s cold, 0.03 s with CoreML's cache; about 1.1 % of real time on one core; about 8 to 16 MB of footprint for the model. Labels arrive a median of 0.92 s and at most 1.62 s after the audio. Two hours of three alternating readers (DIHARD III, 30 s turns) with network denied: 99.2 % correct overall and 99.2 % in the last quarter, 4 voices used, footprint flat (708 to 711 MB, almost all of it the program's own copy of the audio).
- x86_64: the same real-model tests give the same results under Rosetta (real-time factor about 0.05 in a Debug build). No physical Intel Mac was measured.
- A Hardened Runtime signature (ad hoc) with the app's entitlements loads and runs the model, and `codesign --verify --deep --strict` seals the `.mlmodelc`; no file in it is Mach-O. Developer ID signing and notarization with the model have not been run.
- Not verified: real calls, the gates below, CPU next to both recognisers, a signed app with the model running a live transcript, and a per-process trace of file writes. The disk check compares folders: the app's caches after loading, FluidAudio's folder, and audio files in the temporary folder, which other processes share.
