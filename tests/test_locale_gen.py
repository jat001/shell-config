import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


class LocaleGenTests(unittest.TestCase):
    def test_first_match_deduplication_and_idempotence(self):
        script = Path(__file__).resolve().parents[1] / "ansible/roles/linux/files/locale_gen.py"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "locale.gen"
            path.write_text(
                "# en_US.UTF-8 UTF-8\n"
                "en_US.UTF-8 UTF-8\n"
                "zh_CN.UTF-8 UTF-8  \n"
                "# keep this entry\n"
                "en_US.UTF-8 UTF-8\n"
                "# en_US.UTF-8 UTF-8\n",
                encoding="utf-8",
            )
            path.chmod(0o640)
            environment = os.environ.copy()
            environment["SHELL_REQUIRED_LOCALES"] = '["en_US.UTF-8", "zh_CN.UTF-8", "fr_FR.UTF-8"]'

            def run(check):
                environment["SHELL_CHECK_MODE"] = "true" if check else "false"
                return subprocess.run(
                    [sys.executable, str(script), str(path)],
                    env=environment,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()

            original = path.read_bytes()
            self.assertEqual(run(True), "changed")
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(run(False), "changed")
            normalized = path.read_text(encoding="utf-8")
            self.assertEqual(
                normalized.splitlines(),
                [
                    "en_US.UTF-8 UTF-8",
                    "zh_CN.UTF-8 UTF-8",
                    "# keep this entry",
                    "# en_US.UTF-8 UTF-8",
                    "fr_FR.UTF-8 UTF-8",
                ],
            )
            if os.name == "posix":
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
            self.assertEqual(run(False), "unchanged")
            self.assertEqual(path.read_text(encoding="utf-8"), normalized)


if __name__ == "__main__":
    unittest.main()
