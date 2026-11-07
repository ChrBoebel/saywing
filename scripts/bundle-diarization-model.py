#!/usr/bin/env python3
"""Copy the verified Nemotron 3 voice model into a built Saywing.app. No downloads.

Every file of the manifest's bundled preset must match Runtime/Diarization/nemotron-3-manifest.json.
Only those files, the manifest and the model's notice are copied. Run it before the step that
signs the app (bundle-dictation-runtime.py or release.py signing), because it changes the
bundle's resources."""
import argparse
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import diarization_model as model  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('models', type=Path, help='Directory filled by scripts/fetch-diarization-model.py')
args = parser.parse_args()

manifest = model.load_manifest()
app, models = args.app.resolve(strict=True), args.models.resolve(strict=True)
if app.name != 'Saywing.app' or not (app/'Contents/MacOS/Saywing').is_file():
    raise SystemExit('Expected a built Saywing.app')
names = model.verify(models, manifest, manifest['bundled_preset'])
target = app/'Contents/Resources/Diarization'
if target.exists():
    raise SystemExit('Refusing to replace an existing voice model; use a fresh build')
for relative in names:
    (target/relative).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(models/relative, target/relative)
shutil.copy2(model.MANIFEST, target/model.MANIFEST_NAME)
shutil.copy2(model.NOTICE, target/model.NOTICE_NAME)
print('VOICE MODEL BUNDLED:', target/manifest['presets'][manifest['bundled_preset']]['model'])
