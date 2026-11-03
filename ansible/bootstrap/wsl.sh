#!/bin/sh
set -eu

port=$1
address=$2
key=$3
powershell=${4-}
workdir=${5-}
modules=${6-}
directory=/etc/shell-ansible

retry() {
    attempt=1
    until "$@"; do
        [ "$attempt" -lt 3 ] || return 1
        attempt=$((attempt + 1))
        sleep 10
    done
}

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this bootstrap as root.\n' >&2
    exit 1
fi

if [ "${SHELL_DEBIAN_TESTING:-0}" = 1 ] && command -v apt-get >/dev/null 2>&1 && [ -f /etc/debian_version ]; then
    source=/etc/apt/sources.list.d/debian.sources
    marker=$directory/debian-testing-complete
    if [ ! -f "$marker" ] || ! grep -q '^Suites: testing testing-updates$' "$source" 2>/dev/null; then
        mkdir -p -m 700 "$directory" /etc/apt/sources.list.d
        for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$file" ] || continue
            case "$file" in */shell-*) continue ;; esac
            if [ "$file" != "$source" ] && {
                [ "$file" = /etc/apt/sources.list ] || grep -Eq 'deb\.debian\.org|security\.debian\.org' "$file"
            }; then
                : >"$file"
            fi
        done
        cat >"$source.tmp" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: testing testing-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: testing-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
        mv "$source.tmp" "$source"
        retry apt-get update >&2
        DEBIAN_FRONTEND=noninteractive retry apt-get full-upgrade -y >&2
        touch "$marker"
    fi
fi

# python3-apt lets the apt module run in check mode, which cannot install it on demand.
# A clean Debian image has no CA bundle. Ansible then downloads signing keys over HTTPS.
# A clean openSUSE image has no Python, sshd or btrfs tools.
# A clean Fedora image has no sshd or btrfs tools, and Ansible's dnf5 module needs the libdnf5 bindings.
if ! command -v mkfs.btrfs >/dev/null 2>&1 ||
    ! command -v python3 >/dev/null 2>&1 ||
    { ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; } ||
    { command -v apt-get >/dev/null 2>&1 && ! python3 -c 'import apt' 2>/dev/null; } ||
    { command -v apt-get >/dev/null 2>&1 && ! dpkg -s ca-certificates >/dev/null 2>&1; } ||
    { command -v dnf >/dev/null 2>&1 && ! python3 -c 'import libdnf5' 2>/dev/null; }; then
    if command -v pacman >/dev/null 2>&1; then
        [ -s /etc/pacman.d/gnupg/pubring.gpg ] ||
            { pacman-key --init && pacman-key --populate archlinux; } >&2
        retry pacman -Syu --needed --noconfirm openssh python btrfs-progs >&2
    elif command -v apt-get >/dev/null 2>&1; then
        retry apt-get update >&2
        DEBIAN_FRONTEND=noninteractive retry apt-get install -y --no-install-recommends \
            ca-certificates openssh-server python3 python3-apt btrfs-progs >&2
    elif command -v zypper >/dev/null 2>&1; then
        retry zypper --non-interactive refresh >&2
        retry zypper --non-interactive install --no-recommends \
            ca-certificates openssh python3 btrfsprogs >&2
    elif command -v dnf >/dev/null 2>&1; then
        retry dnf --assumeyes --setopt=install_weak_deps=False install \
            ca-certificates openssh-server python3 python3-libdnf5 btrfs-progs >&2
    else
        printf 'Unsupported distribution.\n' >&2
        exit 1
    fi
fi

mkdir -p -m 700 "$directory" /run/sshd
[ -f "$directory/host_ed25519" ] ||
    ssh-keygen -q -t ed25519 -N '' -C shell-ansible -f "$directory/host_ed25519"
printf '%s\n' "$key" >"$directory/authorized_keys"
chmod 600 "$directory/authorized_keys"

# Fedora's OpenSSH build rejects "UsePAM no", and its root account is shadow-locked.
# The PAM account check accepts the key login that the non-PAM path refuses.
usepam=no
command -v dnf >/dev/null 2>&1 && usepam=yes
cat >"$directory/sshd_config" <<EOF
Port $port
ListenAddress $address
HostKey $directory/host_ed25519
AuthorizedKeysFile $directory/authorized_keys
PidFile $directory/sshd.pid
PermitRootLogin prohibit-password
AllowUsers root
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM $usepam
Subsystem sftp internal-sftp
EOF

# The wrapper exists only on the distribution that also serves Windows. Other distributions stay ordinary SSH targets.
if [ -n "$powershell" ]; then
    if [ ! -x "$powershell" ] || ! "$powershell" -NoProfile -Command exit >/dev/null 2>&1; then
        printf 'WSL interop cannot start %s.\n' "$powershell" >&2
        exit 1
    fi
    mkdir -p "$directory/bin"
    {
        printf '#!/bin/sh\n'
        printf 'cd %s || exit 1\n' "'$workdir'"
        printf 'PSModulePath=%s\n' "'$modules'"
        # The generated wrapper keeps the expansion for the target shell.
        # shellcheck disable=SC2016
        printf 'WSLENV=${WSLENV:+$WSLENV:}PSModulePath\n'
        printf 'export PSModulePath WSLENV\n'
        printf 'exec %s "$@"\n' "'$powershell'"
    } >"$directory/bin/PowerShell"
    chmod 755 "$directory/bin/PowerShell"
    ln -sf PowerShell "$directory/bin/powershell"
    printf 'SetEnv PATH=%s/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
        "$directory" >>"$directory/sshd_config"
fi

sshd=$(command -v sshd || printf /usr/sbin/sshd)
"$sshd" -t -f "$directory/sshd_config"
# The next Windows process is a new distribution instance, so /run may already be gone.
# OpenSSH 10.6 on openSUSE does not write PidFile with -D; the script records the process it execs instead.
cat >"$directory/start-sshd.sh" <<EOF
#!/bin/sh
mkdir -p -m 700 /run/sshd
printf '%s\n' \$\$ > $directory/sshd.pid
exec $sshd -D -e -f $directory/sshd_config
EOF
chmod 755 "$directory/start-sshd.sh"
printf '%s\n' "$sshd"
