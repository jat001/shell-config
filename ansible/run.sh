#!/bin/sh
set -eu

# The key is created on the host and mounted at /state. A missing key still allows a play that does not use SSH.
mkdir -p -m 700 /root/.ssh
if [ -f /state/id_ed25519 ]; then
    install -m 600 /state/id_ed25519 /root/.ssh/shell-ansible
fi
touch /state/known_hosts
ln -sf /state/known_hosts /root/.ssh/known_hosts

cd "$(dirname -- "$0")"
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
playbook=${SHELL_PLAYBOOK:-site.yml}
exec ansible-playbook "$playbook" "$@"
