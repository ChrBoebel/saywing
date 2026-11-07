#!/usr/bin/env python3
"""Retain and expose exact bundled notices; this inventory is not a legal approval."""
import argparse
import hashlib
from html import escape
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release import corresponding_source_key, https_url, public_source_url  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
SOURCE_RECORDS = REPO / 'docs/licenses/native-corresponding-sources.json'
# Maintainer download cache for --fetch-sources; never bundled into the app.
SOURCE_CACHE = REPO / '.build/license-corresponding-source'
# ADR 0007: the app ships exact pointers and a written offer, never the source archives.
# The publish job archives the exact files for every published build and verifies that each
# one is publicly downloadable at its `mirror_url` on the download host (amendment 2026-10-25).
SOURCE_DOCUMENTS = ('README.md', 'sources.json')
SOURCE_REQUESTS = 'https://github.com/ChrBoebel/saywing/issues'
MAINTAINER_PROFILE = 'https://github.com/ChrBoebel'
COPYLEFT = re.compile(r'\b(L?GPL|MPL)')
SHA256 = re.compile(r'[0-9a-f]{64}')
MH_MAGIC_64 = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe')
FAT_MAGIC = (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
MH_DYLIB = 6
# GNU toolchain runtime libraries (LGPL / GPL with the GCC exception). Every copy must be
# declared by a corresponding-source record and stay a separate, replaceable dylib.
GNU_RUNTIME = ('libquadmath', 'libgfortran', 'libgcc_s', 'libstdc++', 'libgomp', 'libatomic', 'libssp')


def verify_supplements(directory, records):
    for record in records:
        path = (directory / record['license_file']).resolve(strict=True)
        if not path.is_relative_to(directory.resolve()):
            raise ValueError('License supplement escapes directory')
        if hashlib.sha256(path.read_bytes()).hexdigest() != record['license_sha256']:
            raise ValueError('License supplement hash mismatch: ' + record['license_file'])



def unsigned_digest(path):
    # Developer ID signing changes the seal, not the reviewed native code.
    # Normalize a temporary copy so re-signing does not invalidate provenance. Removing a
    # linker-generated signature leaves different padding than removing a codesign one,
    # so the copy is signed ad hoc first: raw wheel files and bundled copies then agree.
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / path.name
        shutil.copy2(path, copy)
        for command in (['--force', '--sign', '-'], ['--remove-signature']):
            subprocess.run(['/usr/bin/codesign', *command, str(copy)], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return hashlib.sha256(copy.read_bytes()).hexdigest()


def verify_rust_coverage(resources, proof, architecture):
    if not proof.get('complete') or architecture not in ('arm64', 'x86_64'):
        raise ValueError('Rust license coverage is incomplete or architecture is unknown')
    records = [item for item in proof['binaries'] if item['architecture'] == architecture]
    if architecture == 'arm64' and not records:
        raise ValueError('ARM Rust binary provenance is missing')
    known = set()
    for item in records:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Rust provenance escapes bundle')
        path = resources / relative
        if not path.is_file() or not path.resolve().is_relative_to(resources.resolve()):
            raise ValueError('Rust provenance is missing or escapes bundle')
        if unsigned_digest(path) != item['unsigned_sha256']:
            raise ValueError('Rust binary differs from license-reviewed source: ' + item['path'])
        known.add(path.resolve())
    for path in resources.rglob('*'):
        if path.is_file() and path.suffix in ('.so', '.dylib') and path.resolve() not in known:
            if b'/rustc/' in path.read_bytes():
                raise ValueError('Unreviewed Rust library: ' + str(path.relative_to(resources)))


def for_architecture(records, architecture):
    return [item for item in records if architecture in item.get('architectures', ['arm64', 'x86_64'])]


def macho_filetype(path):
    """Mach-O file type; for universal files, every slice must have the same type."""
    with path.open('rb') as stream:
        header = stream.read(8)
        if header[:4] in FAT_MAGIC:
            offset_size = 8 if header[:4] == FAT_MAGIC[1] else 4
            count = int.from_bytes(header[4:8], 'big')
            types = set()
            for index in range(count):
                stream.seek(8 + index * (12 + 2 * offset_size + 4 * (offset_size == 8)) + 8)
                offset = int.from_bytes(stream.read(offset_size), 'big')
                stream.seek(offset)
                slice_header = stream.read(16)
                types.add(int.from_bytes(slice_header[12:16], 'little') if slice_header[:4] in MH_MAGIC_64 else None)
            return types.pop() if len(types) == 1 else None
        stream.seek(0)
        header = stream.read(16)
    return int.from_bytes(header[12:16], 'little') if header[:4] in MH_MAGIC_64 else None


def verify_copyleft_libraries(resources, records):
    """Return {library name: [relative paths]} after checking each is a separate dylib."""
    declared = {name for item in records for name in item.get('dynamic_libraries', [])}
    found = {}
    for path in sorted(resources.rglob('*')):
        if not path.name.startswith(GNU_RUNTIME) or not ('.dylib' in path.name or path.suffix in ('.so', '.a')):
            continue
        relative = str(path.relative_to(resources))
        if path.suffix == '.a':
            raise ValueError('Static GNU runtime archive must not be bundled: ' + relative)
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(resources.resolve()):
                raise ValueError('GNU runtime library escapes bundle: ' + relative)
            continue
        if path.name not in declared:
            raise ValueError('Undeclared GNU runtime library (add its corresponding source): ' + relative)
        if macho_filetype(path) != MH_DYLIB:
            raise ValueError('GNU runtime library is not a separate dynamic library: ' + relative)
        found.setdefault(path.name, []).append(relative)
    missing = sorted(declared - set(found))
    if missing:
        raise ValueError('Declared GNU runtime libraries are missing; update their record: ' + ', '.join(missing))
    return found


def written_offer():
    return ('<p><strong>Download.</strong> The source archives are not included in this app. Every file listed '
            'below is publicly available, without an account and free of charge, from the Saywing download server, '
            'the same place that serves the Saywing download; its address there is given first for each file. The '
            'upstream address follows as a second source. Check any copy against the listed size and SHA-256. '
            'CorrespondingSource/sources.json in this app lists the same records in machine-readable form (the '
            'Saywing download server address is the field mirror_url), and CorrespondingSource/README.md explains '
            'how to rebuild and replace the GNU libraries.</p>'
            '<p><strong>Written offer.</strong> In addition, for at least three years from the date on which the Saywing '
            'maintainers distributed the Saywing build that contains this notice, and for as long as they offer '
            'updates or support for that build if that is longer, the Saywing maintainers will give any third party, '
            'on request, a complete machine-readable copy of every source file listed below for that build: the '
            'complete corresponding source of the GNU libraries and the source code form of the Mozilla Public '
            'License 2.0 components. They provide it free of charge as a download or, if you ask for it, on a '
            'physical medium for no more than the cost of physically performing that distribution. Ask through the '
            'project issue tracker at <a href="' + SOURCE_REQUESTS + '">' + SOURCE_REQUESTS + '</a> and name the '
            'Saywing version, build and Mac architecture shown in Settings; if you cannot use the issue tracker, use '
            'the contact shown on the maintainer profile <a href="' + MAINTAINER_PROFILE + '">' + MAINTAINER_PROFILE
            + '</a>. The maintainers keep an identical copy of every listed file for each published build.</p>')


def link(url):
    return '<a href="' + escape(url) + '">' + escape(url) + '</a>'


def addresses(record):
    return 'download from the Saywing download server at ' + link(record['mirror_url']) + '; upstream: ' + link(record['url'])


def pointer(record):
    return ('<li><code>' + escape(record['file']) + '</code>, ' + str(record['bytes']) + ' bytes, SHA-256 <code>'
            + escape(record['sha256']) + '</code>: ' + addresses(record) + '</li>')


def source_section(records, found):
    """Written offer, GNU replaceability statement, MPL-2.0 source information and exact pointers."""
    if not records:
        return ''
    gnu = []
    for item in records:
        if not item.get('dynamic_libraries'):
            continue
        paths = [path for name in item['dynamic_libraries'] for path in found.get(name, [])]
        sources = [record for record in records if record.get('component') == item['component']]
        gnu.append('<h3>' + escape(item['component']) + '</h3><p>License: ' + escape(item['license']) + '.</p>'
                   '<p>Separate dynamic libraries in this app, unmodified from their upstream package:</p><ul>'
                   + ''.join('<li><code>' + escape(path) + '</code></li>' for path in paths) + '</ul><p>'
                   + escape(item.get('binary_origin', '')) + '</p><p>Complete corresponding source '
                   '(not included in this app; download it from the addresses below):</p><ul>'
                   + ''.join(pointer(record) for record in sources) + '</ul>')
    mpl = [item for item in records if 'MPL' in item.get('license', '')]
    html = '<h2>Corresponding source</h2>' + written_offer()
    if gnu:
        html += ('<h2>GNU libraries: license, replacement and source</h2>'
                 '<p>The libraries below are licensed under the GNU Lesser General Public License version 2.1 or later, '
                 'or the GNU General Public License version 3 or later with the GCC Runtime Library Exception 3.1. '
                 'libquadmath is licensed under the GNU Lesser General Public License version 2.1 or (at your option) '
                 'any later version; the Saywing maintainers distribute it under the GNU Lesser General Public License '
                 'version 3, which incorporates the GNU General Public License version 3 '
                 '(Licenses/GCC-13.4.0/COPYING3.LIB and COPYING3). '
                 'Their complete license texts are under Licenses/GCC-13.4.0 below. They are loaded at run time as '
                 'separate files, so you may replace them with a modified or compatible version as described in '
                 'CorrespondingSource/README.md. Saywing imposes no additional restriction on modifying them for your '
                 'own use or on reverse engineering for debugging such modifications.</p>' + ''.join(gnu))
    if mpl:
        html += ('<h2>Mozilla Public License 2.0 components</h2>'
                 '<p>The following components are covered by the Mozilla Public License 2.0, whose complete text is '
                 'included below. Their source code form is available from the addresses given, and from the Saywing '
                 'maintainers under the written offer above.</p><ul>'
                 + ''.join('<li>' + escape(item.get('component', item['file'])) + ' (' + escape(item['license'])
                           + '): <code>' + escape(item['file']) + '</code>, ' + str(item['bytes'])
                           + ' bytes, SHA-256 <code>' + escape(item['sha256']) + '</code>: ' + addresses(item)
                           + '; license text: '
                           + ', '.join('<code>' + escape(text) + '</code>' for text in item['license_texts']) + '</li>'
                           for item in mpl) + '</ul>')
    return html + '<h2>All source archives for this build</h2><ul>' + ''.join(pointer(record) for record in records) + '</ul>'


def notice_files(resources):
    for path in sorted(resources.rglob('*')):
        if not path.is_file():
            continue
        name = path.name.upper()
        supplemental = path.is_relative_to(resources / 'Licenses') and path.suffix.lower() in ('.txt', '.md', '.rst')
        if not supplemental and not name.startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'THIRDPARTYNOTICE', 'COPYRIGHT', 'AUTHORS')):
            continue
        if not path.resolve().is_relative_to(resources.resolve()):
            raise ValueError('Notice escapes resource directory')
        # Source code named licenses.py is not a license document.
        if path.suffix.lower() in ('.py', '.pyc', '.so', '.dylib', '.json', '.html'):
            continue
        yield path


VOICE_MODEL_NOTICE = 'Diarization/LICENSE-Nemotron-3-Diarization.txt'


def voice_model_section(resources):
    """Only builds that carry the meeting voice model name it (ADR 0008)."""
    if not (resources / VOICE_MODEL_NOTICE).is_file():
        return ''
    return ('<h2>Nemotron 3 Diarization</h2>'
            '<p>The model that tells the other participants\' voices apart in meeting transcripts is Nemotron 3 '
            'Diarization by NVIDIA, converted to CoreML by Fluid Inference. It is provided under the OpenMDW License '
            'Agreement, version 1.1, which grants no rights in the datasets the model was trained on. The complete '
            'license and the notices of origin are included below (<code>' + VOICE_MODEL_NOTICE + '</code>).</p>'
            '<p>Das Modell, das in Meeting-Transkripten die Stimmen der anderen Teilnehmenden unterscheidet, ist '
            'Nemotron 3 Diarization von NVIDIA, von Fluid Inference nach CoreML konvertiert. Es steht unter dem OpenMDW '
            'License Agreement, Version 1.1, das keine Rechte an den Datensätzen einräumt, mit denen das Modell '
            'trainiert wurde. Lizenz und Herkunftshinweise folgen vollständig unten (<code>' + VOICE_MODEL_NOTICE
            + '</code>).</p>\n')


def render_index(resources, sources=''):
    sections = []
    for path in notice_files(resources):
        content = path.read_text(encoding='utf-8')
        sections.append('<details><summary>' + escape(str(path.relative_to(resources)))
                        + '</summary><pre>' + escape(content) + '</pre></details>')
    if not sections:
        raise ValueError('No license notices found')
    return '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>Saywing — Licenses &amp; Model Terms</title>
<style>body{font:17px system-ui;max-width:900px;margin:48px auto;padding:0 24px;line-height:1.6}summary{cursor:pointer;overflow-wrap:anywhere}details{margin:16px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:14px ui-monospace}h1{line-height:1.2}</style>
<h1>Licenses &amp; Model Terms</h1>
<p>Saywing source code is licensed under Apache-2.0. Third-party code, models and voices retain their own licenses below.</p>
<h2>Supertonic 3</h2>
<p>Use and redistribution of the bundled Supertonic 3 model and voice are governed by the BigScience Open RAIL-M license, including paragraph 5 and Attachment A (use restrictions). These terms apply to the model and its derivatives, not to unrelated Saywing source code or other components. The complete unchanged license is included below.</p>
<p>Für die Nutzung und Weitergabe des mitgelieferten Supertonic-3-Modells und seiner Stimme gilt die BigScience Open RAIL-M-Lizenz einschließlich Absatz 5 und Anhang A (Nutzungsbeschränkungen). Diese Bedingungen gelten für das Modell und seine Ableitungen, nicht für unabhängigen Saywing-Quellcode oder andere Komponenten. Der vollständige unveränderte Lizenztext folgt unten.</p>
''' + voice_model_section(resources) + sources + '''
<h2>Original license texts and notices</h2>
<p>This document is available offline. The paths identify the original notices inside this app. An inventory does not certify that all distribution obligations have been fulfilled.</p>
''' + '\n'.join(sections) + '</html>\n'


def corresponding_sources(architecture):
    """Source records for one architecture; records without `architectures` apply to both.

    Each record gains `mirror_url`: its public copy on the download host, which is exactly the
    object scripts/publish-release.py archives and verifies for this architecture.
    """
    return [{**item, 'mirror_url': public_source_url(item, architecture)}
            for item in for_architecture(json.loads(SOURCE_RECORDS.read_text()), architecture)]


def validate_source_records(records):
    """Every pointer is exact; every copyleft record names the license texts shipped in the app."""
    for item in records:
        name = item.get('file', '')
        if Path(name).name != name or name in ('', '.', '..'):
            raise ValueError('Invalid corresponding-source filename: ' + repr(name))
        if not str(item.get('url', '')).startswith('https://') or not isinstance(item.get('bytes'), int) \
                or item['bytes'] <= 0 or not SHA256.fullmatch(str(item.get('sha256', ''))):
            raise ValueError('Corresponding source needs an HTTPS URL, size and SHA-256: ' + name)
        if not str(item.get('license', '')).strip():
            raise ValueError('Corresponding source needs its license: ' + name)
        if COPYLEFT.search(item['license']) and not item.get('license_texts'):
            raise ValueError('Copyleft corresponding source needs its shipped license texts: ' + name)
        if COPYLEFT.search(item['license']) or 'mirror_url' in item:
            validate_mirror_url(item)


def validate_mirror_url(item):
    """The public copy must be an unauthenticated HTTPS URL of exactly the archived object."""
    name = item['file']
    try:
        url = https_url(str(item.get('mirror_url') or ''))
        expected = '/' + quote(corresponding_source_key(item), safe='/@')
    except ValueError as error:
        raise ValueError('Copyleft corresponding source needs its public download URL: ' + name) from error
    if not urlsplit(url).path.endswith(expected):
        raise ValueError('Public download URL does not point to the archived source: ' + name)


def reject_bundled_sources(resources, records):
    """The app carries the offer and pointers only; any archive in it fails the build."""
    folder = resources / 'CorrespondingSource'
    if folder.exists():
        extra = sorted(str(path.relative_to(resources)) for path in folder.rglob('*')
                       if str(path.relative_to(folder)) not in SOURCE_DOCUMENTS)
        if extra:
            raise ValueError('Source archives must not be bundled in the app (ADR 0007): ' + ', '.join(extra))
    names = {item['file'] for item in records}
    bundled = sorted(str(path.relative_to(resources)) for path in resources.rglob('*') if path.name in names)
    if bundled:
        raise ValueError('Source archives must not be bundled in the app (ADR 0007): ' + ', '.join(bundled))


def write_source_pointers(resources, records):
    destination = resources / 'CorrespondingSource'
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'sources.json').write_text(json.dumps(records, indent=2) + '\n')
    shutil.copy2(REPO / 'docs/licenses/CorrespondingSource-README.md', destination / 'README.md')


def verify_license_texts(resources, records):
    shipped = {path.resolve() for path in notice_files(resources)}
    for item in records:
        for relative in item.get('license_texts', []):
            if Path(relative).is_absolute() or '..' in Path(relative).parts:
                raise ValueError('License text path escapes the app: ' + relative)
            if (resources / relative).resolve() not in shipped:
                raise ValueError('Missing license text for ' + item['file'] + ': ' + relative)


def fetch_source(item, directory):
    """Build or publish time only: download one source archive and verify size and SHA-256."""
    target = directory / Path(item['file']).name
    if not target.is_file():
        partial = target.with_name(target.name + '.partial')
        subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error', '--proto', '=https',
                        '--proto-redir', '=https', '--output', str(partial), item['url']], check=True)
        partial.rename(target)
    if target.stat().st_size != item['bytes'] or hashlib.sha256(target.read_bytes()).hexdigest() != item['sha256']:
        target.unlink()
        raise ValueError('Corresponding source hash/size mismatch: ' + item['file'])
    return target


def fetch_sources(cache, records):
    """Maintainer tool: download and verify every source archive, e.g. to answer a request."""
    cache.mkdir(parents=True, exist_ok=True)
    for item in records:
        fetch_source(item, cache)
        print('Verified', item['file'], flush=True)


def bundle_notices(resources):
    sources = REPO / 'docs/licenses'
    portable = resources / 'portable-runtime.json'
    architecture = json.loads(portable.read_text())['architecture'] if portable.exists() else 'arm64'
    source_records = corresponding_sources(architecture)
    validate_source_records(source_records)
    reject_bundled_sources(resources, source_records)
    gnu_libraries = verify_copyleft_libraries(resources, source_records)
    write_source_pointers(resources, source_records)
    records = json.loads((sources / 'portable-supplement-sources.json').read_text())
    rust_proof = json.loads((sources / 'rust-license-coverage.json').read_text())
    verify_rust_coverage(resources, rust_proof, architecture)
    records = for_architecture(records, architecture)
    verify_supplements(sources, records)
    target = resources / 'Licenses'
    target.mkdir(exist_ok=True)
    shutil.copy2(sources / 'rust-license-coverage.json', target / 'rust-license-coverage.json')
    if any(item['architecture'] == architecture for item in rust_proof['binaries']):
        shutil.copytree(sources / 'RustBuild', target / 'RustBuild', dirs_exist_ok=True)
    for name in ['Supertonic-3-Open-RAIL-M.txt'] + [item['license_file'] for item in records]:
        (target / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sources / name, target / name)
    (target / 'supplement-sources.json').write_text(json.dumps(records, indent=2) + '\n')
    (target / 'RUNTIME-NOTES.txt').write_text(
        'Current portable runtime: CPython 3.12.15; architecture: ' + architecture + '.\n'
        'Minimum macOS target: 14.0. This is not proof of execution on every supported Mac.\n'
        'Dictation backend: ' + ('MLX Whisper Turbo 4-bit.' if architecture == 'arm64' else 'whisper.cpp with Whisper Turbo GGML.') + '\n'
        'Both worker runtimes are built by scripts/build-python-runtime.py from hash-locked inputs.\n'
        'Their installed-packages.json and THIRD-PARTY-NOTICES.txt inside the app list the exact\n'
        'packages, vendored native libraries and license texts; the model manifests identify the\n'
        'bundled models.\n')

    verify_license_texts(resources, source_records)
    # Exact originals remain in place; the readable index is generated before signing.
    (resources / 'THIRD-PARTY-NOTICES.html').write_text(
        render_index(resources, source_section(source_records, gnu_libraries)), encoding='utf-8')
    inventory = [{'path': str(p.relative_to(resources)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                 for p in notice_files(resources)]
    (target / 'notice-inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    return len(inventory)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('resources', type=Path, nargs='?')
    parser.add_argument('--fetch-sources', action='store_true',
                        help='Maintainer tool: download and verify every source archive into .build/license-corresponding-source '
                             '(not bundled; used to inspect or answer a source request)')
    args = parser.parse_args()
    if not args.resources and not args.fetch_sources:
        parser.error('resources or --fetch-sources is required')
    if args.fetch_sources:
        fetch_sources(SOURCE_CACHE, json.loads(SOURCE_RECORDS.read_text()))
    if args.resources:
        print('Bundled notice files:', bundle_notices(args.resources.resolve(strict=True)))
