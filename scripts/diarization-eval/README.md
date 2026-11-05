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
- `score.py`, `evaluate.py`: scoring and the run wrapper. `explore.py`: offline
  exploration of post-processing rules on dumped model output (dev only).

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
| `clean8` | the mix at the model's 8 kHz |
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
python3 evaluate.py --work $W --split dev --label baseline --model <ls_eend_dih3_100ms.mlmodelc>
```

**Run the harness in a normal shell.** When CoreML cannot create its cache folder
(`~/Library/Caches/diarization-eval`, for example inside a sandboxed shell), it
falls back to another CPU path whose output differs between processes: the same
audio gave different voices from one run to the next, and about one process in
four heard everyone as one voice. With a writable cache, repeated runs were
bit-identical. `--diagnose <wav>` prints checksums of the features and the model
output to check this. The app has a writable cache folder.

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

## Results (2026-11-05, Apple M4, DIHARD III variant)

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

Test-split runs: `baseline` and `floorbg`, both with manifest SHA-256
`31fc09f3…eefdd2ba1`. The third allowed run was not used.
