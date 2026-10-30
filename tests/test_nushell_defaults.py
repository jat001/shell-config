from pathlib import Path
import os
import stat
import subprocess
import tempfile
import unittest


script = Path(__file__).resolve().parents[1] / 'ansible/roles/linux/files/nushell-defaults.sh'


class NushellDefaultTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.account = self.directory / 'account'
        self.dest = self.directory / 'dest'
        self.bin = self.directory / 'bin'
        self.account.mkdir()
        self.bin.mkdir()

    def nu(self, body):
        path = self.bin / 'nu'
        path.write_text('#!/bin/sh\n' + body, encoding='utf-8')
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def capture(self, environment):
        completed = subprocess.run(
            ['sh', str(script), str(self.dest), str(self.account)],
            capture_output=True, text=True, check=False, env=environment,
        )
        return completed.returncode, completed.stdout, completed.stderr

    def environment(self, **extra):
        environment = os.environ.copy()
        environment['PATH'] = f'{self.bin}:/usr/bin:/bin'
        environment.pop('ATTACK_HOME', None)
        environment.pop('SKIP_WRITE', None)
        environment.pop('PARTIAL', None)
        environment.update(extra)
        return environment

    def test_missing_nu_succeeds_without_files(self):
        code, _stdout, stderr = self.capture(self.environment(PATH='/usr/bin:/bin'))
        self.assertEqual((code, stderr), (0, ''))
        self.assertTrue(self.dest.is_dir())
        self.assertFalse((self.dest / 'env.nu').exists())
        self.assertFalse((self.dest / 'config.nu').exists())

    def test_nu_that_writes_nothing_succeeds_without_files(self):
        self.nu('exit 0\n')
        code, _stdout, stderr = self.capture(self.environment(SKIP_WRITE='1'))
        self.assertEqual((code, stderr), (0, ''))
        self.assertFalse((self.dest / 'env.nu').exists())

    def test_partial_scaffold_is_not_published(self):
        self.nu(
            'mkdir -p "$HOME/.config/nushell"\n'
            'printf "env\\n" > "$HOME/.config/nushell/env.nu"\n'
        )
        code, _stdout, stderr = self.capture(self.environment())
        self.assertEqual((code, stderr), (0, ''))
        self.assertFalse((self.dest / 'env.nu').exists())
        self.assertFalse((self.dest / 'config.nu').exists())

    def test_complete_scaffold_is_captured_without_touching_the_account(self):
        existing = self.account / '.config/nushell/env.nu'
        existing.parent.mkdir(parents=True)
        existing.write_text('user\n', encoding='utf-8')
        self.nu(
            'mkdir -p "$HOME/.config/nushell"\n'
            'printf "env\\n" > "$HOME/.config/nushell/env.nu"\n'
            'printf "config\\n" > "$HOME/.config/nushell/config.nu"\n'
        )
        code, _stdout, stderr = self.capture(self.environment())
        self.assertEqual((code, stderr), (0, ''))
        self.assertEqual((self.dest / 'env.nu').read_text(encoding='utf-8'), 'env\n')
        self.assertEqual((self.dest / 'config.nu').read_text(encoding='utf-8'), 'config\n')
        self.assertEqual(existing.read_text(encoding='utf-8'), 'user\n')

    def test_rewriting_the_account_home_fails(self):
        self.nu(
            'mkdir -p "$ATTACK_HOME/.config/nushell"\n'
            'printf "changed\\n" > "$ATTACK_HOME/.config/nushell/env.nu"\n'
            'mkdir -p "$HOME/.config/nushell"\n'
            'printf "env\\n" > "$HOME/.config/nushell/env.nu"\n'
            'printf "config\\n" > "$HOME/.config/nushell/config.nu"\n'
        )
        code, _stdout, stderr = self.capture(self.environment(ATTACK_HOME=str(self.account)))
        self.assertEqual(code, 1)
        self.assertIn('changed the account home', stderr)
        self.assertFalse((self.dest / 'env.nu').exists())


if __name__ == '__main__':
    unittest.main()
