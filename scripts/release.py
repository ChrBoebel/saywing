#!/usr/bin/env python3
"""Build, seal and optionally notarize Saywing. Never publishes or downloads models.

Runtime input is a previously verified self-contained app; CI additionally pins
its archive by SHA-256. Signing refreshes runtime receipts only after verification.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
from urllib.parse import quote, urlsplit

REPO = Path(__file__).resolve().parents[1]
RELEASE_GATES = ('license_review', 'clean_mac', 'offline_privacy', 'update_roundtrip')
MACHO = {bytes.fromhex(value) for value in (
    'cffaedfe', 'cefaedfe', 'feedfacf', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
# Owner defaults. Forks and other maintainers override them through environment
# variables (CI: repository variables) instead of editing this file.
DEFAULT_PUBLIC_DOWNLOAD_PREFIX = 'https://www.christopherboebel.com/downloads/saywing'
DEFAULT_SIGNING_IDENTITY = 'Developer ID Application: Christopher Böbel (S28WSHSSJD)'
DEFAULT_NOTARY_PROFILE = 'Saywing-Notary-S28WSHSSJD'
# Visible beside the app in every DMG: the source license, its NOTICE, a README that scopes
# Apache-2.0 to the source code, and the Supertonic 3 model terms with the complete unchanged
# Open RAIL-M text (paragraph 5, Attachment A).
DMG_LICENSE_FILES = (('LICENSE', 'LICENSE'), ('NOTICE', 'NOTICE'),
                     ('docs/licenses/DMG-README.txt', 'README.txt'),
                     ('docs/licenses/SUPERTONIC-MODEL-TERMS.md', 'SUPERTONIC-MODEL-TERMS.md'),
                     ('docs/licenses/Supertonic-3-Open-RAIL-M.txt', 'Supertonic-3-Open-RAIL-M.txt'))
# Upstream notices of code linked into every build, whether or not it carries a voice model.
LINKED_CODE_NOTICES = (('docs/licenses/Sparkle-2.10.0.txt', 'LICENSE-Sparkle'),
                       ('docs/licenses/FluidAudio-0.18.2.txt', 'LICENSE-FluidAudio'))


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def https_url(value):
    url = urlsplit(value)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password
            or url.query or url.fragment or '$(' in value):
        raise ValueError('Expected a public HTTPS URL without credentials, query or fragment')
    return value


def validate_version(version, build):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Version must be x.y.z; build must be a positive increasing integer')


def release_target(architecture):
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported release architecture')
    suffix = '/x86_64' if architecture == 'x86_64' else ''
    return {'url_prefix': public_download_prefix() + suffix,
            'storage_prefix': 'saywing' + suffix,
            'approval': REPO / ('release/release-approval-x86_64.json' if suffix else 'release/release-approval.json')}


def public_download_prefix():
    return https_url(os.environ.get('SAYWING_PUBLIC_DOWNLOAD_PREFIX') or DEFAULT_PUBLIC_DOWNLOAD_PREFIX).rstrip('/')


def public_source_prefix():
    """Public base of the corresponding-source route; it maps to the storage root `saywing`.

    Sources are served from the same place as the DMG (GPL-3 §6(d), LGPL "same place"; ADR 0007,
    amendment 2026-10-25), so the default is the public download prefix.
    """
    return https_url(os.environ.get('SAYWING_PUBLIC_SOURCE_PREFIX') or public_download_prefix()).rstrip('/')


def corresponding_source_key(record):
    """Content-addressed object path below a storage or public architecture prefix."""
    name, sha256 = record.get('file') or '', record.get('sha256') or ''
    if Path(name).name != name or name in ('', '.', '..') or not re.fullmatch(r'[0-9a-f]{64}', sha256):
        raise ValueError('Corresponding source needs a plain file name and SHA-256: ' + repr(name))
    return f'corresponding-source/sha256/{sha256}/{name}'


def public_source_url(record, architecture):
    """Public, unauthenticated URL of the object publish-release.py archives at
    `<storage prefix>/<corresponding_source_key>`; the Intel prefix adds /x86_64 to both."""
    release_target(architecture)
    suffix = '/x86_64' if architecture == 'x86_64' else ''
    return https_url(public_source_prefix() + suffix + '/' + quote(corresponding_source_key(record), safe='/@'))


def require_release_approval(path, architecture='arm64'):
    release_target(architecture)
    record = json.loads(path.read_text())
    if record.get('scope', {}).get('architecture') != architecture:
        raise ValueError('Release approval architecture does not match')
    missing = [key for key in RELEASE_GATES if record.get(key) is not True]
    exception = record.get('owner_beta_exception', {})
    # The owner may accept the device-matrix gap for a named beta architecture, never the
    # licensing, privacy, or real-update checks. Keep clean_mac=false as evidence.
    if (missing == ['clean_mac'] and isinstance(exception, dict)
            and exception.get('approved') is True and exception.get('channel') == 'beta'
            and exception.get('gate') == 'clean_mac'
            and isinstance(exception.get('owner_decision'), str) and exception['owner_decision'].strip()
            and isinstance(exception.get('remaining_tests'), list) and exception['remaining_tests']
            and all(isinstance(item, str) and item.strip() for item in exception['remaining_tests'])
            and exception.get('architecture', 'arm64') == architecture):
        missing = []
    if missing:
        raise ValueError('Public release gates remain open: ' + ', '.join(missing))


def contained(root, relative):
    path = root / relative
    if Path(relative).is_absolute() or '..' in Path(relative).parts or not path.resolve(strict=True).is_relative_to(root.resolve()):
        raise ValueError('Resource path escapes its root')
    return path


def verify_receipt(root, receipt_path):
    receipt = json.loads(receipt_path.read_text())
    if not receipt.get('files'):
        raise ValueError('Empty runtime receipt')
    for relative, expected in receipt['files'].items():
        if digest(contained(root, relative)) != expected:
            raise ValueError('Runtime receipt mismatch: ' + relative)
    return receipt


def receipts(app):
    resources = app / 'Contents/Resources'
    return [(resources / 'Speech', resources / 'Speech/SupertonicRuntime/installation-receipt.json'),
            (resources / 'Dictation', resources / 'Dictation/installation-receipt.json')]


def refresh_project_workers(app):
    # Verify all inputs before changing anything; only our own worker sources
    # are replaced, never model weights or third-party/native dependencies.
    verified = [(root, path, verify_receipt(root, path)) for root, path in receipts(app)]
    for (root, path, record), source in zip(verified, [
            REPO / 'Runtime/Supertonic/worker.py', REPO / 'Runtime/Dictation/worker.py']):
        target = path.parent / 'worker.py'
        relative = str(target.relative_to(root))
        if relative not in record['files']:
            raise ValueError('Worker is not covered by input receipt')
        shutil.copy2(source, target)
        record['files'][relative] = digest(target)
        record['project_worker'] = {'source': str(source.relative_to(REPO)), 'sha256': digest(source)}
        path.write_text(json.dumps(record, indent=2) + '\n')


def copy_runtime_file(source, target):
    # APFS clones keep large model/runtime copies cheap. Other filesystems retain
    # copy2 semantics; source and destination are always independent files.
    result = subprocess.run(['/bin/cp', '-c', '-p', str(source), str(target)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        return shutil.copy2(source, target)
    return str(target)


def verify_speech_model(app):
    speech = app / 'Contents/Resources/Speech'
    manifest = json.loads((REPO / 'docs/research/supertonic-comparison-manifest.json').read_text())
    bundled = json.loads((speech / 'SupertonicRuntime/model-manifest.json').read_text())
    if bundled != manifest:
        raise ValueError('Bundled speech manifest differs from pinned repository manifest')
    model = speech / 'DevelopmentModels/supertonic-3-3cadd1ee'
    for entry in manifest['files']:
        path = contained(model, entry['path'])
        if path.stat().st_size != entry['bytes']:
            raise ValueError('Speech model size mismatch')
        actual = digest(path) if entry.get('sha256') else hashlib.sha1(
            f'blob {path.stat().st_size}\0'.encode() + path.read_bytes()).hexdigest()
        if actual != (entry.get('sha256') or entry['git_blob']):
            raise ValueError('Speech model hash mismatch')


def sign_bundle(app, identity):
    verified = [(root, path, verify_receipt(root, path)) for root, path in receipts(app)]
    verify_speech_model(app)
    for path in app.rglob('*'):
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(app):
            raise ValueError('External or broken app symlink')
    native = []
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO:
                    native.append(path)
    # Framework and XPC bundle seals must be created after their contained code.
    nested_bundles = [path for path in app.rglob('*') if path.is_dir()
                      and not path.is_symlink() and path.suffix in ('.framework', '.xpc', '.app', '.bundle')]
    targets = set(native + nested_bundles)
    for path in sorted(targets, key=lambda p: (-len(p.parts), str(p))):
        run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp', '--options', 'runtime',
            '--preserve-metadata=identifier,entitlements', path)
    for root, receipt_path, receipt in verified:
        receipt['files'] = {relative: digest(contained(root, relative)) for relative in receipt['files']}
        receipt['signing'] = {'identity': identity, 'reason': 'Refresh native-code hashes after Developer ID signing'}
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp', '--options', 'runtime',
        '--entitlements', REPO / 'OpenScreenReaderApp/Saywing.entitlements', app)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    for path in native:
        run('/usr/bin/codesign', '--verify', '--strict', path)
    for root, path in receipts(app):
        verify_receipt(root, path)
    verify_speech_model(app)
    run('python3', REPO / 'scripts/verify-app-permissions.py', app)


def copy_linked_code_notices(resources, repo=None):
    for relative, name in LINKED_CODE_NOTICES:
        shutil.copy2((repo or REPO) / relative, resources / name)


def dmg_license_files(repo=None):
    """Return [(source, DMG name)]; fail before any build if a license document is missing."""
    repo = repo or REPO
    missing = [relative for relative, _ in DMG_LICENSE_FILES
               if (repo / relative).is_symlink() or not (repo / relative).is_file() or not (repo / relative).stat().st_size]
    if missing:
        raise ValueError('License documents for the DMG are missing: ' + ', '.join(missing)
                         + ' (NOTICE and SUPERTONIC-MODEL-TERMS.md come with the model-terms change)')
    return [(repo / relative, name) for relative, name in DMG_LICENSE_FILES]


def stage_dmg_licenses(image_root, app, repo=None):
    """Copy the license documents and the app's offline notice index into image_root/Licenses."""
    index = app / 'Contents/Resources/THIRD-PARTY-NOTICES.html'
    if index.is_symlink() or not index.is_file():
        raise ValueError('The signed app has no THIRD-PARTY-NOTICES.html')
    target = image_root / 'Licenses'
    target.mkdir()
    for source, name in dmg_license_files(repo) + [(index, 'THIRD-PARTY-NOTICES.html')]:
        shutil.copyfile(source, target / name)
    return sorted(path.name for path in target.iterdir())


def notarize(path, profile, keychain, log_dir):
    # notarytool timeout leaves Apple's job running. Retain the submission ID/log;
    # never treat a timeout as accepted or automatically resubmit that upload.
    command = ['xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
               '--wait', '--timeout', '30m', '--output-format', 'json']
    if keychain:
        command += ['--keychain', keychain]
    log = log_dir / (path.name + '.notary.json')
    with log.open('w') as stream:
        result = subprocess.run([str(part) for part in command], stdout=stream)
    record = json.loads(log.read_text() or '{}')
    if result.returncode or record.get('status') != 'Accepted':
        raise ValueError('Notarization not accepted; inspect ' + str(log))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-app', type=Path, required=True)
    parser.add_argument('--architecture', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--output', type=Path, required=True, help='New directory, never an installed app')
    parser.add_argument('--derived-data', type=Path, help='Reuse a separate Xcode build cache')
    parser.add_argument('--packages', type=Path, help='Reuse a separate resolved package directory')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--feed-url', required=True)
    parser.add_argument('--download-url-prefix', required=True)
    parser.add_argument('--public-key', required=True)
    parser.add_argument('--identity', default=os.environ.get('SAYWING_SIGNING_IDENTITY') or DEFAULT_SIGNING_IDENTITY)
    parser.add_argument('--notary-profile', default=os.environ.get('SAYWING_NOTARY_PROFILE') or DEFAULT_NOTARY_PROFILE)
    parser.add_argument('--keychain')
    parser.add_argument('--sparkle-account', default='saywing')
    parser.add_argument('--sparkle-key-file', type=Path, help='Private temporary Ed25519 file for unattended CI signing')
    parser.add_argument('--notarize', action='store_true')
    parser.add_argument('--public-release', action='store_true', help='Requires completed release-approval.json gates and notarization')
    parser.add_argument('--diarization-model', type=Path, help='Directory filled by fetch-diarization-model.py; bundles the voice model')
    args = parser.parse_args()
    validate_version(args.version, args.build)
    dmg_license_files()
    https_url(args.feed_url)
    https_url(args.download_url_prefix)
    key = base64.b64decode(args.public_key, validate=True)
    if len(key) != 32 or not any(key):
        raise ValueError('Invalid Sparkle public key')
    if not args.identity.startswith('Developer ID Application:'):
        raise ValueError('Release signing requires a Developer ID Application identity')
    if args.public_release:
        target = release_target(args.architecture)
        require_release_approval(target['approval'], args.architecture)
        if args.download_url_prefix.rstrip('/') != target['url_prefix'] or args.feed_url != target['url_prefix'] + '/appcast.xml':
            raise ValueError('Public release URLs do not match its architecture')
        if not args.notarize:
            raise ValueError('Public releases must be notarized')
    source = args.runtime_app.resolve(strict=True)
    portable = source / 'Contents/Resources/portable-runtime.json'
    if portable.exists():
        metadata = json.loads(portable.read_text())
        if metadata['architecture'] != args.architecture or metadata['minimum_macos'] != '14.0':
            raise ValueError('Runtime architecture/baseline mismatch')
    elif args.architecture != 'arm64':
        raise ValueError('Intel requires independently assembled portable resources')
    for root, receipt in receipts(source):
        verify_receipt(root, receipt)
    verify_speech_model(source)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    derived = args.derived_data.resolve() if args.derived_data else output / 'DerivedData'
    packages = args.packages.resolve() if args.packages else output / 'packages'
    run('xcodebuild', '-project', REPO / 'OpenScreenReader.xcodeproj', '-scheme', 'OpenScreenReader',
        '-configuration', 'Release', '-derivedDataPath', derived, '-clonedSourcePackagesDirPath', packages,
        '-disableAutomaticPackageResolution', 'build', f'ARCHS={args.architecture}', 'MACOSX_DEPLOYMENT_TARGET=14.0', 'CODE_SIGNING_ALLOWED=NO',
        f'MARKETING_VERSION={args.version}', f'CURRENT_PROJECT_VERSION={args.build}',
        f'SAYWING_UPDATE_FEED_URL={args.feed_url}', f'SAYWING_UPDATE_PUBLIC_KEY={args.public_key}')
    app = output / 'Saywing.app'
    run('/usr/bin/ditto', derived / 'Build/Products/Release/Saywing.app', app)
    if args.diarization_model:
        run('python3', REPO / 'scripts/bundle-diarization-model.py', app, args.diarization_model)
    dictation = source / 'Contents/Resources/Dictation'
    if portable.exists():
        for name in ['Speech', 'Dictation']:
            shutil.copytree(source / 'Contents/Resources' / name, app / 'Contents/Resources' / name, symlinks=True, copy_function=copy_runtime_file)
        for name in ['portable-runtime.json', 'LICENSE-Saywing', 'DEVELOPMENT-PREVIEW.txt']:
            shutil.copy2(source / 'Contents/Resources' / name, app / 'Contents/Resources' / name)
    else:
        run('python3', REPO / 'scripts/bundle-dictation-runtime.py', app, dictation,
            '--speech-from', source, '--whisper-model', dictation / 'WhisperTurbo',
            '--public-release' if args.public_release else '--development-only', '--defer-app-signing')
    refresh_project_workers(app)
    # Source archives are never copied into the app (ADR 0007); bundle_notices writes the
    # written offer and exact pointers, and the publish job archives the archives themselves.
    # Inspect every native dependency, including legacy input, before signing/notarizing.
    # This rejects the previous MLX minos=26.2 bundle even when its receipt is valid.
    from portable_runtime import audit as audit_native
    native = audit_native(app, args.architecture, '14.0')
    (output / 'native-audit.json').write_text(json.dumps(native, indent=2) + '\n')
    # Full upstream notice chain accompanies every distribution, including Sparkle and FluidAudio.
    copy_linked_code_notices(app / 'Contents/Resources')
    from bundle_notices import bundle_notices
    bundle_notices(app / 'Contents/Resources')
    if args.public_release:
        (app / 'Contents/Resources/DEVELOPMENT-PREVIEW.txt').unlink(missing_ok=True)
    else:
        (app / 'Contents/Resources/DEVELOPMENT-PREVIEW.txt').write_text(
            'Private release candidate. Public distribution is not approved.\n'
            'See release-result.json for the completed signing and notarization status.\n')
    sign_bundle(app, args.identity)
    package_signed_app(app, output, args, sparkle_tools(packages))


def sparkle_tools(packages):
    artifact = packages / 'artifacts/sparkle/Sparkle'
    for directory in (artifact / 'bin', artifact / 'Sparkle/bin'):
        if all((directory / tool).is_file() for tool in ('generate_keys', 'generate_appcast', 'sign_update')):
            return directory
    raise ValueError('Pinned Sparkle tools were not resolved by Xcode')


def generate_feed(tools, publish, args):
    key_file = getattr(args, 'sparkle_key_file', None)
    credentials = ['--account', args.sparkle_account]
    if key_file is not None:
        if key_file.is_symlink() or not key_file.is_file() or key_file.stat().st_mode & 0o077:
            raise ValueError('Sparkle key must be a private regular file (mode 0600)')
        credentials = ['--ed-key-file', key_file]
    print('Generating signed Sparkle appcast', flush=True)
    run(tools / 'generate_appcast', *credentials,
        '--download-url-prefix', args.download_url_prefix.rstrip('/') + '/',
        '--maximum-deltas', '0', '-o', publish / 'appcast.xml', publish, timeout=300)
    print('Verifying signed Sparkle appcast', flush=True)
    run(tools / 'sign_update', *credentials, '--verify', publish / 'appcast.xml', timeout=300)


def package_signed_app(app, output, args, tools):
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = {'CFBundleVersion': args.build, 'CFBundleShortVersionString': args.version,
                'SUFeedURL': args.feed_url, 'SUPublicEDKey': args.public_key}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('Signed app metadata differs from the requested release')
    publish = output / 'publish'
    publish.mkdir(exist_ok=True)
    actual_key = run(tools / 'generate_keys', '--account', args.sparkle_account, '-p', capture_output=True, text=True).stdout.strip()
    if actual_key != args.public_key:
        raise ValueError('Sparkle signing key does not match the public key embedded in the app')
    if args.notarize:
        upload = output / 'notary-upload.zip'
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', app, upload)
        notarize(upload, args.notary_profile, args.keychain, output)
        run('xcrun', 'stapler', 'staple', app)
        run('xcrun', 'stapler', 'validate', app)
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', app)
    image_root = output / 'image'
    image_root.mkdir()
    shutil.copytree(app, image_root / 'Saywing.app', symlinks=True, copy_function=copy_runtime_file)
    (image_root / 'Applications').symlink_to('/Applications')
    stage_dmg_licenses(image_root, app)
    image = publish / f'Saywing-{args.version}-{args.build}.dmg'
    run('/usr/bin/hdiutil', 'create', '-volname', 'Saywing', '-srcfolder', image_root, '-format', 'UDZO', image)
    shutil.rmtree(image_root)  # Temporary image source; the signed app and final DMG remain.
    run('/usr/bin/codesign', '--sign', args.identity, '--timestamp', image)
    if args.notarize:
        notarize(image, args.notary_profile, args.keychain, output)
        run('xcrun', 'stapler', 'staple', image)
        run('xcrun', 'stapler', 'validate', image)
        print('Assessing final DMG with Gatekeeper', flush=True)
        run('/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', image, timeout=300)
    # Generate the signed feed only after the final DMG bytes are immutable.
    generate_feed(tools, publish, args)
    (publish / 'SHA256SUMS').write_text(f'{digest(image)}  {image.name}\n')
    channel = 'candidate'
    if args.public_release:
        approval = json.loads(release_target(args.architecture)['approval'].read_text())
        channel = 'beta' if approval.get('owner_beta_exception', {}).get('approved') is True else 'stable'
    (publish / 'latest.json').write_text(json.dumps({
        'version': args.version, 'build': args.build, 'url': args.download_url_prefix.rstrip('/') + '/' + image.name,
        'bytes': image.stat().st_size, 'sha256': digest(image), 'minimum_macos': '14.0', 'architecture': args.architecture,
        'channel': channel,
    }, indent=2) + '\n')
    (output / 'release-result.json').write_text(json.dumps({
        'public_release_approved': args.public_release, 'notarized': args.notarize,
        'version': args.version, 'build': args.build, 'architecture': args.architecture, 'publish_directory': str(publish),
        'source_dirty': bool(run('git', '-C', REPO, 'status', '--porcelain', capture_output=True, text=True).stdout.strip()),
        'source_commit': run('git', '-C', REPO, 'rev-parse', 'HEAD', capture_output=True, text=True).stdout.strip(),
        # Exactly the source pointers in the signed app; scripts/publish-release.py archives these files.
        'corresponding_sources': json.loads((app / 'Contents/Resources/CorrespondingSource/sources.json').read_text()),
    }, indent=2) + '\n')
    print('Prepared:', publish, '(not published)')


if __name__ == '__main__':
    main()
