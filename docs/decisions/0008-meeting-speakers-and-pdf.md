# ADR 0008: Telling meeting speakers apart, and PDF export

- Status: accepted. The runtime adapter is integrated and pinned. By maintainer decision of 2026-11-04, public builds were to carry the LS-EEND DIHARD III variant (see "Model decision"); release 0.1.30 does not carry it. Since 2026-11-07 the code uses Nemotron 3 Diarization instead; that model change is **pending the maintainer's license decision** (see "Model change"), and until it is recorded a public build with the model stops at the release gate.
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
   - The model is NVIDIA's Nemotron 3 Diarization (since 2026-11-07, pending the license decision under "Model change"; before, LS-EEND), a streaming end-to-end model as CoreML export. It needs no separate embedding or clustering step and tracks up to 8 speakers at 10 ms.
   - The runtime is FluidAudio's `Nemotron3Diarizer`, in the app's own process, on the Neural Engine where the Mac has one, not in the sandboxed Python worker.
   - Voices are shown as "Speaker 1", "Speaker 2" and so on, numbered in the order they first speak.
2. **No audio kept for diarisation.**
   - The audio is fed in as it arrives and discarded, like the recogniser's input.
   - An offline pass after Stop (pyannote Community-1) would need the whole track in memory: about 230–460 MB for two hours. It was rejected for that reason.
3. **Names come only from the user.**
   - A click on a speaker label renames that voice in every turn and in the export.
   - Two voices can be merged when the model split one person.
   - One turn can be given to another voice or to a new person when the model heard two people as one (added 2026-11-06, after the speaker-split evaluation below showed that most errors are merged voices and that post-processing cannot split them). The correction is a time range and a voice; it wins over every span the model reports for that range, then or later.
   - Names, merges and corrected turns live only in memory with the transcript.
4. **No voice profiles.**
   - Saywing never stores speaker embeddings, attractors or the model's speaker cache.
   - It never recognises a person across meetings and never tries to identify anyone.
   - Model state dies with the transcript.
5. **Assignment.**
   - Recognised words carry audio time ranges. Each word of "Others" goes to the voice that spoke most during it, unless the user gave that moment to a voice by hand.
   - A change of voice starts a new turn.
   - Words without a voice stay "Others".
6. **Fallback.** If the model is missing or fails, the transcript works as before with "Others". The window says once that voices are not told apart: without a model when the others first speak, after a failure in the failure notice.
7. **PDF export.**
   - Save offers PDF (first), Markdown and plain text.
   - The PDF is laid out on A4 with Core Text.
   - It is tagged (heading and paragraphs) so screen readers can follow it.
   - Its document info holds only the title and "Saywing".
   - Writing still happens only through the explicit save panel.
8. **Honest labels** (added 2026-11-06). Telling voices apart is experimental. The first time a voice appears in a transcript, the footer says once, without a dialog, that voices are told apart automatically, may be mixed up, and can be corrected with a click on a name.

## Model and code

| Item | Value |
|---|---|
| Model | Nemotron 3 Diarization, preset set only by `bundled_preset` in the manifest: `fast` (fp16, 0.72 s of audio per step, 1.04 s input latency, FIFO of 40 frames), 16 kHz input, 8 speaker slots, 10 ms output |
| Source | `FluidInference/nemotron-3-diarization-coreml`, revision `25a90f97f254428d4b30374b76af9c74fdee8327`, folder `monolithic/v2/` |
| Upstream | [nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization), revision `f667ed73aee57d40cc39428eb768b4fd87a0a29e` (Streaming Sortformer with an arrival-order speaker cache) |
| License | [OpenMDW License Agreement 1.1](https://openmdw.ai/license/1-1/), granted by NVIDIA for the weights; the CoreML card states that the converted weights carry the same license. It requires shipping the agreement and the notices of origin; neither repository has a separate NOTICE file. Notice: `docs/licenses/Nemotron-3-Diarization-OpenMDW-1.1.txt`, shipped as `Diarization/LICENSE-Nemotron-3-Diarization.txt`. |
| Training data | About 10,000 hours of real conversations (Fisher English Parts 1-2, AMI, ICSI, VoxConverse, AISHELL-4, DIHARD III Dev, CALLHOME Part 1 of NIST SRE 2000, AliMeeting, DiPCo, NOTSOFAR1, DISPLACE, David AI data licensed under agreement, a pseudo-labelled YODAS-v2 subset) and 82,611 hours of simulated mixtures from LibriSpeech, AMI, AliMeeting, Fisher English and David AI, with MUSAN noise. Fisher English, DIHARD III and CALLHOME are Linguistic Data Consortium corpora. Datasets keep their own terms. |
| Size | 199.1 MB (`weights/weight.bin` 198.6 MB, graph 0.5 MB, silence embedding 2 KB) |
| Hashes | Every file of the measured presets (`fast`, `fast32`, `fast32-split-w8a8`) is pinned in `Runtime/Diarization/nemotron-3-manifest.json` with size and SHA-256 |
| Runtime code | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.2 (revision `e396cf780c4abf8e395087467c0585d3b0d17f68`), Apache-2.0, exact-version reference with `traits = (Diarizer)` in the Xcode project. Linked with it: `FastClusterWrapper` (fastcluster, BSD 2-Clause), `MachTaskSelfWrapper`, and VBx-derived clustering (Apache-2.0). Not linked: TTS code, G2P resources, the prebuilt NeMo binary. Notices: `docs/licenses/FluidAudio-0.18.2.txt`. |
| Delivery | Only in builds that carry it: `scripts/release.py --diarization-model`, which the release workflow passes only when the repository variable `SAYWING_BUNDLE_DIARIZATION_MODEL` is exactly `true`. A public build with it also needs `voice_model_license_review` for exactly this model and revision in the release approval (not recorded). Never downloaded at runtime. Weights are not committed to Git. |

Earlier model (until 2026-11-07): LS-EEND, `FluidInference/ls-eend-coreml` revision `28ce1b1f8ef186729df63b3886fbaae7bc10c4a1`, 44.6 MB per variant, MIT as published by the exporter, pretrained on Switchboard, Switchboard Cellular and NIST SRE 2004–2008 (LDC) with MUSAN noise and fine-tuned on AMI, CALLHOME, DIHARD II or DIHARD III. Its manifest, notice and state check were removed with its adapter; they are in the history up to commit `96925ef`.

## Consequences

- One new third-party Swift package in every build: about 7.3 MB more binary (Apple Silicon: 4.85 to 12.10 MB). A build with the model is about 199 MB larger on top (LS-EEND: 43.6 MB).
- No new network path. The model is loaded from the app bundle with `Nemotron3Models.load(config:directory:)`. FluidAudio's download code (`ModelHub`, `AssetDownloader`, `URLSession`) is linked but never called; the one file that imports FluidAudio sets `ModelHub.offlineMode`, which makes those paths throw, and a release test rejects download helpers in app sources. A run with all network denied by `sandbox-exec` works.
- Resolving packages also downloads the unused `NemoTextProcessing` binary artifact at build time, because SwiftPM fetches declared binary targets regardless of traits. It is checksum-pinned by FluidAudio and is not linked.
- On the first load, CoreML compiles the model for the Neural Engine (about 6.5 s) and writes a compiled form (about 1.1 MB, derived only from the model) to `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`, one per model path and macOS build. Later loads take under 0.1 s. It appears during loading only; the session adds nothing to it and writes no audio or voice state.
- Because the first load takes seconds, the model loads in the background from the consent step on and is freed when the window closes before a transcript. A transcript never waits for it: up to 30 s of the others' audio waits in RAM and gets its voices once the model is ready.
- Diarisation runs on the Neural Engine, next to the two speech transcribers. It must be measured in the 60-minute gate of ADR 0006. On Intel Macs (and under Rosetta) CoreML has no Neural Engine and uses GPU and CPU; the bake-off measured `fast32` under Rosetta on the M4 about 5 to 8 times slower than native, still well under real time.
- The model's memory of voices is a fixed-size speaker cache, so it does not grow with the meeting; the second hour must still be checked in the gate.
- Correcting the model is manual. The window offers "Rename…", "Same Person As ▸" (merge two voices) and "Different Person ▸" (move one turn to another voice or a new person). A turn holds all words of one voice until someone else speaks, so two people the model merged who speak back to back stay one turn and move together.
- Speaker voices are biometric data under GDPR Art. 9 as soon as they are used to identify someone. Saywing does not identify anyone, keeps nothing, and the user names voices by hand. This belongs in the legal review that ADR 0006 already makes a release gate.

## Model decision — 2026-11-04 (LS-EEND)

Public builds carry the DIHARD III variant (`dih3`, up to 10 speakers), by maintainer decision, deliberately without external counsel and without written answers from LDC or the authors.

- **Why this variant:** it separated the most readers in the measurements below. AMI has the least burdened last training stage but no clean chain, and it measured weakest with three and five readers.
- **What the analysis of 2026-11-04 found (not legal advice):** no variant is free of LDC data, because all share the pretraining above; the LDC agreements do not settle whether trained weights are covered; and the authors' MIT grant does not explicitly name the weights. It recommended asking LDC and the authors in writing before bundling. The maintainer decided to go ahead and accepts this risk.
- **If a rights holder objects:** turn `SAYWING_BUNDLE_DIARIZATION_MODEL` off and publish a new release. Without the model the others stay "Others", and nothing else depends on it.

## Model change — 2026-11-07, pending the maintainer's license decision

Proposal: replace LS-EEND with NVIDIA's Nemotron 3 Diarization (preset `fast`). The code, the manifest and the notice are in place. **No license decision is recorded.** Until the maintainer records one (`voice_model_license_review` in the release approval, for model "Nemotron 3 Diarization" and revision `25a90f97…`), `scripts/release.py --public-release --diarization-model` stops before building; with `SAYWING_BUNDLE_DIARIZATION_MODEL` still `true`, the next public release fails until the decision is recorded or the variable is turned off.

- **Why:** on the dev split of the evaluation it is better than LS-EEND in every group and condition (all runs 96.4 % correct and the exact voice count in 93 % of runs, against 89.7 % and 71 %); on the test split, run once afterwards, 94.9 % and 94 % against 84.2 % and 57 %, with the largest gains for similar voices and short turns (details under "Verification so far"). It tracks up to 8 voices with a 1.04 s input latency.
- **Configuration**, chosen on dev with a rule written down before (harness README): highest correct share; within 0.5 points the lower label lag wins, then the smaller model; label-lag median at most 2 s. `fast32` fp16 had the highest share (96.6 %), `fast32-split-w8a8` (96.5 %, 102 MB) and `fast` fp16 (96.4 %) were within 0.5 points; `fast` has the lowest label lag (median 0.33 s against 0.52 s). FluidInference publishes no W8A8 build of `fast`. The W8A8 build would halve the size but also takes 22 s instead of 6.5 s for its first load.
- **License and data, for the decision (not legal advice):** OpenMDW-1.1 is a permissive grant by NVIDIA, which permits commercial use and redistribution if the agreement and the notices of origin are kept; it has a patent-litigation termination clause and leaves clearing third-party rights to the user. NVIDIA, a large rights holder, is the licensor of the weights, unlike LS-EEND, where the authors never confirmed that MIT covers the checkpoints. The training data still include Linguistic Data Consortium corpora (Fisher English, DIHARD III, CALLHOME), so the open question of whether LDC terms reach trained weights is comparable to LS-EEND's; the data also include David AI recordings "licensed under agreement" to NVIDIA. The grant covers no dataset.
- **If not approved:** turn `SAYWING_BUNDLE_DIARIZATION_MODEL` off. LS-EEND is no longer in the code; going back means reverting this change.

## Open

- **Real calls.** Recorded multi-speaker calls are still missing; the numbers below are read speech only. Similar voices and short turns can be confused.

## Validation gates

- Real calls with 2, 3 and 5 remote participants:
  - wrongly attributed words;
  - voices split or merged;
  - latency of labels.
- CPU and memory over 60 and 120 minutes with both transcribers running.
- A file-system check that no audio or model state is written during a session.
- License chain of the bundled model, including its training datasets, before a public release (for Nemotron 3: the pending decision under "Model change").

## Verification so far

- Unit tests cover voice assignment, numbering, renaming, merging and moving one turn (to another voice, to a new person, against later spans, with merges and names, in every export format), the one-time notes about voices, the voice tracker's queueing and late-result handling, the save panel's format menu, and the Markdown, text and PDF export. One test runs synthetic speech of three voices through Apple's recognizer and the voice tracker, with a stand-in diarizer that knows who spoke, and checks that a named voice reaches the saved PDF.
- Echo on "Me" (found in a call over laptop speakers, 2026-10-21): a segment of "Me" now counts as an echo when at least three of its words with three or more letters exist and 60 % of them sound like words the others said at the same moment. The signal threshold of the echo gate is now 0.12, measured with synthetic speech in a simulated room: different voices reached at most 0.085, a quiet, reverberant, distorted echo at least 0.14. A real room measurement with laptop speakers and microphone is still open.
### Nemotron 3 Diarization (2026-11-07, Apple M4, macOS 26 build 25G83)

- Adapter: `NemotronMeetingDiarizer` runs FluidAudio's `Nemotron3Diarizer` with compute units `.all` (CoreML's plan: 99.7 % of the cost on the Neural Engine). It resamples to 16 kHz through one long-lived converter, keeps no frames or segments (a unit test feeds 12 minutes and finds none retained), handles 8 voices and reports a voice still speaking once a second. The model's own state (speaker cache of 264 frames, FIFO of 40) has a fixed size. Unit tests cover the manifest lookup, a broken model reporting once through the tracker, the preload (audio from before the model was ready gets its voices, at most 30 s of it, at its meeting time; a load error reports once; releasing cancels the load and frees a loaded or late model; Stop waits at most 30 s), and the controller (the model loads with the consent step, once; closing the window before a transcript and Discard free it; words from before the model was ready get their voices).
- Configuration chosen on dev by a rule written down before (harness README): `fast` fp16. Dev, all 216 runs: 96.4 % correct, exact voice count 93 %, lag median 0.33 s (`fast32` 96.6 % / 93 % / 0.52 s; `fast32-split-w8a8` 96.5 % / 91 % / 0.52 s, 102 MB; LS-EEND 89.7 % / 71 % / 0.91 s). Through the app's adapter the dev run matched the bake-off runner bit for bit.
- Test split, run once with the bundled configuration through the adapter:

  | Test split | LS-EEND dih3 | Nemotron 3 `fast` |
  |---|---:|---:|
  | All 216 runs | 84.2 % / 57 % | 94.9 % / 94 % |
  | 2-3 readers, no similar pair | 91.5 % / 78 % | 98.5 % / 100 % |
  | 2-3 readers with a similar pair | 81.9 % / 58 % | 97.0 % / 100 % |
  | 4-5 readers | 82.8 % / 41 % | 94.9 % / 89 % |
  | Similar pair, any count | 81.3 % / 51 % | 95.8 % / 93 % |
  | System voices | 79.5 % / 64 % | 88.1 % / 89 % |
  | Turns of 1.5-4 s | 73.1 % / 27 % | 94.2 % / 87 % |
  | clean8 / clean48 / call48 (correct) | 83.3 / 82.4 / 86.8 % | 93.2 / 96.0 / 95.5 % |

  Each cell: correct share / exact voice count. Lag median 0.33 s, 90th percentile 1.24 s; real-time factor 0.018; no failures; better by more than a point in 141 runs, worse in 18. The targets (2-3 speakers 95 % and exact count in 90 %; 4-5 speakers and similar voices 85 %) are met on this corpus; system voices stay below. Remaining errors are too few voices (6 % of runs), never too many. The corpus is read speech mixed into conversations, and NVIDIA's training data include LibriSpeech and large amounts of simulated mixtures, so the gain may be smaller on real calls.
- Load: about 6.5 s the first time CoreML sees the model (it compiles it for the Neural Engine and keeps about 1.1 MB in the app's caches), 0.08 s afterwards; 13 s once in the test host next to other tests. The W8A8 build took 22 s cold. Peak footprint while feeding 120-180 MB in the opt-in tests, up to 400 MB in the harness (which holds the whole conversation).
- CoreML's cache: unlike LS-EEND, nothing is updated in place, so the state check was removed. With an unwritable cache folder CoreML takes its other path, which gave the same voices in 5 of 5 processes and the same score, about 3.5 times slower (real-time factor 0.07) and with about 720 MB peak footprint.
- The opt-in suite (`TEST_RUNNER_SAYWING_DIARIZATION_MODELS=<folder>`) passes for `fast`, `fast32` and `fast32-split-w8a8`: both recorded readers get their own voice with 100 % of attributed time correct (also at 48 kHz through the preload and the tracker), the session writes nothing after loading, and **three system voices taking turns, the test that failed with every LS-EEND variant, now pass** (86.7 % correct for `fast`, bar 80 %).
- x86_64: the Release build compiles; under Rosetta CoreML has no Neural Engine and uses GPU and CPU. The bake-off measured `fast32` there with the same result as native on 12 dev runs, at a real-time factor of 0.05-0.08. `fast` under Rosetta and physical Intel Macs were not measured.
- Signing: an ad hoc Hardened Runtime signature with the app's entitlements seals the bundled model (`codesign --verify --deep --strict`); no file in it is Mach-O. A signed app running a live transcript with the model, Developer ID signing and notarization were not run.
- Not verified: real calls, the gates above, CPU and energy next to both recognisers, and a per-process trace of file writes.

### LS-EEND (until 2026-11-07)

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
- Speaker-split evaluation (2026-11-05, Apple M4, DIHARD III, [scripts/diarization-eval](../../scripts/diarization-eval/README.md)): 48 public-domain LibriVox readers (German and English, 12 per language and gender) and 16 macOS system voices, split by speaker into dev and test. 72 seeded conversations per split (2 to 5 speakers, turns of 10-20, 4-8 or 1.5-4 s, similar-voice pairs, up to about 9 % overlap, pauses), each clean at 8 kHz, clean at 48 kHz through the app's resampler, and as a call (300-3400 Hz, AAC at 20 kbit/s, noise at 25 dB SNR). The harness compiles the adapter itself and feeds it in 10 ms chunks. The test manifest was frozen before tuning.

  | Test split, current adapter | Correct | Exact voice count |
  |---|---:|---:|
  | 2-3 readers, no similar pair | 91.5 % | 78 % |
  | 2-3 readers, all | 87.8 % | 70 % |
  | 4-5 readers | 82.8 % | 41 % |
  | Similar pair, any count | 81.3 % | 51 % |
  | System voices | 79.5 % | 64 % |
  | Turns of 1.5-4 s | 73.1 % | 27 % |
  | All 216 runs (dev: 89.7 %, 71 %) | 84.2 % | 57 % |

  None of the targets is met (2-3 speakers 95 % and exact count in 90 %; 4-5 speakers and similar voices 85 %). Label lag stays at a median of 0.91 s (90th percentile 1.51 s), real-time factor about 0.016. Most of the error is voices the model merges: on test, 10.7 of 15.9 points of wrong time lie in turns of readers who got no voice of their own, also across genders. Post-processing of the model output (one voice per frame, smoothing, hysteresis, a minimum speech time before a voice appears) moved dev results by -2.8 to +0.5 points, because the model's probabilities are almost binary. A noise floor under digital silence raised dev from 89.7 % to 92.0 % but held only partly on test (84.2 % to 84.5 %, call audio worse), so it was not shipped. Telling merged voices apart needs more than post-processing of this model; that is a model limit, not a tuning gap.
- The evaluation also found that CoreML without a writable cache folder falls back to a CPU path that mishandles LS-EEND's state, which FluidAudio 0.18.2 updates in place: output differs between processes, and voices are mixed up (60 of 60 fresh processes wrong in a controlled test; in some, every reader became one voice). With the cache, repeated runs were bit-identical. The app can hit this when a new compiled bundle (about 43 MB) has to be written while the disk is nearly full (first transcript, after a macOS update or a model move, after macOS clears Caches) or when the user cannot write `~/Library/Caches/<bundle id>`. Since 2026-11-06 the adapter runs a two-second check at load that compares FluidAudio's in-place path with a copy of the model whose state is fed back separately; if they disagree, the model is refused through the existing failure path and the others stay "Others" instead of getting wrong labels. The real fix belongs in FluidAudio (separate state buffers). The real-model tests and the harness must run where CoreML can write its cache.
- Not verified: real calls, the gates below, CPU next to both recognisers, a signed app with the model running a live transcript, and a per-process trace of file writes. The disk check compares folders: the app's caches after loading, FluidAudio's folder, and audio files in the temporary folder, which other processes share.
