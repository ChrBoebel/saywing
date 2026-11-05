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
