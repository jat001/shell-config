#!/bin/sh
set -eu

check=false
if [ "${1-}" = --check ]; then
    check=true
    shift
fi
bootstrap_ca=${1:-${SHELL_BOOTSTRAP_CA:-}}
changed=false
temporary=
trap '[ -z "$temporary" ] || rm -f -- "$temporary"' EXIT

rewrite() {
    expression=$1
    shift
    for file; do
        [ -f "$file" ] || continue
        file=$(readlink -f -- "$file")
        if "$check"; then
            temporary=$(mktemp)
        else
            temporary=$(mktemp "${file%/*}/.shell-https.XXXXXX")
        fi
        sed -E "$expression" "$file" >"$temporary"
        # Minimal Tumbleweed has coreutils, but does not ship cmp from diffutils.
        original_hash=$(sha256sum <"$file")
        updated_hash=$(sha256sum <"$temporary")
        if [ "$original_hash" != "$updated_hash" ]; then
            changed=true
            if ! "$check"; then
                cp --attributes-only --preserve=all -- "$file" "$temporary"
                mv -f -- "$temporary" "$file"
            fi
        fi
        rm -f -- "$temporary"
        temporary=
    done
}

if command -v pacman >/dev/null 2>&1; then
    rewrite 's@^([[:blank:]]*(Server|CacheServer)[[:blank:]]*=[[:blank:]]*)http://@\1https://@' \
        /etc/pacman.conf /etc/pacman.d/mirrorlist
elif command -v apt-get >/dev/null 2>&1; then
    rewrite 's@^([[:blank:]]*deb(-src)?[[:blank:]]+(\[[^]]*\][[:blank:]]+)?)http://@\1https://@' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list
    rewrite '
        :line
        /^URIs:/I!b
        :uris
        /^[[:blank:]]*#/!s@(^URIs:|[[:blank:]])http://@\1https://@gI
        n
        /^([[:blank:]]|#)/b uris
        b line
    ' /etc/apt/sources.list.d/*.sources
elif command -v zypper >/dev/null 2>&1; then
    # RIS recreates the .repo files from this index when the service refreshes.
    rewrite '/^[[:blank:]]*<!--/!s@((disturl|url|gpgkey)=")http://@\1https://@g' \
        /usr/share/zypp/local/service/openSUSE/repo/repoindex.xml
    rewrite '/^[[:blank:]]*(baseurl|mirrorlist|metalink|gpgkey|url)[[:blank:]]*=/s@([=[:blank:]])http://@\1https://@g' \
        /etc/zypp/repos.d/*.repo /etc/zypp/services.d/*.service
elif command -v dnf >/dev/null 2>&1; then
    rewrite '
        /^[[:blank:]]*(baseurl|mirrorlist|metalink|gpgkey)[[:blank:]]*=/s@([=[:blank:]])http://@\1https://@g
        \@^[[:blank:]]*metalink[[:blank:]]*=[[:blank:]]*https://mirrors\.fedoraproject\.org/metalink\?@ {
            /[?&]protocol=/!s/[[:blank:]]*$/\&protocol=https&/
            s/([?&])protocol=[^&#[:space:]]*/\1protocol=https/
        }
    ' /usr/share/dnf5/repos.d/*.repo /etc/yum.repos.d/*.repo \
        /usr/share/dnf5/repos.override.d/*.repo /etc/dnf/repos.override.d/*.repo
    if "$changed" && ! "$check"; then
        dnf --quiet clean expire-cache >&2
    fi
fi

if command -v apt-get >/dev/null 2>&1 && [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    changed=true
    if ! "$check"; then
        : "${bootstrap_ca:?A CA bundle is required to bootstrap APT over HTTPS}"
        temporary=$(mktemp)
        install -m 644 -- "$bootstrap_ca" "$temporary"
        # _apt must be able to read the bootstrap bundle. Normal APT runs use the system bundle.
        attempt=1
        until apt-get -o "Acquire::https::CAInfo=$temporary" update >&2 &&
            DEBIAN_FRONTEND=noninteractive apt-get -o "Acquire::https::CAInfo=$temporary" \
                install -y --no-install-recommends ca-certificates >&2; do
            [ "$attempt" -lt 3 ] || exit 1
            attempt=$((attempt + 1))
            sleep 10
        done
        [ -s /etc/ssl/certs/ca-certificates.crt ] || update-ca-certificates >&2
        test -s /etc/ssl/certs/ca-certificates.crt
    fi
fi

if "$changed"; then printf '%s\n' repos-https-changed; fi
