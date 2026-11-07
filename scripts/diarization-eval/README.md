# Diarization evaluation

Measures how well the meeting transcript tells the others' voices apart, with the
app's own adapter (`OpenScreenReaderApp/Meeting/MeetingVoiceDiarizer.swift`) and the
same pinned FluidAudio. A local tool for maintainers: CI never builds or runs it, the
app never calls it, and no audio is committed.

## What is committed

- `corpus.py`, `scenarios.py`, `audio.py`: build the speaker corpus and the seeded
  conversations.
- `manifests/`: the corpus (source URL, reader, licence, SHA-256 of every file), the
  speaker split, and the dev and test conversation manifests with their SHA-256.
  The test manifest was written before any tuning and is not changed afterwards.
- `Package.swift`, `Sources/diarization-eval`: the harness. Its `App-*.swift` files
  are symlinks to the app's meeting sources, so it compiles exactly what ships.
- `score.py`, `evaluate.py`: scoring and the run wrapper.

The LS-EEND-only tools behind the earlier results (`--diagnose`, `--probe`,
`--check`, `--dump` and `explore.py`) were removed with that model on 2026-11-07;
they are in the history up to commit `96925ef`.

## Corpus

48 public-domain LibriVox readers from multi-reader collections ("Sammlung kurzer
deutscher Prosa", "Kinder- und Hausmärchen (1812/15)", "Short Story Collection"),
12 per language (German, English) and gender, one recorded section each, plus 16
installed macOS `say` voices. Gender is estimated from the median pitch (below
165 Hz: male) for readers, and taken from the persona for system voices. Speakers,
not conversations, are split: dev and test never share a voice.

Each split has 60 conversations of readers (2, 3, 4 or 5 speakers; turns of
10-20 s, 4-8 s or 1.5-4 s; 24 with a similar-voice pair of the same gender within
20 Hz median pitch; up to about 9 % overlap; pauses) and 12 of system voices, 1 to
4 minutes each. Every conversation is evaluated in three conditions:

| Condition | Audio |
|---|---|
| `clean8` | the mix at 8 kHz (LS-EEND's own rate; the Nemotron adapter brings it to 16 kHz) |
| `clean48` | the same mix at 48 kHz, through the app's resampler in 10 ms chunks |
| `call48` | 300-3400 Hz band, AAC round trip at 20 kbit/s, pink noise at 25 dB SNR, at 48 kHz through the resampler |

## Running it

Needs Python 3 with numpy and scipy, ffmpeg, Xcode, network access to librivox.org,
archive.org and github.com for the build steps, and about 5 GB under the work folder.
`say` and the AAC encoder need a normal (not sandboxed) shell.

```sh
W=/tmp/claude/diar-eval
python3 corpus.py --work $W build            # downloads and decodes the readers
python3 corpus.py --work $W split            # once
python3 scenarios.py --work $W plan --split dev && python3 scenarios.py --work $W plan --split test   # once
python3 scenarios.py --work $W render --split dev && python3 scenarios.py --work $W render --split test
swift build -c release --scratch-path $W/build
python3 ../fetch-diarization-model.py $W/models/nemotron-3     # the bundled preset; --preset for others
python3 evaluate.py --work $W --split dev --label nemotron --model $W/models/nemotron-3 \
    --binary $W/build/release/diarization-eval
```

`--model` is a folder laid out like the app's Diarization folder, as the fetch
script leaves it; its manifest names the preset. The harness loads the model
through the app's `MeetingVoiceModel.loadDiarizer` before feeding any audio.

**Run the harness in a normal shell**, where CoreML can write its cache folder
(`~/Library/Caches/diarization-eval`). With the cache, repeated runs are
bit-identical. Without it CoreML takes a slower path; for Nemotron that path gives
the same voices (see "CoreML's cache" below), for LS-EEND it did not.

To check that a local corpus matches the committed one, compare `$W/*.json` with
`manifests/` (the manifests store the SHA-256 of every speaker file). `evaluate.py`
refuses a manifest whose hash changed and logs every run on the test split in
`$W/test-runs.log`; it refuses a fourth.

## Metrics

Readers and voices are paired one to one (Hungarian method, most shared time).

- **Correct**: share of the time a voice is reported that falls in a turn of its
  paired reader. Pooled over runs; "Mean" averages per conversation.
- **Coverage**: share of reference speech (voiced frames inside turns) that has a voice.
- **Confusion**, **DER**: as in diarization error rate, without a collar.
- **Exact count**: conversations given exactly as many voices as readers; "Fewer" and
  "More" are the other two cases.
- **Lag**: seconds of audio already fed when a span arrived, minus its end.
- Real-time factor of feeding and the peak physical footprint of the process.

## Results with LS-EEND (2026-11-05, Apple M4, DIHARD III variant)

These are the results of the model the app used until 2026-11-07; Nemotron 3 is
below.

Every run on the test split is listed. Each split has 216 runs (72 conversations in
three conditions). "Correct" is pooled over runs; "Exact" is the share of runs with
exactly as many voices as readers.

**Current adapter** (unchanged from main):

| Group | Dev correct | Dev exact | Test correct | Test exact |
|---|---:|---:|---:|---:|
| All runs | 89.7 | 71 | 84.2 | 57 |
| Readers, 2-3, no similar pair | 95.2 | 87 | 91.5 | 78 |
| Readers, 2-3, all | 94.5 | 84 | 87.8 | 70 |
| Readers, 2-3, similar pair | 93.2 | 81 | 81.9 | 58 |
| Readers, 4-5 | 90.5 | 63 | 82.8 | 41 |
| Readers, 4-5, similar pair | 89.6 | 56 | 80.8 | 44 |
| System voices | 76.7 | 58 | 79.5 | 64 |
| Turns 10-20 s | 95.4 | 82 | 92.3 | 80 |
| Turns 4-8 s | 93.3 | 80 | 87.0 | 60 |
| Turns 1.5-4 s | 88.0 | 60 | 73.1 | 27 |
| clean8 / clean48 / call48 | 89.0 / 88.6 / 91.4 | 68 / 65 / 81 | 83.3 / 82.4 / 86.8 | 53 / 51 / 67 |

Label lag: median 0.91 s, 90th percentile 1.51 s. Real-time factor of feeding: median
0.017 (dev), 0.016 (test). Coverage of voiced reference speech 94.5 % (dev), 92.2 %
(test).

Most of the error is voices the model merges: on test, 15.9 % of attributed time is
wrong and 10.7 points of it lie in turns of readers who got no voice of their own
(dev: 10.4 and 6.3). Merges also happen between readers of different gender and
between system voices more than 40 Hz apart in median pitch.

**Tried on dev** (offline replay of the dumped model output unless noted; all
numbers are "all runs" correct / exact):

| Lever | Dev result |
|---|---|
| Replay of the current rule (check) | 89.6 / 71 |
| One voice per frame (most likely slot above 0.5 or 0.55) | 89.9-90.1 / 71-72 |
| plus a second voice only above 0.6 | 89.7 / 72 |
| Moving average over 3 or 5 frames | 90.0-90.2 / 70-71 |
| Hysteresis 0.55/0.45, 0.5/0.4, 0.6/0.5; longer minimum speech | 89.4-89.9 / 69-71 |
| A voice reported only after 1-3 s of its own speech | 86.9-88.3 / 66-68 |
| Band-limiting the input to 300-3400 Hz or high-pass 150/300 Hz (clean8 only) | -1.7 to +0.7 |
| Noise at fixed SNR 15-35 dB under clean8 | +2.4 to +4.5, plateau 20-30 dB |
| Pitch-based split of a merged voice | not built: on 2-6 s excerpts the pitch estimate of one reader strayed more than 25 Hz from that reader's median in a median of 12 % (up to 55 %) of excerpts |

The model's probabilities are almost binary (0.27 or 0.73), which is why thresholds,
smoothing and hysteresis change little.

**Noise floor in the adapter** (live harness, all 216 runs): white noise 25 dB below
the track's level over the last 10 s, fixed seed; first version always, second
version only what the track's own background (quietest 100 ms of the last 5 s)
lacks.

| Run | Split | All | 2-3, no similar | 2-3, similar | 4-5 | System | call48 |
|---|---|---:|---:|---:|---:|---:|---:|
| Always 25 dB | dev | 91.7 / 77 | 96.4 / 94 | 94.1 / 78 | 90.7 / 68 | 85.1 / 75 | 90.8 / 76 |
| Background-aware | dev | 92.0 / 77 | 96.9 / 93 | 93.9 / 83 | 91.4 / 67 | 84.8 / 75 | 92.1 / 79 |
| Background-aware | **test** | 84.5 / 61 | 91.9 / 72 | 81.5 / 81 | 83.8 / 46 | 79.1 / 64 | 84.9 / 62 |

On test the gain mostly disappeared: per run, 51 conversations-conditions got
better and 46 worse; call audio got worse in 12 runs and better in 4; exact voice
counts for 2-3 readers fell from 78 % to 72 %. It was therefore not shipped. The dev
gain was likely inflated by choosing the best of several variants on a model whose
output reacts strongly to small input changes.

**Other model variants** (2026-11-06, dev split only, all 216 runs, same harness and
adapter; correct / exact):

| Group | DIHARD III (shipped) | CALLHOME | AMI |
|---|---:|---:|---:|
| All runs | 89.7 / 71 | 90.1 / 72 | 79.9 / 51 |
| Readers, 2-3, no similar pair | 95.2 / 87 | 97.1 / 94 | 91.5 / 81 |
| Readers, 2-3, similar pair | 93.2 / 81 | 91.7 / 75 | 81.8 / 78 |
| Readers, 4-5 | 90.5 / 63 | 89.2 / 61 | 78.4 / 29 |
| Similar pair, any count | 91.3 / 68 | 88.0 / 60 | 80.1 / 54 |
| System voices | 76.7 / 58 | 80.3 / 64 | 64.0 / 33 |
| Turns 1.5-4 s | 88.0 / 60 | 89.3 / 70 | 74.6 / 43 |
| clean8 / clean48 / call48 | 89.0 / 88.6 / 91.4 | 89.3 / 89.1 / 92.0 | 78.1 / 77.2 / 84.9 |
| Exact, clean8 / clean48 / call48 | 68 / 65 / 81 | 62 / 64 / 90 | 49 / 49 / 56 |
| Coverage of voiced speech | 94.5 | 97.2 | 96.1 |
| Lag median / 90th percentile (s) | 0.91 / 1.51 | 0.91 / 1.51 | 0.91 / 1.51 |
| Real-time factor, median | 0.0169 | 0.0159 | 0.0155 |

AMI is worse everywhere and finds too few voices in 48 % of runs. CALLHOME is
mixed: better with 2-3 distinct readers, system voices, short turns and call audio,
worse with similar voices (-3.3 points, exact count 60 % instead of 68 %) and 4-5
readers. Per run it was better than DIHARD III in 61 runs and worse in 67 (by more
than 1 point). No variant beat DIHARD III by 3 points across the main groups, so the
last test-split run was not spent on one. The real-time factors of CALLHOME and AMI
were measured while other work ran on the machine (90th percentile 0.021-0.023).

Test-split runs: `baseline` and `floorbg`, both with manifest SHA-256
`31fc09f3…eefdd2ba1`. The third allowed run was not used.

## Nemotron 3: choosing the configuration

**Rule, written down on 2026-11-06 before the measurements below.** The candidates
are Nemotron 3 Diarization in the `fast` or `fast32` streaming shape, each as fp16
or W8A8 if FluidInference publishes that build. They are compared on the dev split
only (all 216 runs, the "all runs" row):

1. The highest "correct" share wins.
2. Candidates within 0.5 points of the highest count as tied. Among tied
   candidates, the lower label lag wins (the harness's lag median, see "Metrics");
   if that ties too, the smaller model wins.
3. A candidate whose label-lag median is above 2 s is out.

Load time does not decide; it is measured and reported next to the result. The test
split is then run once, with the chosen configuration through the app's adapter.

**Dev measurements** (2026-11-06/07, Apple M4, macOS 25G83, FluidAudio 0.18.2,
`FluidInference/nemotron-3-diarization-coreml` revision `25a90f97`, all 216 runs).
The streaming numbers come from the bake-off runner, which feeds exactly like the
harness; the chosen `fast` was then run again through the app's adapter with this
harness and gave the same table bit for bit (96.4 / 93, lag 0.33 / 1.22 s,
real-time factor 0.022). FluidInference publishes no W8A8 build of `fast`.

| Candidate | Size | Correct | Exact count | Lag median / p90 | Real-time factor | Load, empty CoreML cache | Load, warm |
|---|---:|---:|---:|---:|---:|---:|---:|
| `fast32` fp16 | 199.1 MB | **96.6** | 93 | 0.52 / 2.43 s | 0.0095 | 6.6 s | 0.08 s |
| `fast32-split-w8a8` | 102.1 MB | 96.5 | 91 | 0.52 / 2.44 s | 0.0052 | 22.0 s | 0.07 s |
| `fast` fp16 | 199.1 MB | 96.4 | 93 | **0.33** / 1.22 s | 0.0197 | 6.5 s | 0.08 s |
| LS-EEND dih3 (before) | 44.6 MB | 89.7 | 71 | 0.91 / 1.51 s | 0.0169 | | |

All three are within 0.5 points of 96.6, so the lower lag decides: **`fast`**
(the bundled preset). Its time-weighted lag (how late each labelled second got its
label) is 1.17 s median, against 1.79 s for `fast32`.

Load times: one fresh process each, model load until `Nemotron3Models.load`
returned; "empty CoreML cache" is a new `CFFIXED_USER_HOME` with a writable
`Library/Caches` (CoreML compiles the model for the Neural Engine and keeps about
1.1 MB there), "warm" the second and third process with the same cache. The 6 s and
21 s of the bake-off were therefore cold loads. The first load in the Xcode test
host, next to other tests, took 13 s for `fast`.

**Test split, run once** (2026-11-07, third and last allowed run, label
`nemotron-fast`, manifest `31fc09f3…`, the app's adapter with the bundled preset):

| Group | LS-EEND dih3 correct / exact | Nemotron 3 `fast` correct / exact |
|---|---:|---:|
| All runs | 84.2 / 57 | **94.9 / 94** |
| Readers, 2-3, no similar pair | 91.5 / 78 | **98.5 / 100** |
| Readers, 2-3, all | 87.8 / 70 | **97.9 / 100** |
| Readers, 2-3, similar pair | 81.9 / 58 | **97.0 / 100** |
| Readers, 4-5 | 82.8 / 41 | **94.9 / 89** |
| Readers, 4-5, similar pair | 80.8 / 44 | **94.6 / 86** |
| Similar pair, any count | 81.3 / 51 | **95.8 / 93** |
| System voices | 79.5 / 64 | **88.1 / 89** |
| Turns 10-20 s | 92.3 / 80 | **98.4 / 100** |
| Turns 4-8 s | 87.0 / 60 | **96.0 / 97** |
| Turns 1.5-4 s | 73.1 / 27 | **94.2 / 87** |
| clean8 / clean48 / call48 | 83.3 / 82.4 / 86.8 | **93.2 / 96.0 / 95.5** |
| Exact, clean8 / clean48 / call48 | 53 / 51 / 67 | **90 / 96 / 94** |

Lag median 0.33 s, 90th percentile 1.24 s (LS-EEND 0.91 / 1.51 s); coverage of
voiced reference speech 93.9 % (92.2 %); real-time factor median 0.018; no
failures. Per run, Nemotron was better by more than a point in 141 of 216 runs and
worse in 18. Where it errs, it now finds too few voices (6 % of runs: 4-5 readers,
system voices, short turns), never too many. The dev advantage held on test.

## CoreML's cache

**Nemotron 3** (2026-11-06, `fast`, the app's adapter through this harness, six
3-reader dev conversations clean8 plus two call48, one process per run set):
FluidAudio keeps Nemotron's state in Swift arrays and copies it into separate
inputs for every step, with separate output buffers, so nothing is updated in
place. With `Library/Caches` read-only (`CFFIXED_USER_HOME`, as below), CoreML
prints the same `E5RT encountered an STL exception` and takes its other path: 5 of 5
processes gave spans identical to each other and the same score as with the cache
(98.6 % correct, every voice count exact; the spans differ from the cached path in
the last digits only). That path is slower (real-time factor 0.07 instead of 0.02)
and uses more memory (peak footprint about 720 MB instead of 120-180 MB). No guard
is needed, and the app has none.

**LS-EEND**, kept for the record:

FluidAudio's `LSEENDModel` binds every recurrent state output (`enc_kv_new`, ...)
to the very array it passes as the matching input (`enc_kv`, ...), so the model
updates its state in place. CoreML normally runs the model through a compiled
bundle it writes to `~/Library/Caches/<bundle id or process name>/com.apple.e5rt.e5bundlecache/<macOS build>/`
(43 MB per model). That path handles the aliasing. When the bundle cannot be
written, CoreML prints `E5RT encountered an STL exception` and runs another CPU
path, which does not: the speaker probabilities depend on the process. The same
model with separate, fed-back state gives the right answer on that path too
(`--probe`: in-place 5969.98 or 5987.43, separate 5929.94, with the cache 5929.94).

Reproduce without a sandbox: CoreML follows `CFFIXED_USER_HOME`.

```sh
mkdir -p /tmp/claude/rohome/Library/Caches && chmod 555 /tmp/claude/rohome/Library/Caches
CFFIXED_USER_HOME=/tmp/claude/rohome .../diarization-eval --model <mlmodelc> --probe <wav>
```

Measured (2026-11-06, Apple M4, macOS build 25G83), six 3-reader dev conversations,
clean8, one process per run: with the cache, 18 of 18 processes gave identical
spans; without it, 60 of 60 processes gave wrong voices, in two or three discrete
outcomes per conversation (5 voices and 59-93 % correct, or 3-4 voices and 35-47 %
correct; 61.5 % mean against 98.2 %). None collapsed to one voice here; the earlier
sandboxed runs did in about one process of four.

| Cache state | Result |
|---|---|
| `Library/Caches` or `<name>` or `com.apple.e5rt.e5bundlecache` not writable, cold | fallback, wrong |
| Disk full (8 MB volume, 0.8 MB free) | fallback, wrong |
| Warm cache, then made read-only | fine (bundle reused) |
| Warm cache whose bundle files were deleted, folders kept | fine (rebuilt) |
| Cache deleted while a process runs, or between loads | fine (rebuilt at next load) |

A read-only warm cache only lasts until the key changes: a new macOS build or a
model at a new place needs a new 43 MB bundle. The app's guard (2026-11-06, removed with LS-EEND on 2026-11-07) compared,
at load, two seconds of synthetic voices through the in-place path and through a
second copy of the model with separate state (bit-identical with the cache, 0.16 to
0.46 apart without it, for all three variants) and reports the model unavailable
when they differed.
