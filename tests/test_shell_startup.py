import contextlib
import io
import os
import shutil
import socket
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import shell_startup


class ShellStartupTests(unittest.TestCase):
    def test_inherited_managed_variables_are_cleared(self):
        with patch.dict(
            os.environ, {"PNPM_HOME": "/inherited", "XDG_DATA_HOME": "/inherited", "LC_ALL": "zh_CN.UTF-8"}
        ):
            environment = shell_startup.shell_environment("/tmp/home")
        self.assertNotIn("PNPM_HOME", environment)
        self.assertNotIn("XDG_DATA_HOME", environment)
        self.assertEqual(environment["LC_ALL"], "C")
        self.assertEqual(environment["HOME"], "/tmp/home")

    def test_startup_errors_fail_even_with_a_valid_marker(self):
        for error in ("syntax error near unexpected token", "ble.sh: insane environment", "Error: nu::shell"):
            with self.subTest(error=error), self.assertRaises(RuntimeError):
                shell_startup.check("test", f"{error}\n__SHELL_OK__/expected__END__", "/expected")

    def test_missing_marker_fails(self):
        with self.assertRaises(RuntimeError):
            shell_startup.check("test", "", "/expected")

    def test_terminal_queries_are_answered_across_reads(self):
        terminal, peer = socket.socketpair()
        with terminal, peer:
            peer.settimeout(1)
            output = bytearray()
            peer.sendall(b"\x1b[6")
            shell_startup.read_until(terminal.fileno(), output, None, 0.02)
            peer.sendall(b"n\x1b[c__DONE__")
            shell_startup.read_until(terminal.fileno(), output, b"__DONE__", 1)
            replies = bytearray()
            while len(replies) < len(b"\x1b[1;1R\x1b[?1;2c"):
                replies.extend(peer.recv(32))
            self.assertEqual(replies, b"\x1b[1;1R\x1b[?1;2c")

    @unittest.skipUnless(shutil.which("bash"), "bash is required")
    def test_bash_without_blesh_fails_even_when_environment_is_correct(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".bashrc").write_text('export PNPM_HOME="/expected"\n', encoding="utf-8")
            with self.assertRaises(RuntimeError):
                shell_startup.run("bash", home, "/expected", 0.1, 0.5)

    def test_valid_marker_passes(self):
        with contextlib.redirect_stdout(io.StringIO()):
            shell_startup.check("test", "__SHELL_OK__/expected__END__", "/expected")


if __name__ == "__main__":
    unittest.main()
