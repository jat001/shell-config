#!/bin/sh
set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v ansible-lint >/dev/null 2>&1; then
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm ansible-lint
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-lint
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive install ansible-lint
    else
        printf 'Unsupported WSL distribution: pacman, apt-get and zypper are all missing.\n' >&2
        exit 1
    fi
fi

command -v ansible-lint >/dev/null 2>&1
attempt=1
while ! ansible-galaxy collection install -r "$repository/ansible/requirements.yml"; do
    [ "$attempt" -lt 3 ] || exit 1
    attempt=$((attempt + 1))
    sleep 10
done
