import importlib.util
import json
from pathlib import Path
import unittest


path = Path(__file__).resolve().parents[1] / 'ansible/filter_plugins/shell.py'
spec = importlib.util.spec_from_file_location('shell_filters', path)
filters = importlib.util.module_from_spec(spec)
spec.loader.exec_module(filters)


class TerminalSettingsTests(unittest.TestCase):
    def test_jsonc_preserves_string_contents(self):
        value = 'literal,} and ,] with "quotes", \\ and https://example.test/*literal*/'
        source = '\ufeff{\n// comment\n"custom": ' + json.dumps(value) + ',\n"items": [1, /* comment */],\n}'
        result = filters.shell_terminal_settings(source, {'theme': 'Mocha'}, {})
        merged = json.loads(result['content'])
        self.assertEqual(merged, {'custom': value, 'items': [1], 'theme': 'Mocha'})
        self.assertTrue(result['changed'])
        self.assertFalse(filters.shell_terminal_settings(result['content'], {'theme': 'Mocha'}, {})['changed'])

    def test_merge_keeps_unmanaged_profiles_and_fields(self):
        existing = {
            'custom': {'keep': True},
            'profiles': {
                'defaults': {'font': {'size': 14}},
                'list': [
                    {'guid': 'generated', 'source': 'Microsoft.WSL'},
                    {'guid': 'managed', 'commandline': 'old', 'tabTitle': 'keep'},
                ],
            },
            'actions': [{'id': 'custom', 'command': 'copy'}, {'id': 'managed', 'command': 'old'}],
        }
        managed = {
            'profiles': {
                'defaults': {'font': {'face': 'Maple Mono NF CN'}},
                'list': [{'guid': 'managed', 'commandline': '${SCOOP}/nu.exe'}],
            },
            'actions': [{'id': 'managed', 'command': 'new'}],
        }
        result = filters.shell_terminal_settings(json.dumps(existing), managed, {'SCOOP': 'C:/scoop'})
        merged = json.loads(result['content'])
        self.assertEqual(merged['custom'], existing['custom'])
        self.assertEqual(merged['profiles']['list'][0], existing['profiles']['list'][0])
        self.assertEqual(merged['profiles']['list'][1], {
            'guid': 'managed', 'commandline': 'C:/scoop/nu.exe', 'tabTitle': 'keep',
        })
        self.assertEqual(merged['profiles']['defaults']['font'], {'size': 14, 'face': 'Maple Mono NF CN'})
        self.assertEqual(merged['actions'], [
            {'id': 'custom', 'command': 'copy'}, {'id': 'managed', 'command': 'new'},
        ])
        self.assertFalse(filters.shell_terminal_settings(result['content'], managed, {'SCOOP': 'C:/scoop'})['changed'])

    def test_unavailable_msys2_does_not_replace_existing_profile(self):
        existing = {'profiles': {'list': [{'guid': 'msys2', 'commandline': 'custom'}]}}
        managed = {'profiles': {'list': [
            {'guid': 'msys2', 'commandline': '${MSYS2_ROOT}/msys2_shell.cmd'},
            {'guid': 'nu', 'commandline': '${SCOOP}/nu.exe'},
        ]}}
        result = filters.shell_terminal_settings(json.dumps(existing), managed, {'SCOOP': 'C:/scoop'})
        profiles = json.loads(result['content'])['profiles']['list']
        self.assertEqual(profiles, [
            {'guid': 'msys2', 'commandline': 'custom'},
            {'guid': 'nu', 'commandline': 'C:/scoop/nu.exe'},
        ])

    def test_invalid_json_fails_instead_of_replacing_settings(self):
        with self.assertRaises(json.JSONDecodeError):
            filters.shell_terminal_settings('{"custom":', {'theme': 'Mocha'}, {})


if __name__ == '__main__':
    unittest.main()
