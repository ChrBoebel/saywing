# Third-party licenses

This folder holds the original license texts and notices for third-party software, models and voices that Saywing builds bundle, plus the source and dependency records used to assemble them. The Saywing source code itself is licensed under the Apache License 2.0; see [`../../LICENSE`](../../LICENSE) and [`../../NOTICE`](../../NOTICE).

## Speech model

- [`SUPERTONIC-MODEL-TERMS.md`](SUPERTONIC-MODEL-TERMS.md) — use-based terms that apply to every build including the Supertonic 3 speech model.
- [`Supertonic-3-Open-RAIL-M.txt`](Supertonic-3-Open-RAIL-M.txt) — the unchanged BigScience Open RAIL-M license of the Supertonic 3 model and voice styles.
- [`DMG-README.txt`](DMG-README.txt) — the `README.txt` in every DMG's `Licenses` folder; it limits Apache-2.0 to the source code and points to the model terms.

## Application and runtime components

- [`Sparkle-2.10.0.txt`](Sparkle-2.10.0.txt) — Sparkle 2.10.0 update framework license and bundled dependency notices.
- [`FluidAudio-0.18.2.txt`](FluidAudio-0.18.2.txt) — licenses of the FluidAudio code linked with only its `Diarizer` trait: FluidAudio and VBx (Apache-2.0), fastcluster (BSD 2-Clause). The separate LS-EEND model and its notice ([`../../Runtime/Diarization/LICENSE-LS-EEND.txt`](../../Runtime/Diarization/LICENSE-LS-EEND.txt)) reach only builds that carry the model ([ADR 0008](../decisions/0008-meeting-speakers-and-pdf.md)).
- [`Python-3.12.15/`](Python-3.12.15/) — CPython 3.12.15 license texts and provenance for the Apple Silicon runtimes.
- [`Python-3.12.15-Intel/`](Python-3.12.15-Intel/) — CPython 3.12.15 license texts and provenance for the Intel runtimes.
- [`GCC-13.4.0/`](GCC-13.4.0/) — GCC 13.4.0 runtime library licenses (GPL-3.0 with the GCC Runtime Library Exception, LGPL-2.1 for libquadmath).
- [`Tokenizers-0.23.3.txt`](Tokenizers-0.23.3.txt) — Apache License 2.0 text for the tokenizers 0.23.3 package.
- [`mlx-examples-MIT.txt`](mlx-examples-MIT.txt) — MIT license from Apple's mlx-examples, used for mlx-whisper.

## Rust components

- [`Rust/`](Rust/) — original license files of the Rust crates compiled into the dictation runtime's Rust extensions.
- [`RustBuild/`](RustBuild/) — Cargo lock files, source records and licenses for tokenizers, safetensors and tiktoken (see its `README.txt`).
- [`RustToolchain/`](RustToolchain/) — Rust compiler standard-library copyright and license texts for each toolchain version used.
- [`rust-dependency-review.json`](rust-dependency-review.json), [`rust-license-coverage.json`](rust-license-coverage.json), [`remaining-rust-scope.json`](remaining-rust-scope.json) — crate inventory, notice coverage and remaining scope records.

## Corresponding sources

- [`CorrespondingSource-README.md`](CorrespondingSource-README.md) — explanation of the source archives shipped with the app and any local modifications.
- [`native-corresponding-sources.json`](native-corresponding-sources.json) — pinned source archives (URL, size, SHA-256) for native libraries such as the GCC runtime.
- [`beta-0.1.17-corresponding-source.md`](beta-0.1.17-corresponding-source.md) — source pointers and written offer for the 0.1.17 betas of 2026-10-15, which predate the offer in the app.
- [`portable-supplement-sources.json`](portable-supplement-sources.json) — source and license records for supplemental runtime packages such as tokenizers and for CPython's bundled dependencies.

Inside the app, these texts are available offline under Settings and in `THIRD-PARTY-NOTICES.html`; see [`../../NOTICE`](../../NOTICE).
