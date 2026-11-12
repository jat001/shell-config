#!/bin/sh
set -eu

mounts=${1:-/proc/self/mounts}
if drive=$(jq -er '.environments.wsl.dev_drive | select(.) | [.mountpoint, .filesystem] | @tsv' \
    "${0%/*}/common.json"); then
    IFS="$(printf '\t')" read -r mountpoint filesystem <<EOF
$drive
EOF
    # The user service requests the mount. Give it a bounded head start before choosing the XDG paths.
    # shellcheck disable=SC2016
    timeout 5s sh -c '
        mounted() {
            while read -r _ target type _; do
                if [ "$target" = "$1" ] && [ "$type" = "$2" ]; then
                    return 0
                fi
            done < "$3"
            return 1
        }
        until mounted "$@"; do sleep 0.1; done
    ' sh "$mountpoint" "$filesystem" "$mounts" || :
fi

cat "$mounts"
