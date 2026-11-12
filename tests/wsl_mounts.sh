#!/bin/sh
set -eu

probe="${0%/*}/../wsl-mounts.sh"
work=$(mktemp -d)
trap 'rm -f "$work/mounts" "$work/ready" "$work/result"; rmdir "$work"' EXIT
wrong='/dev/sdx /mnt/wsl/dev ext4 rw 0 0'
ready='/dev/sdx /mnt/wsl/dev btrfs rw 0 0'
printf '%s\n' "$wrong" >"$work/mounts"
printf '%s\n' "$ready" >"$work/ready"

sh "$probe" "$work/mounts" >"$work/result" &
waiter=$!
sleep 0.3
if ! kill -0 "$waiter" 2>/dev/null; then
    printf 'The mount check returned before the expected filesystem appeared.\n' >&2
    exit 1
fi
mv "$work/ready" "$work/mounts"
wait "$waiter"
test "$(cat "$work/result")" = "$ready"

# An already mounted drive must not wait. A wrong filesystem must still return a snapshot on timeout.
result=$(timeout 3s sh "$probe" "$work/mounts")
test "$result" = "$ready"
printf '%s\n' "$wrong" >"$work/mounts"
result=$(timeout 8s sh "$probe" "$work/mounts")
test "$result" = "$wrong"
