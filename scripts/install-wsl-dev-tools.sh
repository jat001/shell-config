#!/bin/sh
set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if command -v pacman >/dev/null 2>&1; then
    prepare() { :; }
    install() { sudo pacman -S --needed --noconfirm "$1"; }
elif command -v apt-get >/dev/null 2>&1; then
    prepare() { sudo apt-get update; }
    install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"; }
elif command -v zypper >/dev/null 2>&1; then
    prepare() { :; }
    install() { sudo zypper --non-interactive install "$1"; }
else
    printf 'Unsupported WSL distribution: pacman, apt-get and zypper are all missing.\n' >&2
    exit 1
fi

prepared=0
for package in ansible-lint fish zsh; do
    if command -v "$package" >/dev/null 2>&1; then
        continue
    fi
    if [ "$prepared" -eq 0 ]; then
        prepare
        prepared=1
    fi
    install "$package"
done

for package in ansible-lint fish zsh; do
    command -v "$package" >/dev/null 2>&1
done

attempt=1
while ! ansible-galaxy collection install -r "$repository/ansible/requirements.yml"; do
    [ "$attempt" -lt 3 ] || exit 1
    attempt=$((attempt + 1))
    sleep 10
done
