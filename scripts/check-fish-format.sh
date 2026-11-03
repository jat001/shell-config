#!/bin/sh
set -eu

failed=0
for file in "$@"; do
    if ! fish_indent "$file" | cmp -s "$file" -; then
        printf '%s: not formatted by fish_indent\n' "$file" >&2
        failed=1
    fi
done

exit "$failed"
