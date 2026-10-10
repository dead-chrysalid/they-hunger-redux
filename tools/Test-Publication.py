"""Small integration checks for historical resource and credential auditing."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publication_audit', Path(__file__).with_name('Audit-PublicSources.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HistoryAuditTests(unittest.TestCase):
    def test_deleted_resource_is_still_detected(self):
        with tempfile.TemporaryDirectory(prefix='redux-publication-') as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], stderr=subprocess.STDOUT)
            git('init', '-b', 'master')
            git('config', 'user.name', 'Publication test')
            git('config', 'user.email', 'test@example.invalid')
            (repo / 'README.md').write_text('Source only\n')
            git('add', '.')
            git('commit', '-m', 'Clean source')
            self.assertTrue(module.audit(repo, 'master')['passed'])
            (repo / 'models').mkdir()
            (repo / 'models/test.mdl').write_bytes(b'private resource fixture')
            git('add', '.')
            git('commit', '-m', 'Historical resource')
            git('rm', 'models/test.mdl')
            git('commit', '-m', 'Remove resource from current tree')
            result = module.audit(repo, 'master')
            self.assertFalse(result['passed'])
            self.assertIn('game-resource', [issue['type'] for issue in result['issues']])
            (repo / 'credential.txt').write_text('ghp_' + 'X' * 36)
            git('add', '.')
            git('commit', '-m', 'Synthetic credential signature')
            result = module.audit(repo, 'master')
            self.assertIn('github-token', [issue['type'] for issue in result['issues']])
            self.assertNotIn('ghp_' + 'X' * 36, str(result))


if __name__ == '__main__':
    unittest.main()
