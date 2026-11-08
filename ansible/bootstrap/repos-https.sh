#!/bin/sh
set -eu

check=false
use_cernet=${SHELL_USE_CERNET:-0}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check=true ;;
        --cernet) use_cernet=1 ;;
        --official) use_cernet=0 ;;
        *) break ;;
    esac
    shift
done
case "$use_cernet" in 0 | 1) ;; *)
    echo 'Invalid CERNET selection.' >&2
    exit 1
    ;;
esac
bootstrap_ca=${1:-${SHELL_BOOTSTRAP_CA:-}}
changed=false
temporary=
staged=
trap '[ -z "$temporary" ] || rm -f -- "$temporary"; [ -z "$staged" ] || rm -f -- "$staged"' EXIT

rewrite() {
    rewrite_expression=$1
    shift
    for file; do
        [ -f "$file" ] || continue
        file=$(readlink -f -- "$file")
        if "$check"; then
            temporary=$(mktemp)
        else
            temporary=$(mktemp "${file%/*}/.shell-https.XXXXXX")
        fi
        sed -E "$rewrite_expression" "$file" >"$temporary"
        # Minimal openSUSE Tumbleweed has coreutils, but does not ship cmp from diffutils.
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

configure_cernet() {
    if command -v pacman >/dev/null 2>&1; then
        block_state=0
        while IFS= read -r line || [ -n "$line" ]; do
            # pacman expands these variables when it reads the configuration.
            # shellcheck disable=SC2016
            case "$line" in
                '# BEGIN shell-ansible CERNET')
                    [ "$block_state" = 0 ] || return 1
                    block_state=1
                    ;;
                'CacheServer = https://mirrors.cernet.edu.cn/archlinux/$repo/os/$arch' | \
                    'CacheServer = https://mirrors.cernet.edu.cn/archlinuxcn/$arch')
                    if [ "$block_state" = 1 ]; then block_state=2; fi
                    ;;
                '# END shell-ansible CERNET')
                    [ "$block_state" = 2 ] || return 1
                    block_state=0
                    ;;
                *)
                    if [ "$block_state" != 0 ]; then
                        echo 'Unrecognized CERNET block in /etc/pacman.conf' >&2
                        return 1
                    fi
                    ;;
            esac
        done </etc/pacman.conf
        [ "$block_state" = 0 ] || return 1
        expression='/^# BEGIN shell-ansible CERNET$/,/^# END shell-ansible CERNET$/d'
        if [ "$use_cernet" = 1 ]; then
            # Probe the installed parser, including on distributions with older pacman.
            supported=$(printf '[shell-probe]\nCacheServer = https://mirrors.cernet.edu.cn/\n' |
                pacman-conf --config /dev/stdin --repo shell-probe CacheServer)
            [ "$supported" = https://mirrors.cernet.edu.cn/ ] || {
                echo 'This pacman does not support CacheServer.' >&2
                return 1
            }
            expression="$expression
                /^\[(core|extra|multilib)\]$/a\\
# BEGIN shell-ansible CERNET\\
CacheServer = https://mirrors.cernet.edu.cn/archlinux/\$repo/os/\$arch\\
# END shell-ansible CERNET
                /^\[archlinuxcn\]$/a\\
# BEGIN shell-ansible CERNET\\
CacheServer = https://mirrors.cernet.edu.cn/archlinuxcn/\$arch\\
# END shell-ansible CERNET"
        fi
        rewrite "$expression" /etc/pacman.conf
    elif command -v apt-get >/dev/null 2>&1; then
        if [ "$use_cernet" = 1 ]; then
            expression='
                s@https?://(deb\.debian\.org/debian-security|security\.debian\.org/debian-security)/?([[:space:]]|$)@mirror+https://mirrors.cernet.edu.cn/api/apt/mirrorlist/debian-security?official_index=1\2@g
                s@https?://deb\.debian\.org/debian/?([[:space:]]|$)@mirror+https://mirrors.cernet.edu.cn/api/apt/mirrorlist/debian\1@g'
        else
            expression='
                s@mirror\+https://mirrors\.cernet\.edu\.cn/api/apt/mirrorlist/debian-security\?official_index=1([[:space:]]|$)@https://security.debian.org/debian-security\1@g
                s@mirror\+https://mirrors\.cernet\.edu\.cn/api/apt/mirrorlist/debian([[:space:]]|$)@https://deb.debian.org/debian\1@g'
        fi
        rewrite "/^[[:blank:]]*deb(-src)?[[:blank:]]/ {$expression
        }" /etc/apt/sources.list /etc/apt/sources.list.d/*.list
        rewrite "
            :line
            /^URIs:/I!b
            :uris
            /^[[:blank:]]*#/! {$expression
            }
            n
            /^([[:blank:]]|#)/b uris
            b line
        " /etc/apt/sources.list.d/*.sources
    elif command -v dnf >/dev/null 2>&1; then
        file=/etc/dnf/repos.override.d/90-shell-cernet.repo
        if [ -e "$file" ] || [ -L "$file" ]; then
            [ -f "$file" ] && [ ! -L "$file" ] &&
                [ "$(head -n 1 "$file")" = '# Managed by shell-ansible CERNET' ] || {
                echo "Unrecognized CERNET override: $file" >&2
                return 1
            }
        fi
        if [ "$use_cernet" = 1 ]; then
            temporary=$(mktemp)
            cat >"$temporary" <<'EOF'
# Managed by shell-ansible CERNET
[fedora]
baseurl=
metalink=
mirrorlist=https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/fedora/releases/$releasever/Everything/$basearch/os

[updates]
baseurl=
metalink=
mirrorlist=https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/fedora/updates/$releasever/Everything/$basearch
EOF
            if [ ! -f "$file" ] || [ "$(sha256sum <"$file")" != "$(sha256sum <"$temporary")" ]; then
                changed=true
                if ! "$check"; then
                    mkdir -p "${file%/*}"
                    staged=$(mktemp "${file%/*}/.shell-cernet.XXXXXX")
                    install -m 644 "$temporary" "$staged"
                    mv -f "$staged" "$file"
                    staged=
                fi
            fi
            rm -f "$temporary"
            temporary=
        elif [ -f "$file" ]; then
            changed=true
            if ! "$check"; then rm -f "$file"; fi
        fi
    elif command -v zypper >/dev/null 2>&1; then
        index=/usr/share/zypp/local/service/openSUSE/repo/repoindex.xml
        if [ "$use_cernet" = 1 ] && [ -f "$index" ] &&
            ! grep -Eq 'disturl="https?://(cdn|download|downloadcontent)\.opensuse\.org(/[^"]*)?"' "$index"; then
            echo "Unrecognized openSUSE Tumbleweed service URL in $index" >&2
            return 1
        fi
        if [ "$use_cernet" = 1 ]; then
            expression='
                /shellcernet=/!s@(disturl="https://(cdn|download|downloadcontent)\.opensuse\.org([^"]*)")@\1 shellcernet="https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/opensuse\3"@
                /mirrorlist=/!s@(<repo[[:blank:]]+url="%\{disturl\}([^"]*)")@\1 mirrorlist="%{shellcernet}\2"@'
        else
            expression='
                s@ mirrorlist="%\{shellcernet\}[^"]*"@@g
                s@ shellcernet="https://mirrors\.cernet\.edu\.cn/api/rpm/mirrorlist/opensuse[^"]*"@@g'
        fi
        rewrite "$expression" "$index"
        for repository in /etc/zypp/repos.d/*.repo; do
            [ -f "$repository" ] || continue
            if [ "$use_cernet" = 1 ]; then
                # A service refresh may already have supplied the mirrorlist.
                if grep -q '^[[:blank:]]*mirrorlist[[:blank:]]*=' "$repository"; then continue; fi
                expression='s@^([[:blank:]]*baseurl[[:blank:]]*=[[:blank:]]*https://(cdn|download|downloadcontent)\.opensuse\.org(/[^[:space:]]*))[[:blank:]]*$@\1\nmirrorlist=https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/opensuse\3@'
            else
                expression='\@^[[:blank:]]*mirrorlist[[:blank:]]*=[[:blank:]]*https://mirrors\.cernet\.edu\.cn/api/rpm/mirrorlist/opensuse(/|$)@d'
            fi
            rewrite "$expression" "$repository"
        done
    fi
}

if ! "$check"; then
    # Check every file and the native parser before changing the first source.
    SHELL_USE_CERNET="$use_cernet" sh "$0" --check "$bootstrap_ca" >/dev/null
fi

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
elif command -v dnf >/dev/null 2>&1; then
    rewrite '
        /^[[:blank:]]*(baseurl|mirrorlist|metalink|gpgkey)[[:blank:]]*=/s@([=[:blank:]])http://@\1https://@g
        \@^[[:blank:]]*metalink[[:blank:]]*=[[:blank:]]*https://mirrors\.fedoraproject\.org/metalink\?@ {
            /[?&]protocol=/!s/[[:blank:]]*$/\&protocol=https&/
            s/([?&])protocol=[^&#[:space:]]*/\1protocol=https/
        }
    ' /usr/share/dnf5/repos.d/*.repo /etc/yum.repos.d/*.repo \
        /usr/share/dnf5/repos.override.d/*.repo /etc/dnf/repos.override.d/*.repo
elif command -v zypper >/dev/null 2>&1; then
    # RIS recreates the .repo files from this index when the service refreshes.
    rewrite '/^[[:blank:]]*<!--/!s@((disturl|url|gpgkey)=")http://@\1https://@g' \
        /usr/share/zypp/local/service/openSUSE/repo/repoindex.xml
    rewrite '/^[[:blank:]]*(baseurl|mirrorlist|metalink|gpgkey|url)[[:blank:]]*=/s@([=[:blank:]])http://@\1https://@g' \
        /etc/zypp/repos.d/*.repo /etc/zypp/services.d/*.service
fi

if [ "${SHELL_CERNET_KEEP:-0}" != 1 ]; then configure_cernet; fi
if command -v dnf >/dev/null 2>&1 && "$changed" && ! "$check"; then
    dnf --quiet clean expire-cache >&2
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
