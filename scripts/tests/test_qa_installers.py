import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('qa_installers', Path(__file__).parents[1] / 'qa_installers.py')
qa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qa)


class InstallerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            'GITHUB_REPOSITORY': qa.MIRROR, 'GITHUB_REF': 'refs/heads/' + qa.BRANCH,
            'GITHUB_EVENT_NAME': 'push', 'GITHUB_SHA': 'b' * 40,
            'GITHUB_RUN_NUMBER': '1', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_RUN_ID': '123',
        }
        self.manifest = {'source_repository': qa.SOURCE, 'source_branch': qa.BRANCH, 'source_sha': 'a' * 40}

    def test_valid_context_and_monotonic_build_number(self):
        self.assertEqual(qa.context(self.env, self.manifest)[1], 10001)
        self.env['GITHUB_RUN_NUMBER'] = '2'
        self.assertEqual(qa.context(self.env, self.manifest)[1], 10002)

    def test_reject_source_repository_execution(self):
        self.env['GITHUB_REPOSITORY'] = qa.SOURCE
        with self.assertRaises(RuntimeError):
            qa.context(self.env, self.manifest)

    def test_reject_other_branch_and_pull_requests(self):
        for key, value in [('GITHUB_REF', 'refs/heads/main'), ('GITHUB_EVENT_NAME', 'pull_request')]:
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                qa.context({**self.env, key: value}, self.manifest)

    def test_reject_invalid_provenance(self):
        for key, value in [('source_repository', qa.MIRROR), ('source_branch', 'branch-outside-saas'), ('source_sha', 'main')]:
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                qa.context(self.env, {**self.manifest, key: value})

    def test_mobile_and_desktop_entrypoints_are_distinct(self):
        root = Path(__file__).resolve().parents[2]
        self.assertTrue((root / 'packages/mobile_app/lib/main.dart').is_file())
        self.assertTrue((root / 'packages/desktop_app/lib/main.dart').is_file())
        self.assertTrue((root / 'packages/mobile_app/android').is_dir())
        self.assertTrue((root / 'packages/mobile_app/ios').is_dir())
        self.assertTrue((root / 'packages/desktop_app/windows').is_dir())
        self.assertTrue((root / 'packages/desktop_app/linux').is_dir())
        self.assertTrue((root / 'packages/desktop_app/macos').is_dir())
        self.assertFalse((root / 'packages/mobile_app/web').exists())

    def test_reject_windows_version_overflow(self):
        with self.assertRaises(RuntimeError):
            qa.context({**self.env, 'GITHUB_RUN_NUMBER': '60000'}, self.manifest)

    def test_matching_snapshot_allows_manifest(self):
        qa.check_source_tree({'app': ('100644', 'a')},
                             {'app': ('100644', 'a'), 'docs/saas/CI_CANDIDATE_SOURCE.json': ('100644', 'b')})

    def test_reject_changed_or_missing_source_file_and_unapproved_extra(self):
        for mirror in ({'app': 'b'}, {'other': 'a'}, {'app': 'a', 'malicious.py': 'b'}):
            with self.subTest(mirror=mirror), self.assertRaises(RuntimeError):
                qa.check_source_tree({'app': 'a'}, mirror)

    def test_reject_public_release_destination(self):
        with patch.object(qa, 'api', return_value={'private': False}), self.assertRaises(RuntimeError):
            qa.provenance(self.manifest)

    def test_incomplete_assets_never_create_release(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(qa, 'DIST', Path(tmp)), \
             patch.object(qa, 'context', return_value=(self.manifest, 10001)), \
             patch.object(qa, 'provenance'), patch.object(qa, 'api') as api:
            with self.assertRaises(RuntimeError):
                qa.publish()
            api.assert_not_called()

    def test_upload_digest_failure_leaves_draft(self):
        with tempfile.TemporaryDirectory() as tmp:
            dist = Path(tmp)
            for name in ('StOmni-SaaS-QA-2.0.1-10001-android.apk',
                         'StOmni-SaaS-QA-2.0.1-10001-windows-x64-setup.exe',
                         'SHA256SUMS.txt', 'android-signing-info.txt'):
                (dist / name).write_bytes(b'test')
            with patch.object(qa, 'DIST', dist), patch.object(qa, 'context', return_value=(self.manifest, 10001)), \
                 patch.object(qa, 'provenance'), patch.dict(qa.os.environ, self.env), \
                 patch.object(qa, 'api', side_effect=[{'id': 1}, {'size': 4, 'digest': 'wrong'}]) as api:
                with self.assertRaises(RuntimeError):
                    qa.publish()
                self.assertTrue(api.call_args_list[0].kwargs['payload']['draft'])
                self.assertEqual(api.call_count, 2)


if __name__ == '__main__':
    unittest.main()
