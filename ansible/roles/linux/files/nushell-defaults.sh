#!/bin/sh
# Capture the scaffold this nu writes. config reset -w writes nothing unless .config/nushell
# already exists, and it still exits 0. --no-config-file also writes nothing.
# config nu --default is a different embedded file and is not used here.
set -eu

dest=$1
home=$2

rm -rf -- "$dest"
mkdir -p -- "$dest"
command -v nu >/dev/null 2>&1 || exit 0

fingerprint() {
    if [ -f "$1" ]; then
        cksum -- "$1"
    else
        printf 'missing\n'
    fi
}

before=$(fingerprint "$home/.config/nushell/env.nu"; fingerprint "$home/.config/nushell/config.nu")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p -- "$work/.config/nushell"
HOME=$work XDG_CONFIG_HOME=$work/.config nu -c 'config reset -w' || true
after=$(fingerprint "$home/.config/nushell/env.nu"; fingerprint "$home/.config/nushell/config.nu")
if [ "$before" != "$after" ]; then
    printf 'config reset changed the account home\n' >&2
    exit 1
fi
if [ -f "$work/.config/nushell/env.nu" ] && [ -f "$work/.config/nushell/config.nu" ]; then
    cp -a -- "$work/.config/nushell/env.nu" "$work/.config/nushell/config.nu" "$dest/"
fi
