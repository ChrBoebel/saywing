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
MANIFEST = REPO / 'Runtime/Diarization/ls-eend-manifest.json'


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
        forbidden = re.compile(r'loadFromHuggingFace|ModelHub\.(download|fetch)|DownloadUtils|AssetDownloader|initialize\(variant|LSEENDDiarizer\(variant')
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

    def test_the_variant_is_chosen_only_in_the_manifest(self):
        variants = json.loads(MANIFEST.read_text())['variants']
        pattern = re.compile(r'\b(' + '|'.join(variants) + r')\b')
        for path in [REPO / 'scripts/fetch-diarization-model.py', REPO / 'scripts/bundle-diarization-model.py', WORKFLOW,
                     *(REPO / 'OpenScreenReaderApp/Meeting').glob('*.swift')]:
            self.assertIsNone(pattern.search(path.read_text()), path)


class DataFactsTests(unittest.TestCase):
    def test_model_records_name_the_pretraining_data(self):
        for text in (json.loads(MANIFEST.read_text())['dataset_note'], (REPO / 'Runtime/Diarization/LICENSE-LS-EEND.txt').read_text(),
                     (REPO / 'docs/decisions/0008-meeting-speakers-and-pdf.md').read_text()):
            flat = ' '.join(text.split())
            for name in ('Switchboard', 'NIST SRE', 'MUSAN'):
                self.assertIn(name, flat)


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
    """The real script against a small stand-in manifest; a build without it stays untouched."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        repo = self.root / 'repo'
        (repo / 'scripts').mkdir(parents=True)
        (repo / 'Runtime/Diarization').mkdir(parents=True)
        shutil.copy2(REPO / 'scripts/bundle-diarization-model.py', repo / 'scripts/')
        shutil.copy2(REPO / 'Runtime/Diarization/LICENSE-LS-EEND.txt', repo / 'Runtime/Diarization/')
        self.models = self.root / 'models'
        directory = 'optimized/x/100ms/ls_eend_x_100ms.mlmodelc'
        files = []
        for relative, content in (('weights/weight.bin', b'\xcf\xfaweights'), ('model.mil', b'program'), ('coremldata.bin', b'data')):
            path = self.models / directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            files.append({'rfilename': f'{directory}/{relative}', 'size': len(content),
                          'verified_sha256': hashlib.sha256(content).hexdigest()})
        (repo / 'Runtime/Diarization/ls-eend-manifest.json').write_text(json.dumps(
            {'bundled_variant': 'x', 'variants': {'x': {'directory': directory, 'files': files}}}))
        self.script = repo / 'scripts/bundle-diarization-model.py'
        self.app = self.root / 'Saywing.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        shutil.copyfile('/usr/bin/true', self.app / 'Contents/MacOS/Saywing')
        (self.app / 'Contents/MacOS/Saywing').chmod(0o755)

    def bundle(self):
        return subprocess.run([sys.executable, self.script, self.app, self.models], capture_output=True, text=True)

    def test_the_model_notice_ships_with_the_model_and_only_then(self):
        resources = self.app / 'Contents/Resources'
        release.copy_linked_code_notices(resources)
        self.assertNotIn('LICENSE-LS-EEND', notices.render_index(resources))
        result = self.bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        index = notices.render_index(resources)
        self.assertIn('Diarization/LICENSE-LS-EEND.txt', index)
        self.assertIn('Switchboard', index)

    def test_a_changed_model_file_stops_the_build(self):
        target = next(self.models.rglob('model.mil'))
        target.write_bytes(b'prograN')
        result = self.bundle()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('verification failed', result.stderr)
        self.assertFalse((self.app / 'Contents/Resources/Diarization').exists())

    def test_signing_seals_the_model_as_resources(self):
        self.assertEqual(self.bundle().returncode, 0)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', self.app], check=True, capture_output=True)
        verify = ['/usr/bin/codesign', '--verify', '--deep', '--strict', self.app]
        self.assertEqual(subprocess.run(verify, capture_output=True).returncode, 0)
        next((self.app / 'Contents/Resources/Diarization').rglob('weight.bin')).write_bytes(b'changed')
        self.assertNotEqual(subprocess.run(verify, capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
