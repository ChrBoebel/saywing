# Reproducible Python worker runtimes

Saywing's dictation worker (`Runtime/Dictation/worker.py`) and Supertonic speech worker
(`Runtime/Supertonic/worker.py`) run in bundled CPython interpreters. Both are built by
`scripts/build-python-runtime.py` from pinned, hash-verified inputs. Network access is used
**only while building**; the app never downloads or installs Python packages.

## Inputs

| Input | Pin |
| --- | --- |
| CPython | 3.12.15, python-build-standalone release 20261013, `install_only_stripped`; URL, size and SHA-256 per architecture in `Runtime/Portable/python.json`; source commit, recipe, patches and archive checks in `Runtime/Portable/python-provenance.json` ([Interpreter provenance](research/interpreter-provenance.md)) |
| Dictation, Apple Silicon | `Runtime/Dictation/requirements-lock.txt` (24 packages) |
| Dictation, Intel | `Runtime/Dictation/requirements-lock-x86_64.txt` (NumPy 2.2.6, SciPy 1.17.1; recognition uses the whisper.cpp bridge, `scripts/build-whisper-cpp.sh`) |
| Speech, both architectures | `Runtime/Supertonic/requirements-lock.txt` (NumPy 2.2.6, ONNX Runtime 1.23.2) |

Each lock pins exact versions with SHA-256 hashes of the macOS 14 wheels. The builder
installs them with `pip --require-hashes --no-deps --only-binary :all:` and explicit
`--platform macosx_14_0_<arch>` tags, so a newer build host cannot select wheels that need
a newer macOS. `mlx-whisper` stays at 0.4.3 because `scripts/patch-dictation-runtime.py`
is gated on that release's exact `transcribe.py` SHA-256.

### Why these packages

The locks contain only what the workers import, not the packages' declared dependency
closures (installed with `--no-deps`):

- A real Whisper Turbo transcription with the previous runtime, recording `sys.modules`,
  imported only: MLX, mlx-metal, mlx-whisper, NumPy, SciPy, tiktoken, regex, tqdm,
  huggingface_hub and its HTTP stack (httpx2, httpcore2, anyio, h11, idna, truststore,
  charset-normalizer), PyYAML, filelock and typing_extensions.
- The Qwen3-ASR path additionally needs mlx-audio, Transformers, tokenizers and packaging.
  Transformers refuses to import without the `safetensors` distribution, so it stays even
  though it is not imported.
- A real Supertonic synthesis imported only NumPy and ONNX Runtime; ONNX Runtime's other
  declared dependencies (coloredlogs, flatbuffers, protobuf, sympy, ...) are for its tools.

Not shipped any more: torch, numba/llvmlite (only used for word timestamps, which Saywing
disables), fsspec, hf-xet, requests, soundfile/libsndfile, sounddevice, miniaudio, pip,
setuptools, the unrelated document/image tool chain that came with a copied prototype
environment (including the non-redistributable `artifact_tool_v2` with `node_modules/@oai`),
and duplicate NumPy installs. That prototype environment was only in private builds 1–5; the
published 0.1.17 betas used the later portable runtime and do not contain it (checked on the
served DMGs, see the addendum in
[ADR 0007](decisions/0007-gcc-runtime-libraries.md#addendum-2026-10-25-the-2026-10-15-beta-builds)).

## Build

Prerequisites: macOS, `/usr/bin/curl`, a host Python 3.11+ with pip (it only downloads and
unpacks wheels; it never runs inside the app). Rosetta is needed only to *test* Intel
runtimes on Apple Silicon. Output directories must be new.

```sh
python3 scripts/build-python-runtime.py --runtime dictation --architecture arm64  --cache .build/runtime-cache --output .build/runtime/dictation-arm64
python3 scripts/build-python-runtime.py --runtime dictation --architecture x86_64 --cache .build/runtime-cache --output .build/runtime/dictation-x86_64
python3 scripts/build-python-runtime.py --runtime speech    --architecture arm64  --cache .build/runtime-cache --output .build/runtime/speech-arm64
python3 scripts/build-python-runtime.py --runtime speech    --architecture x86_64 --cache .build/runtime-cache --output .build/runtime/speech-x86_64
```

Hosts contacted: `github.com` (redirecting to `release-assets.githubusercontent.com` /
`objects.githubusercontent.com`) for CPython, `pypi.org` and `files.pythonhosted.org` for
wheels. If pip cannot reach the macOS trust store (seen in sandboxed shells as
`OSStatus -26276`), set `PIP_USE_DEPRECATED=legacy-certs`; integrity still comes from the
pinned hashes.

The builder:

1. downloads CPython over HTTPS and verifies size and SHA-256 **before** extracting
   (path-traversal and external-symlink checks as in `scripts/portable_runtime.py`);
2. removes pip/ensurepip, the test suite, IDLE, tkinter with Tcl/Tk, dbm, lib2to3, headers,
   man pages, static `config-3.12-darwin` files and every executable except `python3`;
3. installs the hash-locked wheels into `site-packages`, removes console scripts and
   bytecode (workers run with `-B`); package directories are otherwise unchanged
   (SciPy 1.17 imports `numpy._core.tests`, so test packages are not pruned);
4. fails if the installed set differs from the lock, or on forbidden content:
   `artifact_tool*`, torch, pip/setuptools/wheel, or any `@oai` or `node_modules` path;
5. writes `installed-packages.json` (name, version, license, license-file and vendored
   native-library paths relative to the runtime, wheel SHA-256, PyPI source page; it fails
   on any absolute path), `THIRD-PARTY-NOTICES.txt` (CPython and its components from
   `docs/licenses/Python-3.12.15*`, every package's license files, upstream texts from
   `docs/licenses` where a wheel ships none, and a copyleft/source-availability section) and
   `runtime-provenance.json` (lock hash, CPython pin, the interpreter's python-build-standalone
   commit and full-archive hash, pip version, native audit). The build stops if
   `Runtime/Portable/python-provenance.json` does not describe the pinned archive;
6. audits every Mach-O file for the target architecture, macOS 14 minimum and no
   non-system absolute load paths.

To change a version, edit the pin and refresh hashes (this re-resolves the macOS 14 wheels):

```sh
python3 scripts/build-python-runtime.py --runtime dictation --update-hashes --cache .build/runtime-cache
```

Then rebuild and commit the regenerated `Runtime/Dictation/installed-packages.json`
(copy it from the arm64 dictation output). New versions without an SPDX expression fall
back to their metadata license until added to `REVIEWED_LICENSES` after review.

## Bundle

`scripts/bundle-dictation-runtime.py` accepts only such a runtime as `RESOURCES/Python`:
it re-runs the forbidden-content and inventory checks, requires the runtime inventory to
equal the committed `Runtime/Dictation/installed-packages.json`, copies it and
`THIRD-PARTY-NOTICES.txt` (plus the Google FLEURS CC BY 4.0 attribution for the demo clips)
into `Dictation/`, and applies the mlx-whisper hardened-runtime patch. A copied prototype
environment is rejected (for example `Forbidden package: torch-2.14.1.dist-info`).
`--development-only` and `--public-release` select the receipt wording; `scripts/release.py`
passes `--public-release` for public releases. The speech side is checked for the same
forbidden content when reused with `--speech-from`.

For local development speech, install the built speech runtime with
`ruby scripts/install-supertonic-runtime.rb VERIFIED_COMPARISON_ROOT .build/runtime/speech-arm64`.

## Release input and CI

`scripts/assemble-release-runtime.py` produces the complete runtime input for
`scripts/release.py --runtime-app` from public sources only:

```sh
python3 scripts/assemble-release-runtime.py --architecture arm64  --public-release --cache .build/runtime-cache --output .build/runtime-arm64/Saywing.app
python3 scripts/assemble-release-runtime.py --architecture x86_64 --public-release --cache .build/runtime-cache --output .build/runtime-x86_64/Saywing.app
```

It first downloads every input into the content-addressed cache (file name = SHA-256)
and verifies size and SHA-256 before anything is built or unpacked:

| Input | Source | Pin |
| --- | --- | --- |
| Supertonic 3 model and voices | `huggingface.co/Supertone/supertonic-3` | `docs/research/supertonic-comparison-manifest.json` (revision, size, SHA-256 per file) |
| Supertonic `helper.py`, `LICENSE`, `README.md` | `raw.githubusercontent.com/supertone-inc/supertonic` | `Runtime/Portable/release-inputs.json` (helper cross-checked with the model manifest) |
| Whisper Turbo MLX 4-bit (arm64) | `huggingface.co/mlx-community/whisper-large-v3-turbo-4bit`; OpenAI and Apache license texts from their recorded URLs | `Runtime/Dictation/whisper-turbo-manifest.json` |
| Whisper Turbo GGML q5_0 (x86_64) | `huggingface.co/ggerganov/whisper.cpp` | `Runtime/Portable/whisper-turbo-cpp-manifest.json` |
| whisper.cpp 1.9.5 source (x86_64) | `codeload.github.com` | `Runtime/Portable/whisper-cpp-source.json` |
| FLEURS demo clips | `test.tar.gz` archives of `huggingface.co/datasets/google/fleurs`; only the two listed members are read | archives in `Runtime/Portable/release-inputs.json`, clips in `Runtime/Dictation/demo-manifest.json` |

Then it builds both worker runtimes with `scripts/build-python-runtime.py`, and assembles
`Contents/Resources` of a new `Saywing.app`:

- `Speech/`: the speech runtime as `SupertonicRuntime/python`, the project worker, helper,
  model manifest and `DevelopmentModels/supertonic-3-3cadd1ee`, with an integrity receipt;
- `Dictation/`: on arm64 written by `scripts/bundle-dictation-runtime.py` (inventory check,
  hardened-runtime patch, receipt) into a staging bundle; on Intel the dictation runtime,
  the GGML model, the whisper.cpp bridge built by `scripts/build-whisper-cpp.sh` with its
  build provenance, `runtime-backends.json` (`whisper-turbo` only), notices and receipt;
- `portable-runtime.json`, `LICENSE-Saywing`, and a native audit of every Mach-O file
  (architecture, macOS 14, no external load paths).

Source archives for the GNU and MPL-2.0 components
(`docs/licenses/native-corresponding-sources.json`) are not release inputs. The app carries
exact pointers, including the public copy on the download host, and a written offer; the
publish job archives the files and verifies that they are publicly downloadable
([ADR 0007](decisions/0007-gcc-runtime-libraries.md)).

Inputs come to about 2 GB per architecture, mostly the two models and the FLEURS archives
(860 MB for two clips of 1.8 MB; the dataset publishes audio only as archives).
Additional hosts beyond the runtime build: `huggingface.co` (redirecting to its CDN),
`raw.githubusercontent.com`, `codeload.github.com` and `www.apache.org`. Intel needs CMake.

**CI.** The `package` job of `.github/workflows/release.yml` runs this for each matrix
architecture (arm64; x86_64 only with `SAYWING_INTEL_RELEASE_ENABLED`) through
`scripts/prepare-release-ci.py runtime`, after the release-approval gate, into
`$RUNNER_TEMP/saywing-runtime/Saywing.app`, then passes that to `scripts/release.py`.
No private archive, storage credential or secret is involved. The download cache
(`$RUNNER_TEMP/saywing-runtime-cache`) is kept with `actions/cache`, keyed by architecture
and the hash of every pin file. That is safe because all cached content is re-verified
against committed hashes on every use (a modified entry fails the build; pip installs
only `--require-hashes` pins), and the release job runs only from `workflow_dispatch` on
`main`: caches written by pull-request runs belong to their merge refs and are never
restored on `main`.

## Verification, 2026-10-23

Built on Apple Silicon (macOS 26) from the pins above. Sizes compared with the earlier
runtimes:

| Runtime | Before | Now |
| --- | --- | --- |
| Dictation arm64 | 1.4 GB (copied prototype; installed portable candidate 1.1 GB) | 385 MB |
| Dictation x86_64 | — | 145 MB |
| Speech arm64 | 174 MB | 128 MB |
| Speech x86_64 | — | 141 MB |

- `Tests/Dictation/test_worker.py` (20 tests) passed with the arm64 and, under Rosetta, the
  x86_64 dictation runtime; `Tests/Fixtures/test_supertonic_worker.py` (9 tests) passed with
  both speech runtimes.
- Real Supertonic synthesis through the worker's session protocol (German and English) with
  both speech runtimes; x86_64 under Rosetta, which is not evidence for Intel hardware.
- The dictation runtime, after bundling (patch applied), verified the bundled Whisper Turbo
  model with the worker's own verifier, resampled the FLEURS clip with SciPy, built the
  Whisper tokenizer with tiktoken, imported the complete mlx-whisper and mlx-audio Qwen
  loader paths, and ran the Qwen3-ASR tokenizer and Whisper feature extractor from the
  installed model without torch.
- No `artifact_tool*`, `@oai`, `node_modules`, torch, numba, pip or Tcl/Tk in any output.

**Verification, 2026-11-04 (real MLX transcription).** Run against the signed, notarized public release 0.1.30 (build 130, CDHash `a1a4d8e6…`), unmodified, on an Apple M4 Mac with 16 GB and macOS 26.6.2. The bundled Python ran `worker.py --model whisper-turbo` through `sandbox-exec` with the app's profile (byte-identical to the one in the signed binary) and the app's arguments and environment, driven by a script instead of the Swift app. Synthetic `say` clips (Anna de_DE and Samantha en_US, mono Float32 at 48 kHz) returned "Guten Morgen, das ist ein Test der lokalen Spracherkennung." and "Good morning. This is a test of local speech recognition." in all three runs, exit status 0. Load to `ready` took 2.1–2.7 s; the first request per process took 8.5–13 s (cause not established), later requests about 1.1 s with explicit language and about 2.2 s with auto-detect; peak memory footprint was about 1.4 GB. Metal use was observed: `Device(gpu, 0)` under the same profile, and the worker's own GPU client accumulated about 3 s of GPU time. `Tests/Dictation/integration_worker.py` passed 14/14 against the same runtime, including the denied network, write, spawn and outside-read checks and cancellation in 0.10 s. Not covered: the Swift app path, microphone audio, UI and paste, Intel, and the optional Whisper Large v3 and Qwen3-ASR models.

To repeat the integration check on an Apple Silicon Mac with a bundled app (MLX needs a Metal device):

```sh
python3 Tests/Dictation/integration_worker.py /path/Saywing.app/Contents/Resources/Dictation /tmp/saywing-check whisper-turbo
```

(`integration_worker.py` itself reads the demo WAVs with `soundfile`; run it with a Python
that has NumPy and soundfile, not the bundled worker runtime.)
