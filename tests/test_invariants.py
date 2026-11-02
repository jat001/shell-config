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

    def test_controller_build_retries_and_reuses_a_saved_image(self):
        installer = (root / 'install.ps1').read_text(encoding='utf-8')
        self.assertIn('function Invoke-ControllerBuild', installer)
        self.assertEqual(installer.count('Invoke-ControllerBuild @('), 2)
        self.assertIn("Join-Path $CacheDirectory 'images'", installer)

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
    def test_profiles_preserve_release_steps_and_shared_cache_forwarding(self):
        runner = (root / 'tests/run.ps1').read_text(encoding='utf-8')
        hyperv = (root / 'tests/hyperv.ps1').read_text(encoding='utf-8')
        for text in (runner, hyperv):
            self.assertIn("[string]$Profile = 'full'", text)
        self.assertIn("fast = @('init', 'prepare', 'full', 'verify')", runner)
        self.assertIn("standard = @('init', 'prepare', 'full', 'idempotence', 'verify', 'unprivileged')", runner)
        self.assertIn("full = @('init', 'prepare', 'full', 'idempotence', 'update', 'verify', 'unprivileged')", runner)
        self.assertIn("fast = @('init', 'full')", hyperv)
        self.assertIn("standard = @('init', 'full', 'full')", hyperv)
        self.assertIn("full = @('init', 'full', 'full', 'update')", hyperv)
        self.assertIn('-CacheDirectory $CacheDirectory', runner)
        self.assertEqual(runner.count('CacheDirectory = $CacheDirectory'), 3)

    def test_bash_entry_ignores_repeated_sourcing(self):
        entry = (root / 'common.bash').read_text(encoding='utf-8')
        self.assertIn('[ -n "${_shell_bash_loaded-}" ] && return 0', entry)

    def test_hyperv_cold_boot_flushes_winlogon_key(self):
        actions = (root / 'tests/hyperv_actions.ps1').read_text(encoding='utf-8')
        self.assertIn('SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon', actions)

    def test_hyperv_msys2_probe_checks_lc_all_in_interactive_shells(self):
        verify = (root / 'tests/hyperv_verify.ps1').read_text(encoding='utf-8')
        self.assertIn("bash -ic 'alias code && command -v oh-my-posh && test", verify)


        bootstrap = (root / 'ansible/bootstrap/wsl.sh').read_text(encoding='utf-8')
        self.assertIn('zypper --non-interactive install --no-recommends', bootstrap)
        self.assertIn("printf '%s\\n' \\$\\$ > $directory/sshd.pid", bootstrap)
        user = (root / 'ansible/roles/linux/tasks/user.yml').read_text(encoding='utf-8')
        self.assertIn("create_home: \"{{ ansible_facts.os_family != 'Suse' }}\"", user)
        self.assertIn("Create SUSE WSL user home", user)
        regional = (root / 'ansible/roles/linux/tasks/regional.yml').read_text(encoding='utf-8')
        self.assertIn("when: ansible_facts.os_family != 'Suse'", regional)
        self.assertIn("Require host locale support on SUSE", regional)

    def test_debian_testing_is_test_only_and_sandbox_cache_stays_in_guest(self):
        installer = (root / 'install.ps1').read_text(encoding='utf-8')
        bootstrap = (root / 'ansible/bootstrap/wsl.sh').read_text(encoding='utf-8')
        guest = (root / 'tests/hyperv_guest.ps1').read_text(encoding='utf-8')
        runner = (root / 'tests/run.ps1').read_text(encoding='utf-8')
        self.assertIn('[switch]$TestDebianTesting', installer)
        self.assertIn("@('env', 'SHELL_DEBIAN_TESTING=1')", installer)
        self.assertIn("ContainsKey('CacheDirectory') -and -not $Inventory", installer)
        self.assertIn('SHELL_DEBIAN_TESTING:-0', bootstrap)
        self.assertIn('apt-get full-upgrade -y', bootstrap)
        self.assertIn('*/shell-*) continue', bootstrap)
        self.assertIn('debian-testing-complete', bootstrap)
        self.assertIn('-TestDebianTesting', guest)
        self.assertIn("shell_download_cache = 'C:\\shell-cache'", runner)


if __name__ == '__main__':
    unittest.main()
