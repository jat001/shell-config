#!/bin/sh
# Run only in a disposable container, through tests/run.ps1.
set -eu

script=/work/ansible/bootstrap/repos-https.sh
if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    mkdir -p /etc/ssl/certs
    install -m 644 /bootstrap-ca/bundle.pem /etc/ssl/certs/ca-certificates.crt
fi

if command -v pacman >/dev/null 2>&1; then
    source=/etc/pacman.conf
    cat >>"$source" <<'EOF'

[archlinuxcn]
Include = /etc/pacman.d/archlinuxcn-mirrorlist
EOF
    # shellcheck disable=SC2016
    printf 'Server = http://repo.archlinuxcn.org/$arch\n' >/etc/pacman.d/archlinuxcn-mirrorlist
elif command -v apt-get >/dev/null 2>&1; then
    source=/etc/apt/sources.list.d/shell-cernet-test.sources
    cat >"$source" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
 https://security.debian.org/debian-security
Suites: testing
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp

# URIs: https://deb.debian.org/debian
EOF
elif command -v dnf >/dev/null 2>&1; then
    source=/etc/dnf/repos.override.d/90-shell-cernet.repo
else
    source=/etc/zypp/repos.d/shell-cernet-test.repo
    cat >"$source" <<'EOF'
[shell-cernet-test]
name=CERNET test
enabled=0
autorefresh=0
baseurl=https://cdn.opensuse.org/tumbleweed/repo/oss
gpgcheck=1
EOF
    index=/usr/share/zypp/local/service/openSUSE/repo
    mkdir -p "$index"
    cat >"$index/test.xml" <<'EOF'
<repoindex ttl="0" disturl="http://cdn.opensuse.org/ports/aarch64" distsub="tumbleweed">
<repo url="%{disturl}/%{distsub}/repo/oss"
alias="cernet-test" enabled="false" gpgcheck="true"/>
</repoindex>
EOF
    ln -sf test.xml "$index/repoindex.xml"
    test "$(sh "$script" --check --cernet)" = repos-https-changed
fi

sh "$script" >/dev/null
if [ -f "$source" ]; then
    original=$(sha256sum <"$source")
else
    original=absent
fi
test "$(sh "$script" --check --cernet)" = repos-https-changed
if [ "$original" = absent ]; then
    test ! -e "$source"
else
    test "$original" = "$(sha256sum <"$source")"
fi
test "$(sh "$script" --cernet)" = repos-https-changed
test -z "$(sh "$script" --check --cernet)"
test -z "$(sh "$script" --cernet)"
test -z "$(SHELL_CERNET_KEEP=1 sh "$script")"

if command -v pacman >/dev/null 2>&1; then
    pacman-conf --repo core CacheServer | grep -q '^https://mirrors.cernet.edu.cn/archlinux/'
    pacman-conf --repo core Server | grep -q '^https://'
    pacman-conf --repo archlinuxcn CacheServer | grep -q '^https://mirrors.cernet.edu.cn/archlinuxcn/'
    test "$(pacman-conf --repo archlinuxcn Server)" = 'https://repo.archlinuxcn.org/x86_64'
elif command -v apt-get >/dev/null 2>&1; then
    grep -q '^URIs: mirror+https://mirrors.cernet.edu.cn/api/apt/mirrorlist/debian$' "$source"
    grep -q '^ mirror+https://mirrors.cernet.edu.cn/api/apt/mirrorlist/debian-security?official_index=1$' "$source"
    grep -q '^# URIs: https://deb.debian.org/debian$' "$source"
elif command -v dnf >/dev/null 2>&1; then
    grep -q '^metalink=$' "$source"
    grep -q '^mirrorlist=https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/fedora/releases/' "$source"
else
    test -L "$index/repoindex.xml"
    grep -q 'shellcernet="https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/opensuse/ports/aarch64"' "$index/test.xml"
    grep -q 'mirrorlist="%{shellcernet}/%{distsub}/repo/oss"' "$index/test.xml"
    grep -q '^mirrorlist=https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/opensuse/tumbleweed/repo/oss$' "$source"
    mkdir -p /etc/zypp/services.d
    cat >/etc/zypp/services.d/shell-cernet-test.service <<'EOF'
[shell-cernet-test]
enabled=1
autorefresh=0
type=ris
url=dir:/usr/share/zypp/local/service/openSUSE
EOF
    zypper --non-interactive refresh-services --force shell-cernet-test
    generated=/etc/zypp/repos.d/shell-cernet-test:cernet-test.repo
    grep -q '^mirrorlist=https://mirrors.cernet.edu.cn/api/rpm/mirrorlist/opensuse/ports/aarch64/tumbleweed/repo/oss$' "$generated"
    test -z "$(sh "$script" --check --cernet)"
fi

test "$(sh "$script" --check)" = repos-https-changed
test "$(sh "$script")" = repos-https-changed
test -z "$(sh "$script" --check)"
test -z "$(sh "$script")"
test -z "$(SHELL_USE_CERNET=1 sh "$script" --check --official)"
if [ "$original" = absent ]; then
    test ! -e "$source"
else
    test "$original" = "$(sha256sum <"$source")"
fi

if command -v pacman >/dev/null 2>&1; then
    test "$(pacman-conf --repo archlinuxcn Server)" = 'https://repo.archlinuxcn.org/x86_64'
fi

if command -v dnf >/dev/null 2>&1; then
    printf 'unmanaged\n' >"$source"
    printf '[custom]\nbaseurl=http://example.invalid/\n' >/etc/yum.repos.d/cernet-conflict.repo
    if sh "$script" --cernet 2>/tmp/cernet-conflict.log; then
        echo 'An unmanaged override was overwritten.' >&2
        exit 1
    fi
    test "$(cat "$source")" = unmanaged
    grep -q '^baseurl=http://example.invalid/' /etc/yum.repos.d/cernet-conflict.repo
    rm -f "$source"
    ln -s /tmp/cernet-missing "$source"
    if sh "$script" --cernet 2>/tmp/cernet-conflict.log; then
        echo 'A dangling override symlink was overwritten.' >&2
        exit 1
    fi
    test -L "$source"
    test ! -e /tmp/cernet-missing
elif command -v pacman >/dev/null 2>&1; then
    printf '\n# BEGIN shell-ansible CERNET\nuser data\n' >>"$source"
    original=$(sha256sum <"$source")
    if sh "$script" --cernet 2>/tmp/cernet-conflict.log; then
        echo 'A malformed CERNET block was overwritten.' >&2
        exit 1
    fi
    test "$original" = "$(sha256sum <"$source")"
fi
echo 'CERNET preview, enable, idempotence and disable passed.'
