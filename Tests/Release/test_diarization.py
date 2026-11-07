import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
import release  # noqa: E402

spec = importlib.util.spec_from_file_location('notices', REPO / 'scripts/bundle_notices.py')
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)

WORKFLOW = REPO / '.github/workflows/release.yml'
MANIFEST = REPO / 'Runtime/Diarization/nemotron-3-manifest.json'
NOTICE = REPO / 'docs/licenses/Nemotron-3-Diarization-OpenMDW-1.1.txt'


class DependencyTests(unittest.TestCase):
    def test_fluidaudio_is_pinned_exactly_with_only_the_diarizer_trait(self):
        project = (REPO / 'OpenScreenReader.xcodeproj/project.pbxproj').read_text()
        self.assertRegex(project, r'repositoryURL = "https://github.com/FluidInference/FluidAudio";\s*'
                                  r'requirement = \{ kind = exactVersion; version = 0\.18\.2; \};\s*'
                                  r'traits = \(\s*Diarizer,?\s*\);')
        resolved = json.loads((REPO / 'OpenScreenReader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
        pin = next(item for item in resolved['pins'] if item['identity'] == 'fluidaudio')
        self.assertEqual(pin['state'], {'revision': 'e396cf780c4abf8e395087467c0585d3b0d17f68', 'version': '0.18.2'})

    def test_the_swift_package_for_the_core_stays_free_of_it(self):
        self.assertNotIn('FluidAudio', (REPO / 'Package.swift').read_text())

    def test_no_app_source_reaches_a_download_helper(self):
        forbidden = re.compile(r'loadFromHuggingFace|ModelHub\.(download|fetch)|DownloadUtils|AssetDownloader|initialize\(variant|LSEENDDiarizer\(variant|downloadAndLoad')
        users = []
        for path in (REPO / 'OpenScreenReaderApp').rglob('*.swift'):
            text = path.read_text()
            self.assertIsNone(forbidden.search(text), path)
            if re.search(r'^import FluidAudio$', text, re.M):
                users.append(path.name)
        # One place to review what the app calls in that package.
        self.assertEqual(users, ['MeetingVoiceDiarizer.swift'])


class WorkflowTests(unittest.TestCase):
    def test_the_model_is_fetched_and_bundled_only_when_the_repository_variable_is_true(self):
        text = WORKFLOW.read_text()
        fetch = re.search(r"- name: Fetch and verify the pinned voice model.*?\n(.*?)\n\s+- name:", text, re.S)
        self.assertIsNotNone(fetch)
        self.assertIn("if: vars.SAYWING_BUNDLE_DIARIZATION_MODEL == 'true'", fetch[1])
        self.assertIn('scripts/fetch-diarization-model.py', fetch[1])
        self.assertEqual(text.count('--diarization-model'), 1)
        guarded = re.search(r'if \[ "\$SAYWING_BUNDLE_DIARIZATION_MODEL" = "true" \]; then\s+voice_model=\(--diarization-model [^\n]*\)\s+fi', text)
        self.assertIsNotNone(guarded)
        self.assertIn('"${voice_model[@]}"', text)

    def test_without_the_variable_the_flag_expands_to_nothing(self):
        step = re.search(r'(voice_model=\(\)\n.*?fi\n)', WORKFLOW.read_text(), re.S)[1]
        script = step + 'printf "%s\\n" "${#voice_model[@]}" "${voice_model[@]}"'
        for value, expected in (('', ['0']), ('false', ['0']), ('TRUE', ['0']),
                                ('true', ['2', '--diarization-model', '/runner/saywing-diarization-model'])):
            result = subprocess.run(['/bin/bash', '-e', '-c', script], check=True, capture_output=True, text=True,
                                    env={'SAYWING_BUNDLE_DIARIZATION_MODEL': value, 'RUNNER_TEMP': '/runner'})
            self.assertEqual(result.stdout.split('\n')[:-1], expected, value)

    def test_the_preset_is_chosen_only_in_the_manifest(self):
        presets = json.loads(MANIFEST.read_text())['presets']
        names = '|'.join(re.escape(name) for name in presets)
        # A quoted preset name, a FluidAudio preset constant, or a model file name.
        pattern = re.compile(r'["\'](' + names + r')["\']|Nemotron3Config\.(?!preset\()[a-z]|Nemotron3Diarizer_')
        for path in [REPO / 'scripts/fetch-diarization-model.py', REPO / 'scripts/bundle-diarization-model.py',
                     REPO / 'scripts/diarization_model.py', WORKFLOW, *(REPO / 'OpenScreenReaderApp/Meeting').glob('*.swift')]:
            self.assertIsNone(pattern.search(path.read_text()), path)

    def test_the_manifest_pins_every_file_of_the_bundled_preset(self):
        manifest = json.loads(MANIFEST.read_text())
        self.assertRegex(manifest['revision'], r'^[0-9a-f]{40}$')
        self.assertEqual(manifest['license'], 'OpenMDW-1.1')
        preset = manifest['presets'][manifest['bundled_preset']]
        names = [item['rfilename'] for item in preset['files']]
        self.assertIn(f"{preset['subdirectory']}/{preset['model']}/weights/weight.bin", names)
        self.assertIn('learnable_sil_emb.bin', names)
        for item in preset['files']:
            self.assertGreater(item['size'], 0)
            self.assertRegex(item['verified_sha256'], r'^[0-9a-f]{64}$')


class ApprovalTests(unittest.TestCase):
    """A public build with the voice model needs a decision for exactly this model."""

    def check(self, record):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'approval.json'
            path.write_text(json.dumps(record))
            release.require_voice_model_approval(path)

    def test_the_general_license_review_does_not_cover_the_voice_model(self):
        approval = json.loads((REPO / 'release/release-approval.json').read_text())
        approval.pop('voice_model_license_review')
        self.assertIs(approval['license_review'], True)
        with self.assertRaisesRegex(ValueError, 'SAYWING_BUNDLE_DIARIZATION_MODEL'):
            self.check(approval)

    def test_both_architectures_record_the_maintainer_decision(self):
        # Decided 2026-11-07 (ADR 0008): public builds may carry exactly this model and revision.
        for name in ('release-approval.json', 'release-approval-x86_64.json'):
            with self.subTest(name):
                release.require_voice_model_approval(REPO / 'release' / name)
                self.assertTrue(json.loads((REPO / 'release' / name).read_text())
                                ['voice_model_license_review']['note'].startswith('2026-11-07 maintainer decision'))

    def test_only_a_decision_for_this_model_and_revision_counts(self):
        manifest = json.loads(MANIFEST.read_text())
        decision = {'approved': True, 'model': manifest['model'], 'revision': manifest['revision'], 'note': 'decided'}
        self.check({'voice_model_license_review': decision})
        for change in ({'approved': False}, {'revision': '0' * 40}, {'model': 'LS-EEND'}, {'note': ' '}):
            with self.assertRaises(ValueError, msg=change):
                self.check({'voice_model_license_review': {**decision, **change}})

    def test_the_release_checks_it_before_building_with_the_model(self):
        text = (REPO / 'scripts/release.py').read_text()
        check = text.index('require_voice_model_approval(target[\'approval\'])')
        self.assertLess(check, text.index("run('xcodebuild'"))
        self.assertIn('if args.diarization_model:', text[text.rindex('\n', 0, check - 30):check])


class DataFactsTests(unittest.TestCase):
    def test_model_records_name_the_training_data(self):
        for text in (json.loads(MANIFEST.read_text())['dataset_note'], NOTICE.read_text(),
                     (REPO / 'docs/decisions/0008-meeting-speakers-and-pdf.md').read_text()):
            flat = ' '.join(text.split())
            for name in ('Fisher English', 'DIHARD', 'CALLHOME', 'Linguistic Data Consortium', 'David AI'):
                self.assertIn(name, flat)

    def test_the_notice_carries_the_license_and_the_notices_of_origin(self):
        text = NOTICE.read_text()
        self.assertIn('OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)', text)
        # The agreement, word for word, as published at openmdw.ai.
        for clause in ('you shall retain in your distribution (1) a copy of this agreement',
                       'This agreement does not impose any restrictions or obligations with respect to any use',
                       'IN NO EVENT SHALL THE PROVIDERS OF THE MODEL MATERIALS BE LIABLE'):
            self.assertIn(clause, text)
        manifest = json.loads(MANIFEST.read_text())
        for origin in (manifest['revision'], manifest['upstream_revision'], 'NVIDIA', 'Fluid Inference'):
            self.assertIn(origin, text)


class NoticeTests(unittest.TestCase):
    def test_every_build_ships_the_notices_of_the_linked_code(self):
        with tempfile.TemporaryDirectory() as temp:
            resources = Path(temp)
            release.copy_linked_code_notices(resources)
            index = notices.render_index(resources)
        for expected in ('LICENSE-Sparkle', 'LICENSE-FluidAudio', 'Apache License', 'Daniel Müllner', 'BUT Speech@FIT', 'e396cf780c4abf8e'):
            self.assertIn(expected, index)

    def test_the_fluidaudio_notice_covers_the_version_that_is_pinned(self):
        project = (REPO / 'OpenScreenReader.xcodeproj/project.pbxproj').read_text()
        version = re.search(r'FluidAudio";\s*requirement = \{ kind = exactVersion; version = ([0-9.]+);', project)[1]
        self.assertTrue((REPO / f'docs/licenses/FluidAudio-{version}.txt').is_file())
        self.assertIn(f'docs/licenses/FluidAudio-{version}.txt', (REPO / 'scripts/release.py').read_text())


class BundlingTests(unittest.TestCase):
    """The real scripts against a small stand-in manifest; a build without them stays untouched."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        repo = self.root / 'repo'
        (repo / 'scripts').mkdir(parents=True)
        (repo / 'Runtime/Diarization').mkdir(parents=True)
        (repo / 'docs/licenses').mkdir(parents=True)
        for name in ('bundle-diarization-model.py', 'diarization_model.py'):
            shutil.copy2(REPO / 'scripts' / name, repo / 'scripts/')
        shutil.copy2(NOTICE, repo / 'docs/licenses/')
        self.models = self.root / 'models'
        model = 'X.mlmodelc'
        files = []
        for relative, content in ((f'{model}/weights/weight.bin', b'\xcf\xfaweights'), (f'{model}/model.mil', b'program'),
                                  (f'{model}/coremldata.bin', b'data'), ('learnable_sil_emb.bin', b'silence')):
            path = self.models / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            files.append({'rfilename': relative if '/' not in relative else f'sub/{relative}', 'size': len(content),
                          'verified_sha256': hashlib.sha256(content).hexdigest()})
        (self.models / 'unlisted.txt').write_text('not part of the model')
        (repo / 'Runtime/Diarization/nemotron-3-manifest.json').write_text(json.dumps(
            {'bundled_preset': 'x', 'presets': {'x': {'subdirectory': 'sub', 'model': model, 'files': files}}}))
        self.script = repo / 'scripts/bundle-diarization-model.py'
        self.app = self.root / 'Saywing.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        shutil.copyfile('/usr/bin/true', self.app / 'Contents/MacOS/Saywing')
        (self.app / 'Contents/MacOS/Saywing').chmod(0o755)

    def bundle(self):
        return subprocess.run([sys.executable, self.script, self.app, self.models], capture_output=True, text=True)

    def test_the_model_lands_where_the_app_looks_with_only_its_listed_files(self):
        result = self.bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.app / 'Contents/Resources/Diarization'
        self.assertEqual(sorted(str(path.relative_to(target)) for path in target.rglob('*') if path.is_file()), [
            'LICENSE-Nemotron-3-Diarization.txt', 'X.mlmodelc/coremldata.bin', 'X.mlmodelc/model.mil',
            'X.mlmodelc/weights/weight.bin', 'learnable_sil_emb.bin', 'nemotron-3-manifest.json'])
        self.assertEqual(json.loads((target / 'nemotron-3-manifest.json').read_text())['bundled_preset'], 'x')

    def test_the_model_notice_ships_with_the_model_and_only_then(self):
        resources = self.app / 'Contents/Resources'
        release.copy_linked_code_notices(resources)
        index = notices.render_index(resources)
        self.assertNotIn('Nemotron', index)
        self.assertEqual(self.bundle().returncode, 0)
        index = notices.render_index(resources)
        self.assertIn('Diarization/LICENSE-Nemotron-3-Diarization.txt', index)
        self.assertIn('<h2>Nemotron 3 Diarization</h2>', index)
        self.assertIn('OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)', index)
        self.assertIn('Fisher English', index)

    def test_a_changed_model_file_stops_the_build(self):
        target = next(self.models.rglob('model.mil'))
        target.write_bytes(b'prograN')
        result = self.bundle()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('verification failed', result.stderr)
        self.assertFalse((self.app / 'Contents/Resources/Diarization').exists())

    def test_a_missing_asset_stops_the_build(self):
        (self.models / 'learnable_sil_emb.bin').unlink()
        self.assertNotEqual(self.bundle().returncode, 0)
        self.assertFalse((self.app / 'Contents/Resources/Diarization').exists())

    def test_signing_seals_the_model_as_resources(self):
        self.assertEqual(self.bundle().returncode, 0)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', self.app], check=True, capture_output=True)
        verify = ['/usr/bin/codesign', '--verify', '--deep', '--strict', self.app]
        self.assertEqual(subprocess.run(verify, capture_output=True).returncode, 0)
        next((self.app / 'Contents/Resources/Diarization').rglob('weight.bin')).write_bytes(b'changed')
        self.assertNotEqual(subprocess.run(verify, capture_output=True).returncode, 0)


class FetchTests(unittest.TestCase):
    def test_a_fetched_folder_is_laid_out_like_the_app_and_names_its_preset(self):
        manifest = json.loads(MANIFEST.read_text())
        spec = importlib.util.spec_from_file_location('diarization_model', REPO / 'scripts/diarization_model.py')
        model = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(model)
        for name, preset in manifest['presets'].items():
            placed = [str(model.placed(preset, item)) for item in preset['files']]
            self.assertIn(f"{preset['model']}/weights/weight.bin", placed, name)
            self.assertTrue(all('/' not in path or path.startswith(preset['model'] + '/') for path in placed), name)
        text = (REPO / 'scripts/fetch-diarization-model.py').read_text()
        self.assertIn('https://huggingface.co/{manifest[\'repo\']}/resolve/{manifest[\'revision\']}/', text)
        self.assertIn('model.MANIFEST_NAME', text)
        self.assertIn('model.NOTICE_NAME', text)


if __name__ == '__main__':
    unittest.main()
