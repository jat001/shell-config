#!/usr/bin/env python3
import json
import os
import stat
import sys
import tempfile


def main():
    path = sys.argv[1]
    required = json.loads(os.environ["SHELL_REQUIRED_LOCALES"])
    required_set = set(required)
    check_mode = os.environ.get("SHELL_CHECK_MODE", "").lower() == "true"
    try:
        with open(path, encoding="utf-8", newline="") as source:
            lines = source.readlines()
        changed = os.name == "posix" and stat.S_IMODE(os.stat(path).st_mode) != 0o644
    except FileNotFoundError:
        lines = []
        changed = True

    seen = set()
    output = []
    for line in lines:
        stripped = line.strip()
        commented = stripped.startswith("#")
        fields = (stripped[1:].strip() if commented else stripped).split()
        if len(fields) == 2 and fields[0] in required_set and fields[1] == "UTF-8":
            locale = fields[0]
            if locale in seen:
                if not commented:
                    changed = True
                    continue
            else:
                seen.add(locale)
                normalized = f"{locale} UTF-8\n"
                if line != normalized:
                    changed = True
                line = normalized
        output.append(line)

    for locale in required:
        if locale not in seen:
            output.append(f"{locale} UTF-8\n")
            changed = True

    if changed and not check_mode:
        fd, temporary = tempfile.mkstemp(prefix=".locale.gen.", dir=os.path.dirname(path), text=True)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as destination:
                destination.writelines(output)
            if os.name == "posix":
                os.chmod(temporary, 0o644)
            os.replace(temporary, path)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
    print("changed" if changed else "unchanged")


if __name__ == "__main__":
    main()
