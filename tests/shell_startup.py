#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import pty
import pwd
import re
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
from pathlib import Path

SHELLS = {
    "bash": (
        ["bash", "-i"],
        'declare -F ble-attach >/dev/null && test -n "$BLE_VERSION" && alias code >/dev/null '
        '''&& printf '__SHELL_OK__%s__END__\\n' "$PNPM_HOME"''',
    ),
    "zsh": (
        ["zsh", "-i"],
        "(( $+functions[compdef] && $+functions[antidote] )) && alias code >/dev/null "
        '''&& printf '__SHELL_OK__%s__END__\\n' "$PNPM_HOME"''',
    ),
    "fish": (
        ["fish", "-i"],
        "functions --query _shell_history_search fish_prompt; and functions code >/dev/null; "
        '''and printf '__SHELL_OK__%s__END__\\n' "$PNPM_HOME"''',
    ),
    "pwsh": (
        ["pwsh", "-NoLogo"],
        "if (-not (Get-Module PSCompletions)) { throw 'PSCompletions is missing' }; "
        "$null = Get-Alias code; $null = prompt; "
        '[Console]::WriteLine("__SHELL_OK__" + $env:PNPM_HOME + "__END__")',
    ),
    "nu": (
        ["nu"],
        "if ($env.config.completions.external.completer | describe) != 'closure' "
        "{ error make {msg: 'External completer is missing'} }; "
        "do $env.config.completions.external.completer ['printf']; "
        "do $env.config.completions.external.completer {command: ['printf']}; "
        "if (scope aliases | where name == 'code' | is-empty) { error make {msg: 'code alias is missing'} }; "
        "do $env.PROMPT_COMMAND; print ('__SHELL_OK__' + $env.PNPM_HOME + '__END__')",
    ),
}
ANSI = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[@-_]")
ERRORS = re.compile(
    r"error:|command not found|unknown command|cannot find|insane environment|"
    r"commandnotfound|exception|not found|not recognized|syntax error|failed to",
    re.IGNORECASE,
)
TERMINAL_REPLIES = {
    b"\x1b[6n": b"\x1b[1;1R",
    b"\x1b[c": b"\x1b[?1;2c",
    b"\x1b[0c": b"\x1b[?1;2c",
}


def read_until(fd, output, marker, timeout):
    deadline = time.monotonic() + timeout
    while marker is None or marker not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        if not select.select([fd], [], [], min(remaining, 0.1))[0]:
            continue
        try:
            block = os.read(fd, 4096)
        except OSError:
            break
        if not block:
            break
        previous = len(output)
        output.extend(block)
        # Reedline and PSReadLine wait for a cursor report before accepting keyboard input.
        for query, reply in TERMINAL_REPLIES.items():
            count = output[max(0, previous - len(query) + 1) :].count(query)
            if count:
                os.write(fd, reply * count)


def stop(pid):
    for _ in range(20):
        try:
            finished, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if finished:
            return
        time.sleep(0.05)
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)


def check(shell, text, expected):
    marker = f"__SHELL_OK__{expected}__END__"
    text = ANSI.sub("", text).replace("\r", "")
    if marker not in text:
        raise RuntimeError(f"{shell} did not finish shared initialization:\n{text}")
    errors = ERRORS.search(text)
    if errors:
        raise RuntimeError(f"{shell} printed a startup error ({errors.group(0)}):\n{text}")
    print(f"{shell}: {expected}")


def shell_environment(home):
    environment = os.environ.copy()
    configuration = json.loads((Path(__file__).resolve().parents[1] / "common.json").read_text(encoding="utf-8"))
    for section in [configuration["common"], *configuration["environments"].values()]:
        for key in section.get("environment", {}):
            if key != "PATH":
                environment.pop(key, None)
    environment["HOME"] = home
    environment["USER"] = pwd.getpwuid(os.getuid()).pw_name
    environment["LOGNAME"] = environment["USER"]
    environment["TERM"] = "xterm-256color"
    environment["LC_ALL"] = "C"
    return environment


def run(shell, home, expected, delay, timeout):
    argv, command = SHELLS[shell]
    if shutil.which(argv[0]) is None:
        raise RuntimeError(f"{argv[0]} is not installed")
    environment = shell_environment(home)
    marker = f"__SHELL_OK__{expected}__END__".encode()
    with tempfile.TemporaryDirectory(prefix="shell-startup-") as runtime:
        environment["XDG_RUNTIME_DIR"] = runtime
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 120, 0, 0))
            os.chdir(home)
            os.execvpe(argv[0], argv, environment)

        output = bytearray()
        try:
            read_until(fd, output, None, delay)
            os.write(fd, (command + "\r").encode())
            read_until(fd, output, marker, timeout)
            os.write(fd, b"exit\r")
            read_until(fd, output, None, 1)
        finally:
            stop(pid)
            os.close(fd)

    check(shell, output.decode("utf-8", "replace"), expected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("shell", choices=SHELLS)
    parser.add_argument("--home", required=True)
    parser.add_argument("--expect", required=True)
    parser.add_argument("--delay", type=float, default=2)
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()
    try:
        run(args.shell, args.home, args.expect, args.delay, args.timeout)
    except (RuntimeError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
