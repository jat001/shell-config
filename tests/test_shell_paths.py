import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


root = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


filters = load('shell_filter', root / 'ansible/filter_plugins/shell.py')
module_path = root / 'ansible/library/shell_paths.py'


class ShellPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def run_module(self, items, check=False):
        payload = {'ANSIBLE_MODULE_ARGS': {'_ansible_check_mode': check, 'items': items}}
        args = self.directory / 'args.json'
        args.write_text(json.dumps(payload), encoding='utf-8')
        completed = subprocess.run(
            [sys.executable, str(module_path), str(args)],
            capture_output=True, text=True, check=False,
        )
        try:
            result = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise AssertionError(f'{completed.stdout}\n{completed.stderr}') from error
        return completed.returncode, result

    def test_one_conflict_leaves_the_whole_group_untouched(self):
        created = self.directory / 'created'
        kept = self.directory / 'kept'
        kept.write_text('user\n', encoding='utf-8')
        code, result = self.run_module([
            {'path': str(created), 'state': 'file', 'content': 'new'},
            {
                'path': str(kept), 'state': 'link', 'src': str(self.directory / 'target'),
                'type': 'file', 'content': 'managed',
            },
        ])
        self.assertNotEqual(code, 0)
        self.assertIn(str(kept), result['msg'])
        self.assertFalse(created.exists())
        self.assertEqual(kept.read_text(encoding='utf-8'), 'user\n')
        self.assertFalse(kept.is_symlink())

    def test_check_mode_does_not_create(self):
        path = self.directory / 'new'
        code, result = self.run_module(
            [{'path': str(path), 'state': 'file', 'content': 'new'}], check=True,
        )
        self.assertEqual(code, 0)
        self.assertTrue(result['changed'])
        self.assertFalse(path.exists())

    def test_empty_directory_and_foreign_link_are_replaced(self):
        empty = self.directory / 'empty'
        empty.mkdir()
        foreign = self.directory / 'foreign'
        foreign.symlink_to(self.directory / 'elsewhere')
        current = self.directory / 'current'
        target = self.directory / 'target'
        current.symlink_to(target)
        code, result = self.run_module([
            {'path': str(empty), 'state': 'link', 'src': str(target), 'type': 'directory'},
            {'path': str(foreign), 'state': 'link', 'src': str(target), 'type': 'directory'},
            {'path': str(current), 'state': 'link', 'src': str(target), 'type': 'directory'},
        ])
        self.assertEqual(code, 0, result)
        self.assertTrue(result['changed'])
        self.assertTrue(empty.is_symlink())
        self.assertEqual(os.readlink(empty), str(target))
        self.assertEqual(os.readlink(foreign), str(target))
        self.assertEqual(os.readlink(current), str(target))
        second, again = self.run_module([
            {'path': str(current), 'state': 'link', 'src': str(target), 'type': 'directory'},
        ])
        self.assertEqual(second, 0, again)
        self.assertFalse(again['changed'])

    def test_nonempty_directory_is_a_conflict(self):
        path = self.directory / 'occupied'
        path.mkdir()
        (path / 'file').write_text('keep', encoding='utf-8')
        code, _result = self.run_module([
            {'path': str(path), 'state': 'link', 'src': str(self.directory / 'target'), 'type': 'directory'},
        ])
        self.assertNotEqual(code, 0)
        self.assertTrue((path / 'file').is_file())
        self.assertFalse(path.is_symlink())

    def test_matching_file_becomes_a_link_and_a_modified_file_does_not(self):
        same = self.directory / 'same'
        same.write_text('managed\n', encoding='utf-8')
        modified = self.directory / 'modified'
        modified.write_text('user\n', encoding='utf-8')
        code, result = self.run_module([
            {
                'path': str(same), 'state': 'link', 'src': str(self.directory / 'managed'),
                'type': 'file', 'content': 'managed',
            },
            {
                'path': str(modified), 'state': 'link', 'src': str(self.directory / 'managed'),
                'type': 'file', 'content': 'managed',
            },
        ])
        self.assertNotEqual(code, 0, result)
        self.assertEqual(same.read_text(encoding='utf-8'), 'managed\n')
        self.assertFalse(same.is_symlink())
        self.assertEqual(modified.read_text(encoding='utf-8'), 'user\n')
        code, result = self.run_module([
            {
                'path': str(same), 'state': 'link', 'src': str(self.directory / 'managed'),
                'type': 'file', 'content': 'managed',
            },
        ])
        self.assertEqual(code, 0, result)
        self.assertTrue(same.is_symlink())
        self.assertEqual(os.readlink(same), str(self.directory / 'managed'))

    def test_identical_file_content_is_not_rewritten(self):
        path = self.directory / 'file'
        path.write_text('managed\n', encoding='utf-8')
        code, result = self.run_module([
            {'path': str(path), 'state': 'file', 'content': 'managed'},
        ])
        self.assertEqual(code, 0, result)
        self.assertFalse(result['changed'])
        self.assertEqual(path.read_text(encoding='utf-8'), 'managed\n')

    def test_distro_default_is_replaced_only_when_it_matches(self):
        default = self.directory / 'skel'
        default.write_text('stock\n', encoding='utf-8')
        stock = self.directory / 'stock'
        stock.write_text('stock\n', encoding='utf-8')
        edited = self.directory / 'edited'
        edited.write_text('user\n', encoding='utf-8')
        target = self.directory / 'managed-target'
        code, result = self.run_module([
            {
                'path': str(stock), 'state': 'link', 'src': str(target),
                'type': 'file', 'content': 'managed', 'defaults': [str(default)],
            },
            {
                'path': str(edited), 'state': 'link', 'src': str(target),
                'type': 'file', 'content': 'managed', 'defaults': [str(default)],
            },
        ])
        self.assertNotEqual(code, 0, result)
        self.assertEqual(stock.read_text(encoding='utf-8'), 'stock\n')
        self.assertFalse(stock.is_symlink())
        self.assertEqual(edited.read_text(encoding='utf-8'), 'user\n')
        code, result = self.run_module([
            {
                'path': str(stock), 'state': 'link', 'src': str(target),
                'type': 'file', 'content': 'managed', 'defaults': [str(default)],
            },
        ])
        self.assertEqual(code, 0, result)
        self.assertTrue(stock.is_symlink())
        self.assertEqual(os.readlink(stock), str(target))

    def test_nushell_scaffold_must_match_as_a_group(self):
        home = self.directory / 'home'
        scaffold = self.directory / 'scaffold'
        (home / '.config/nushell').mkdir(parents=True)
        scaffold.mkdir()
        env = home / '.config/nushell/env.nu'
        config = home / '.config/nushell/config.nu'
        env.write_text('default-env\n', encoding='utf-8')
        config.write_text('edited-config\n', encoding='utf-8')
        (scaffold / 'env.nu').write_text('default-env\n', encoding='utf-8')
        (scaffold / 'config.nu').write_text('default-config\n', encoding='utf-8')
        items = filters.shell_unix_items(
            [
                {'path': 'Documents/env', 'unix': '.config/nushell/env.nu', 'content': 'managed-env'},
                {'path': 'Documents/config', 'unix': '.config/nushell/config.nu', 'content': 'managed-config'},
            ],
            str(home), '/mnt/c/Users/shell', '/repo', [], '',
            nushell_defaults=str(scaffold),
        )
        nushell = [item for item in items if item['path'].endswith('.nu')]
        self.assertEqual(
            [item['defaults'] for item in nushell],
            [[str(scaffold / 'env.nu')], [str(scaffold / 'config.nu')]],
        )
        code, _result = self.run_module(nushell)
        self.assertNotEqual(code, 0)
        self.assertEqual(env.read_text(encoding='utf-8'), 'default-env\n')
        self.assertEqual(config.read_text(encoding='utf-8'), 'edited-config\n')
        self.assertFalse(env.is_symlink())
        config.write_text('default-config\n', encoding='utf-8')
        code, result = self.run_module(nushell)
        self.assertEqual(code, 0, result)
        self.assertTrue(env.is_symlink() and config.is_symlink())

    def test_scaffold_is_not_assumed_without_a_capture(self):
        items = filters.shell_unix_items(
            [
                {'path': '.bashrc', 'content': 'managed'},
                {'path': 'Documents/env', 'unix': '.config/nushell/env.nu', 'content': 'managed'},
                {'path': 'fish', 'unix': '.config/fish/config.fish', 'content': 'managed'},
            ],
            '/home/shell', '/mnt/c/Users/shell', '/repo', [], '',
        )
        by_path = {item['path']: item for item in items}
        self.assertEqual(by_path['/home/shell/.bashrc']['defaults'], [
            '/etc/skel/.bashrc', '/usr/share/base-files/dot.bashrc',
        ])
        self.assertNotIn('defaults', by_path['/home/shell/.config/nushell/env.nu'])
        self.assertNotIn('defaults', by_path['/home/shell/.config/fish/config.fish'])

    def test_external_empty_directory_is_replaced_and_a_file_is_not(self):
        empty = self.directory / 'empty-link'
        empty.mkdir()
        occupied = self.directory / 'occupied-link'
        occupied.write_text('keep\n', encoding='utf-8')
        code, _result = self.run_module([
            {'path': str(empty), 'state': 'link', 'src': str(self.directory / 'outside'), 'type': 'external'},
            {'path': str(occupied), 'state': 'link', 'src': str(self.directory / 'outside'), 'type': 'external'},
        ])
        self.assertNotEqual(code, 0)
        self.assertTrue(empty.is_dir())
        self.assertFalse(empty.is_symlink())
        self.assertEqual(occupied.read_text(encoding='utf-8'), 'keep\n')
        code, result = self.run_module([
            {'path': str(empty), 'state': 'link', 'src': str(self.directory / 'outside'), 'type': 'external'},
        ])
        self.assertEqual(code, 0, result)
        self.assertTrue(empty.is_symlink())


if __name__ == '__main__':
    unittest.main()
