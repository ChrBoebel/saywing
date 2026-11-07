#!/usr/bin/env python3
"""Download the pinned Nemotron 3 voice model for a Saywing build and verify every file.

Build-time only: the app itself never downloads it. Files come from the revision in
Runtime/Diarization/nemotron-3-manifest.json and must match its sizes and SHA-256 digests;
anything else is deleted and the script fails. The target folder ends up laid out like
the app's Diarization folder, so the opt-in tests and the evaluation load it as it is."""
import argparse
from pathlib import Path
import shutil
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import diarization_model as model  # noqa: E402

manifest = model.load_manifest()
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('target', type=Path, help='Directory that receives the model (for example .build/models/nemotron-3)')
parser.add_argument('--preset', default=manifest['bundled_preset'], choices=sorted(manifest['presets']),
                    help='Another measured preset, for evaluation only; builds bundle the manifest\'s')
args = parser.parse_args()

target = args.target.resolve()
target.mkdir(parents=True, exist_ok=True)
preset = manifest['presets'][args.preset]
for item in preset['files']:
    path = (target / model.placed(preset, item)).resolve()
    if not path.is_relative_to(target):
        raise SystemExit('Manifest path escapes target')
    if model.matches(path, item):
        continue
    path.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/{manifest['repo']}/resolve/{manifest['revision']}/{item['rfilename']}"
    print('Downloading', item['rfilename'], file=sys.stderr)
    with urllib.request.urlopen(url) as response, path.open('wb') as out:
        while chunk := response.read(1024 * 1024):
            out.write(chunk)
    if not model.matches(path, item):
        path.unlink()
        raise SystemExit('Verification failed: ' + item['rfilename'])
# The folder's manifest names the preset it holds; bundle-diarization-model.py ships the
# repository's manifest instead.
(target / model.MANIFEST_NAME).write_text(model.MANIFEST.read_text().replace(
    f'"bundled_preset": "{manifest["bundled_preset"]}"', f'"bundled_preset": "{args.preset}"', 1))
shutil.copy2(model.NOTICE, target / model.NOTICE_NAME)
print(target)
