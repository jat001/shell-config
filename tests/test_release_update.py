import hashlib
import importlib.util
import io
from pathlib import Path
import platform
import tarfile
import tempfile
import unittest
from unittest.mock import patch


source = Path(__file__).resolve().parents[1] / 'ansible/roles/linux/files/release-update.py'
spec = importlib.util.spec_from_file_location('release_update', source)
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class Response(io.BytesIO):
    def __init__(self, data=b'', url='https://github.com/owner/project/releases/tag/v2.0.0', length=None):
        super().__init__(data)
        self.url = url
        self.headers = {} if length is None else {'Content-Length': str(length)}


def elf():
    header = bytearray(120)
    header[:6] = b'\x7fELF\x02\x01'
    header[18:20] = {'x86_64': 62, 'aarch64': 183}[platform.machine()].to_bytes(2, 'little')
    header[32:40] = (64).to_bytes(8, 'little')
    header[54:56] = (56).to_bytes(2, 'little')
    header[56:58] = (1).to_bytes(2, 'little')
    return bytes(header)


class ReleaseUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.manifest = {key: str(self.directory / key) for key in ('root', 'bin', 'cache')}
        self.item = {'name': 'shell-test-app', 'command': 'shell-test-app',
                     'repository': 'owner/project', 'asset': 'program'}
        self.release = ('v2.0.0', '2.0.0', 'program', 'https://example.test')

    def managed_installation(self):
        binary = Path(self.manifest['root']) / self.item['name'] / 'v1.0.0' / self.item['command']
        binary.parent.mkdir(parents=True)
        binary.write_bytes(elf())
        link = Path(self.manifest['bin']) / self.item['command']
        link.parent.mkdir(parents=True)
        link.symlink_to(binary)
        return link, binary

    def test_external_installation_is_not_taken_over(self):
        with patch.object(updater.shutil, 'which', return_value='/usr/bin/external'), \
                patch.object(updater, 'latest_asset') as latest:
            self.assertEqual(updater.update_item(self.item, self.manifest, True, False), 'external')
            latest.assert_not_called()

    def test_timer_does_not_reinstall_removed_programs(self):
        with patch.object(updater.shutil, 'which', return_value=None), \
                patch.object(updater, 'latest_asset') as latest:
            self.assertEqual(updater.update_item(self.item, self.manifest, True, False, True), 'unchanged')
            latest.assert_not_called()

    def test_invalid_binary_keeps_the_working_link(self):
        link, old = self.managed_installation()
        bad = self.directory / 'bad'
        bad.write_bytes(b'<!DOCTYPE html>')
        with patch.object(updater, 'latest_asset', return_value=self.release), \
                patch.object(updater, 'cached_download', return_value=bad):
            with self.assertRaisesRegex(ValueError, 'ELF'):
                updater.update_item(self.item, self.manifest, True, False)
        self.assertEqual(link.resolve(), old)
        self.assertTrue(old.exists())

    def test_successful_update_keeps_previous_release(self):
        link, old = self.managed_installation()
        binary = self.directory / 'new'
        binary.write_bytes(elf())
        with patch.object(updater, 'latest_asset', return_value=self.release), \
                patch.object(updater, 'cached_download', return_value=binary):
            self.assertEqual(updater.update_item(self.item, self.manifest, True, False), 'changed')
        self.assertEqual(link.resolve().parent.name, 'v2.0.0')
        self.assertTrue(old.exists())

    def test_restart_failure_restores_previous_link(self):
        link, old = self.managed_installation()
        binary = self.directory / 'new'
        binary.write_bytes(elf())
        release = ('v2.0.0', '2.0.0', 'program', 'https://example.test')
        with patch.object(updater, 'latest_asset', return_value=release), \
                patch.object(updater, 'cached_download', return_value=binary), \
                patch.object(updater, 'restart_user_units', side_effect=RuntimeError('restart failed')):
            with self.assertRaisesRegex(RuntimeError, 'restart failed'):
                updater.update_item(self.item, self.manifest, True, False)
        self.assertEqual(link.resolve(), old)
        self.assertTrue(old.exists())

    def test_check_does_not_write_or_download(self):
        link, old = self.managed_installation()
        with patch.object(updater, 'latest_asset', return_value=self.release), \
                patch.object(updater, 'cached_download') as download:
            self.assertEqual(updater.update_item(self.item, self.manifest, True, True), 'changed')
            download.assert_not_called()
        self.assertEqual(link.resolve(), old)
        self.assertFalse(Path(self.manifest['cache']).exists())

    def test_cached_download_reuse_and_corruption_detection(self):
        with patch.object(updater, 'request', return_value=Response(b'valid', length=5)) as network:
            path = updater.cached_download(self.directory / 'cache', 'asset', 'https://example.test')
            self.assertEqual(updater.cached_download(path.parent, 'asset', 'https://example.test'), path)
            self.assertEqual(network.call_count, 1)
        path.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            updater.cached_download(path.parent, 'asset', 'https://example.test')

    def test_incomplete_download_is_not_published(self):
        with patch.object(updater, 'request', return_value=Response(b'partial', length=100)):
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                updater.cached_download(self.directory / 'cache', 'asset', 'https://example.test')
        self.assertFalse((self.directory / 'cache/asset').exists())

    def test_published_checksum_is_required_to_match(self):
        with patch.object(updater, 'request', return_value=Response(b'valid', length=5)):
            digest = hashlib.sha256(b'valid').hexdigest()
            path = updater.cached_download(self.directory / 'cache', 'asset', 'https://example.test', digest)
            self.assertEqual(path.read_bytes(), b'valid')
        with patch.object(updater, 'request', return_value=Response(b'changed', length=7)):
            with self.assertRaisesRegex(ValueError, 'published SHA256'):
                updater.cached_download(self.directory / 'other', 'asset', 'https://example.test', digest)
        self.assertFalse((self.directory / 'other/asset').exists())

    def test_archive_cannot_escape_staging_directory(self):
        path = self.directory / 'bad.tar'
        with tarfile.open(path, 'w') as archive:
            member = tarfile.TarInfo('../outside')
            member.size = 1
            archive.addfile(member, io.BytesIO(b'x'))
        with self.assertRaises((ValueError, tarfile.TarError)):
            updater.extract_archive(path, self.directory / 'stage')
        self.assertFalse((self.directory / 'outside').exists())

    def test_obsolete_deb_manifest_is_not_executed(self):
        item = {**self.item, 'kind': 'deb'}
        with patch.object(updater, 'latest_asset') as latest:
            with self.assertRaisesRegex(ValueError, 'installation format'):
                updater.update_item(item, self.manifest, True, False)
            latest.assert_not_called()

    def test_binary_update_never_downgrades(self):
        self.managed_installation()
        release = ('v0.9.0', '0.9.0', 'program', 'https://example.test')
        with patch.object(updater, 'latest_asset', return_value=release), \
                patch.object(updater, 'cached_download') as download:
            self.assertEqual(updater.update_item(self.item, self.manifest, True, False), 'unchanged')
            download.assert_not_called()

    def test_asset_url_uses_the_expected_official_repository(self):
        item = {**self.item, 'asset': 'program-{version}-amd64'}
        with patch.object(updater, 'request', return_value=Response()):
            tag, version, filename, url = updater.latest_asset(item)
        self.assertEqual((tag, version, filename), ('v2.0.0', '2.0.0', 'program-2.0.0-amd64'))
        self.assertEqual(url, 'https://github.com/owner/project/releases/download/v2.0.0/program-2.0.0-amd64')

    def test_unexpected_redirect_is_rejected(self):
        response = Response(url='https://evil.test/owner/project/releases/tag/v2.0.0')
        with patch.object(updater, 'request', return_value=response):
            with self.assertRaisesRegex(ValueError, 'redirect'):
                updater.latest_asset(self.item)

if __name__ == '__main__':
    unittest.main()
