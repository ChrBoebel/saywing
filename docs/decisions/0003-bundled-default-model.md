# ADR 0003: Bundled default speech model

- Status: Accepted, subject to release gates M0, P, and M1
- Date: 2026-09-04

## Context

A separate first-run model download adds a large trust and decision point before the core user benefit. The desired experience is one website download followed by immediate local use after normal macOS installation and permission onboarding.

The current candidate `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit` reports an approximately 1.69 GB payload. Its page reports Apache-2.0 and says it was converted with mlx-audio 0.3.0, but a name and mutable repository branch are not sufficient release provenance.

## Decision

- The macOS MVP release should contain one pinned and verified default model inside the signed application resources.
- Model weights remain outside Git.
- A release staging task uses an immutable allowlist of revisions, files, sizes, and SHA-256 hashes.
- The shipped dependency closure, conversion path, tokenizer, voices, runtime, and model require archived license evidence and an SBOM.
- No model, package, or update download occurs in the MVP runtime.
- The application exposes model name, version, source, size, license, and integrity status without asking the user to select a model.
- The provider architecture continues to support a different model or platform artifact later.

## Release gates

- M0: provenance, dependency, voice-rights, and license approval before weight download;
- P: a minimal hermetic worker signs, notarizes, survives browser quarantine, and runs on a clean Mac without system Python or Homebrew;
- M1: the real packaged model passes German/English fidelity, blinded naturalness, latency, cancellation, memory, privacy, and offline tests.

The mlx-audio v0.3.0 TTS extras include `espeakng-loader`; eSpeak NG is GPL-3.0-or-later. The release must prove that the Qwen path excludes it, replace it, or receive an explicit project-level GPL decision before integration.

## Consequences

- First use is simpler and fully offline.
- The DMG and installed app are large, and full manual upgrades may transfer model data again.
- If a self-contained notarized DMG cannot pass the gates, model delivery returns to an explicit project decision; a PKG or runtime download is not adopted silently.

## Update 2026-10-23: Supertonic 3 is the bundled default

By the project's 2026-09-05 listening decision the bundled default speech model is
Supertonic 3 (`Supertone/supertonic-3`, revision
`3cadd1ee6394adea1bd021217a0e650ede09a323`, voice M1), not the Qwen3-TTS
candidate above. Gate M0 as written was scoped to Qwen-TTS; the Qwen eSpeak NG
question applies only if Qwen-TTS is reconsidered. Qwen remains comparison-only
and is never an automatic fallback.

Supertonic 3 model files and voice styles are licensed under the BigScience
Open RAIL-M License (August 18, 2022), not Apache-2.0. Its pinned license is kept
unchanged in `docs/licenses/Supertonic-3-Open-RAIL-M.txt`; the binding use
restrictions for builds that include the model are in
`docs/licenses/SUPERTONIC-MODEL-TERMS.md`. Every build now bundles both files and
shows them in Settings > Read Aloud > Model Terms and in setup.

None of the following license gates is claimed as passed by this update; each
still needs evidence and a maintainer decision:

- OpenRAIL-M §4(a)/(b) and §5: the use-based restrictions are included as an
  enforceable provision and a copy of the license reaches every recipient, both
  in the app (in place since this update) and in the distributed DMG or other
  download channel (not yet in place);
- third-party notices for the bundled Python/ONNX speech runtime and the
  dictation runtimes are complete and match the shipped files;
- the provenance of the bundled CPython interpreter (source, build, patches and
  licenses) is documented for every architecture;
- upstream Supertonic maintenance has ended (announced 2026-07-23); the
  maintenance risk remains an explicit release decision.

## Update 2026-10-24: status of the license gates

`license_review` stays `false` in both release approvals.

Done:

- **Model terms in the DMG.** `scripts/release.py` puts `SUPERTONIC-MODEL-TERMS.md` and the
  complete Open RAIL-M text beside the app in every DMG. The release stops before building if
  either is missing. The app already showed both.
- **Notices and sources for the rebuilt minimal runtimes.**
  - `scripts/bundle_notices.py` builds the offline notice index from the original notices.
  - It binds the Rust extensions to their reviewed binaries.
  - The source obligations are met by [ADR 0007](0007-gcc-runtime-libraries.md):
    - the SciPy GCC runtime libraries are accepted as separate, replaceable dylibs;
    - the app ships a written offer, exact source pointers and the license texts instead of
      the archives;
    - the publish job archives the exact source files for every published build.

    The first real bucket archive is created by the next publication.
- **Interpreter provenance (2026-10-24).** The gate asks for "source, build, patches and
  licenses". All four are recorded for both architectures in
  `Runtime/Portable/python-provenance.json`; details are in
  [Interpreter provenance](../research/interpreter-provenance.md).
  - **Source:** python-build-standalone tag `20261013` resolves to commit
    `9e40cba825ca0997a01cab9f60a0b15ffb976af2`.
  - **Build:** the recipe files are recorded as git blob pointers at that commit. arm64 is built
    natively on an arm64 macOS runner; x86_64 is cross-compiled on the same runner. Both use
    `pgo+lto`.
  - **Patches:** 20 of the 69 CPython patch files apply to 3.12.15 on macOS. One of them,
    `dont-clear-runshared`, applies to x86_64 only. The dependency versions are recorded with
    their URLs and SHA-256 as declared upstream.
  - **Same build:** each pinned stripped archive and the full archive whose licenses are
    shipped come from the same build. Evidence:
    - both hashes match the release's `SHA256SUMS`;
    - the full archive's `PYTHON.json` shows the pinned version and target;
    - the `_sysconfigdata` files are identical and name the same unique build directory;
    - every stripped file is byte-identical to the full archive's file, or is the same Mach-O
      or PE binary without debug data (same `LC_UUID` and section contents).
  - **Licenses:** the shipped license texts are byte-identical to the full archive's.
  - **Re-check:** `scripts/python_provenance.py` re-runs these checks. A pin change without a new
    record fails the unit tests and the runtime build.

Open:

- **Legal review of the model-terms wording.** The maintainer's legal review of
  `docs/licenses/SUPERTONIC-MODEL-TERMS.md` is still open. It covers how the OpenRAIL-M §4/§5
  use restrictions are passed on as an enforceable provision. This review is why
  `license_review` stays `false`.
- **Upstream maintenance.** Upstream Supertonic maintenance has ended. This is an explicit
  release decision, not a license item, and it is unchanged.

## Update 2026-10-25: license review completed by the maintainer

`license_review` is `true` in both release approvals. The maintainer completed the review
without external counsel, on the basis of written analyses of the Open RAIL-M terms and of
the copyleft obligations, and after these changes:

- explicit in-app acceptance of the model terms, bound to the SHA-256 of the bundled text;
- an equally binding German version of the terms with a translated Attachment A, German law
  with the consumer proviso, and a liability clause within German law;
- corresponding source served publicly next to every download, verified before publishing,
  and LGPL-3.0 for libquadmath ([ADR 0007](0007-gcc-runtime-libraries.md), amendment).

Residual risks the maintainer accepts:

- whether Supertone Inc. can enforce Attachment A directly against end users;
- whether model weights are protected by copyright, which decides whether the terms are
  enforced as a license condition or only as a contract;
- whether the maintainer acts as a business ("Unternehmer") towards consumers;
- the quality of the German translation of Attachment A;
- whether the retroactive LGPL-3.0 election cures the 2026-10-15 betas under German law;
- the unrecorded Homebrew bottle revision behind SciPy's GNU runtime libraries, and
  Stephen L. Moshier's copyright in some libquadmath files.

Unchanged: `clean_mac` stays `false` (publications remain beta builds under the documented
exception), and the end of upstream Supertonic maintenance remains an explicit release
decision.

## Update 2026-11-04: voice model

The review of 2026-10-25 did not cover the LS-EEND voice model. The maintainer decided separately to ship it and accepts its training-data risks; see [ADR 0008](0008-meeting-speakers-and-pdf.md). Its replacement, Nemotron 3 Diarization (2026-11-07), was decided the same way on 2026-11-07: public builds carry it under OpenMDW-1.1 without external counsel, and the maintainer accepts its training-data risks (LDC corpora and David AI data). The decision is `voice_model_license_review` in both release approvals; see the same ADR.
