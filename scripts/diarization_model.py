"""The pinned Nemotron 3 voice model: where its files go and how they are checked.

Shared by fetch-diarization-model.py and bundle-diarization-model.py. A model folder is
laid out like the app's Contents/Resources/Diarization: the preset's compiled model, its
assets, the manifest and the notice. The app reads `bundled_preset` from the manifest in
that folder; nothing else in Saywing names a preset."""
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MANIFEST = REPO / 'Runtime/Diarization/nemotron-3-manifest.json'
MANIFEST_NAME = 'nemotron-3-manifest.json'
NOTICE = REPO / 'docs/licenses/Nemotron-3-Diarization-OpenMDW-1.1.txt'
NOTICE_NAME = 'LICENSE-Nemotron-3-Diarization.txt'


def load_manifest(path=MANIFEST):
    return json.loads(Path(path).read_text())


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def placed(preset, item):
    """Where a manifest file goes in a model folder: its path without the preset's subdirectory."""
    name = item['rfilename']
    prefix = preset['subdirectory'] + '/'
    relative = Path(name[len(prefix):] if name.startswith(prefix) else name)
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit('Manifest path escapes the model folder: ' + name)
    return relative


def matches(path, item):
    return path.is_file() and path.stat().st_size == item['size'] and sha256(path) == item['verified_sha256']


def verify(folder, manifest, preset_name):
    """Every file of the preset in `folder`, with its size and SHA-256; returns the relative paths."""
    preset = manifest['presets'][preset_name]
    folder = Path(folder).resolve(strict=True)
    names = []
    for item in preset['files']:
        relative = placed(preset, item)
        path = (folder / relative).resolve(strict=True)
        if not path.is_relative_to(folder):
            raise SystemExit('Model path escapes the model folder: ' + item['rfilename'])
        if not matches(path, item):
            raise SystemExit('Pinned voice model verification failed: ' + item['rfilename'])
        names.append(relative)
    return names
