#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
configuration=$repository/common.json
drive=$(jq -c '.environments.wsl.dev_drive // null' "$configuration")
[ "$drive" != null ] || exit 0
mountpoint=$(printf '%s' "$drive" | jq -er '.mountpoint')
filesystem=$(printf '%s' "$drive" | jq -er '.filesystem')
# Kept off the drive: it is read before the drive is mounted.
state=$HOME/.local/state/shell/dev-drive.uuid
uuid=$(cat "$state" 2>/dev/null || true)
task=$(printf '%s' "$drive" | jq -er '.task')
schtasks=$(printf '%s' "$drive" | jq -er '.schtasks')

check_mount() {
    actual=$(findmnt -rn -M "$mountpoint" -o UUID,FSTYPE) || return 1
    actual_uuid=${actual%% *}
    if [ "${actual#* }" != "$filesystem" ] || [ -z "$actual_uuid" ] ||
        { [ -n "$uuid" ] && [ "$actual_uuid" != "$uuid" ]; }; then
        printf 'Unexpected filesystem at %s: %s\n' "$mountpoint" "$actual" >&2
        [ -z "$uuid" ] || printf 'Expected UUID %s from %s\n' "$uuid" "$state" >&2
        exit 1
    fi
    if [ -z "$uuid" ]; then
        uuid=$actual_uuid
        mkdir -p "$(dirname -- "$state")"
        printf '%s\n' "$uuid" > "$state"
        printf 'Recorded development drive UUID in %s\n' "$state"
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
