#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
configuration=$repository/common.json
drive=$(jq -c '.environments.wsl.dev_drive // null' "$configuration")
[ "$drive" != null ] || exit 0
mountpoint=$(printf '%s' "$drive" | jq -er '.mountpoint')
filesystem=$(printf '%s' "$drive" | jq -er '.filesystem')
uuid=$(printf '%s' "$drive" | jq -er '.uuid' | tr '[:upper:]' '[:lower:]')
task=$(printf '%s' "$drive" | jq -er '.task')
schtasks=$(printf '%s' "$drive" | jq -er '.schtasks')

check_mount() {
    actual=$(findmnt -rn -M "$mountpoint" -o UUID,FSTYPE) || return 1
    if [ "$actual" != "$uuid $filesystem" ]; then
        printf 'Unexpected filesystem at %s: %s\n' "$mountpoint" "$actual" >&2
        exit 1
    fi
    printf 'Development drive ready: %s (%s)\n' "$mountpoint" "$uuid"
}

if check_mount; then
    exit 0
fi

if ! "$schtasks" /Run /TN "$task" >/dev/null 2>&1; then
    printf 'Could not request Windows task: %s\n' "$task" >&2
    exit 1
fi

printf 'Requested Windows task: %s\n' "$task"
attempt=0
while [ "$attempt" -lt 60 ]; do
    if check_mount; then
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 1
done

printf 'Timed out waiting for development drive: %s\n' "$mountpoint" >&2
exit 1
