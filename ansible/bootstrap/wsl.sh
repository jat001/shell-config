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

# python3-apt lets the apt module run in check mode, which cannot install it on demand.
# A clean Debian image has no CA bundle. Ansible then downloads signing keys over HTTPS.
if ! command -v mkfs.btrfs >/dev/null 2>&1 ||
    ! command -v python3 >/dev/null 2>&1 ||
    { ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; } ||
    { command -v apt-get >/dev/null 2>&1 && ! python3 -c 'import apt' 2>/dev/null; } ||
    { command -v apt-get >/dev/null 2>&1 && ! dpkg -s ca-certificates >/dev/null 2>&1; }; then
    if command -v pacman >/dev/null 2>&1; then
        [ -s /etc/pacman.d/gnupg/pubring.gpg ] ||
            { pacman-key --init && pacman-key --populate archlinux; } >&2
        retry pacman -Syu --needed --noconfirm openssh python btrfs-progs >&2
    elif command -v apt-get >/dev/null 2>&1; then
        retry apt-get update >&2
        DEBIAN_FRONTEND=noninteractive retry apt-get install -y --no-install-recommends \
            ca-certificates openssh-server python3 python3-apt btrfs-progs >&2
    else
        printf 'Unsupported distribution.\n' >&2
        exit 1
    fi
fi

mkdir -p -m 700 "$directory" /run/sshd
[ -f "$directory/host_ed25519" ] ||
    ssh-keygen -q -t ed25519 -N '' -C shell-ansible -f "$directory/host_ed25519"
printf '%s\n' "$key" > "$directory/authorized_keys"
chmod 600 "$directory/authorized_keys"

cat > "$directory/sshd_config" <<EOF
Port $port
ListenAddress $address
HostKey $directory/host_ed25519
AuthorizedKeysFile $directory/authorized_keys
PidFile $directory/sshd.pid
PermitRootLogin prohibit-password
AllowUsers root
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
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
        printf 'WSLENV=${WSLENV:+$WSLENV:}PSModulePath\n'
        printf 'export PSModulePath WSLENV\n'
        printf 'exec %s "$@"\n' "'$powershell'"
    } > "$directory/bin/PowerShell"
    chmod 755 "$directory/bin/PowerShell"
    ln -sf PowerShell "$directory/bin/powershell"
    printf 'SetEnv PATH=%s/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
        "$directory" >> "$directory/sshd_config"
fi

sshd=$(command -v sshd || printf /usr/sbin/sshd)
"$sshd" -t -f "$directory/sshd_config"
# The next Windows process is a new distribution instance, so /run may already be gone.
cat > "$directory/start-sshd.sh" <<EOF
#!/bin/sh
mkdir -p -m 700 /run/sshd
exec $sshd -D -e -f $directory/sshd_config
EOF
chmod 755 "$directory/start-sshd.sh"
printf '%s\n' "$sshd"
