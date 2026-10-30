from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]


class InvariantTests(unittest.TestCase):
    def test_arch_keys_are_populated_before_they_are_signed(self):
        packages = (root / 'ansible/roles/linux/tasks/packages_archlinux.yml').read_text(encoding='utf-8')
        populate = packages.index('argv: [pacman-key, --populate, archlinux]')
        sign = packages.index('argv: [pacman-key, --lsign-key, farseerfc@archlinux.org]')
        self.assertLess(populate, sign)
        bootstrap = (root / 'ansible/bootstrap/wsl.sh').read_text(encoding='utf-8')
        self.assertIn('pacman-key --init && pacman-key --populate archlinux', bootstrap)
        self.assertNotIn('lsign-key', bootstrap)
        startup = (root / 'ansible/roles/linux/tasks/main.yml').read_text(encoding='utf-8')
        self.assertIn('pacman-key --init && $sudo pacman-key --populate archlinux', startup)
        self.assertNotIn('lsign-key', startup)

    def test_debian_bootstrap_installs_ca_certificates_before_ansible_uses_https(self):
        bootstrap = (root / 'ansible/bootstrap/wsl.sh').read_text(encoding='utf-8')
        reason = bootstrap.index('Ansible then downloads signing keys over HTTPS')
        install = bootstrap.index('ca-certificates openssh-server python3 python3-apt btrfs-progs')
        self.assertLess(reason, install)

    def test_mirrored_networking_is_applied_before_sshd_listens_on_loopback(self):
        installer = (root / 'install.ps1').read_text(encoding='utf-8')
        shutdown = installer.index('& $wsl --shutdown')
        listen = installer.index("'127.0.0.1', $key")
        self.assertLess(shutdown, listen)
        self.assertIn('NAT forwards only the default distribution', installer)

    def test_sandbox_network_avoids_the_hyperv_pool_and_wsb_uses_a_launcher(self):
        runner = (root / 'tests/run.ps1').read_text(encoding='utf-8')
        self.assertIn("$networkSubnet = '10.77.90.0/24'", runner)
        self.assertIn("'--subnet', $networkSubnet", runner)
        self.assertIn("-c 'C:\\shell-test\\launch.cmd'", runner)
        self.assertIn('ErrorActionPreference = \'Continue\'', runner)


if __name__ == '__main__':
    unittest.main()
