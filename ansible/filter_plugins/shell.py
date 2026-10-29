import json
import os
import re


def _join(*parts):
    return '/'.join(part.rstrip('/') for part in parts if part)


def shell_windows_items(entries, home, repository, fish, plugins, clink):
    items = [
        {'path': _join(home, entry['path']), 'state': 'file', 'content': entry['content']}
        for entry in entries
    ]
    items += [
        {'path': _join(home, '.config/fish', name), 'state': 'directory'}
        for name in fish
    ]
    items += [
        {'path': _join(home, '.config/shell'), 'state': 'link', 'src': repository},
        {
            'path': _join(home, '.config/oh-my-posh'),
            'state': 'link',
            'src': _join(repository, 'oh-my-posh'),
        },
        {
            'path': _join(home, '.zsh_plugins.txt'),
            'state': 'link',
            'src': _join(repository, 'zsh_plugins.txt'),
            'type': 'file',
            'content': plugins,
        },
        {
            'path': _join(home, 'AppData/Local/clink/clink_settings'),
            'state': 'link',
            'src': _join(repository, 'common.clink_settings'),
            'type': 'file',
            'content': clink,
        },
    ]
    return items


def shell_unix_items(entries, home, source_home, repository, fish, plugins, msys=False, skel=None):
    items = [
        {'path': _join(home, '.config/shell'), 'state': 'link', 'src': repository},
        {
            'path': _join(home, '.config/oh-my-posh'),
            'state': 'link',
            'src': _join(repository, 'oh-my-posh'),
        },
        {
            'path': _join(home, '.zsh_plugins.txt'),
            'state': 'link',
            'src': _join(repository, 'zsh_plugins.txt'),
            'type': 'file',
            'content': plugins,
        },
    ]
    items += [
        {
            'path': _join(home, '.config/fish', name),
            'state': 'link',
            'src': _join(source_home, '.config/fish', name),
        }
        for name in fish
    ]

    for entry in entries:
        unix = entry.get('unix', entry['path'])
        if unix is False or (msys and entry.get('msys') is False):
            continue
        item = {
            'path': _join(home, unix),
            'state': 'link',
            'src': _join(source_home, entry['path']),
            'type': 'file',
            'content': entry['content'],
        }
        if '/' not in unix:
            if msys:
                item['defaults'] = [_join(skel, unix)] if skel else []
            else:
                item['defaults'] = [
                    _join('/etc/skel', unix),
                    _join('/usr/share/base-files', 'dot' + unix),
                ]
        items.append(item)

    return items


def shell_units(directory, only=None, exclude=()):
    units = []
    for name in sorted(os.listdir(directory)):
        if not re.fullmatch(r'[^.].*\.(service|socket|timer|path|target)', name):
            continue
        if (only and name not in only) or name in exclude:
            continue
        with open(os.path.join(directory, name), encoding='utf-8') as handle:
            content = handle.read().replace('\r', '').rstrip('\n')
        enable = bool(re.search(r'(?m)^\[Install\]\s*$', content)) and not os.path.splitext(name)[0].endswith('@')
        units.append({
            'name': name,
            'content': content,
            'enable': enable,
            'wanted_by': [
                target
                for line in re.findall(r'(?m)^WantedBy=(.*)$', content)
                for target in line.split()
            ] if enable else [],
        })
    return units


def shell_unit_items(units, home, repository):
    items = [
        {
            'path': _join(home, '.config/systemd/user', unit['name']),
            'state': 'link',
            'src': _join(repository, 'systemd', unit['name']),
            'type': 'file',
            'content': unit['content'],
        }
        for unit in units
    ]
    # The same links systemctl --user enable creates, so units are enabled without a running user manager.
    items += [
        {
            'path': _join(home, '.config/systemd/user', target + '.wants', unit['name']),
            'state': 'link',
            'src': _join(repository, 'systemd', unit['name']),
        }
        for unit in units
        for target in unit['wanted_by']
    ]
    return items


def shell_link_items(links):
    return [
        {'path': path, 'state': 'link', 'src': target, 'type': 'external'}
        for path, target in sorted(links.items())
    ]


class _Undefined(Exception):
    pass


def _strip_jsonc(text):
    # Windows Terminal accepts comments and trailing commas in settings.json.
    output = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == '"':
            end = index + 1
            while end < len(text) and text[end] != '"':
                end += 2 if text[end] == '\\' else 1
            output.append(text[index:end + 1])
            index = end + 1
        elif text.startswith('//', index):
            end = text.find('\n', index)
            index = len(text) if end < 0 else end
        elif text.startswith('/*', index):
            end = text.find('*/', index + 2)
            index = len(text) if end < 0 else end + 2
        else:
            output.append(char)
            index += 1
    return re.sub(
        r'"(?:\\.|[^"\\])*"|,(\s*[}\]])',
        lambda match: match.group(1) if match.group(1) is not None else match.group(0),
        ''.join(output),
    )


def _expand(value, variables):
    if isinstance(value, dict):
        return {key: _expand(item, variables) for key, item in value.items()}
    if isinstance(value, list):
        items = []
        for item in value:
            try:
                items.append(_expand(item, variables))
            except _Undefined:
                pass
        return items
    if isinstance(value, str):
        def replace(match):
            if not variables.get(match.group(1)):
                raise _Undefined(match.group(1))
            return variables[match.group(1)]
        return re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', replace, value)
    return value


_TERMINAL_KEYS = {
    ('actions',): 'id',
    ('keybindings',): 'id',
    ('schemes',): 'name',
    ('themes',): 'name',
    ('profiles', 'list'): 'guid',
}


def _merge(existing, managed, path=()):
    if isinstance(existing, dict) and isinstance(managed, dict):
        merged = dict(existing)
        for key, value in managed.items():
            merged[key] = _merge(existing[key], value, path + (key,)) if key in existing else value
        return merged
    key = _TERMINAL_KEYS.get(path)
    if key and isinstance(existing, list) and isinstance(managed, list):
        merged = list(existing)
        positions = {
            item[key]: index for index, item in enumerate(merged) if isinstance(item, dict) and key in item
        }
        for item in managed:
            if item.get(key) in positions:
                merged[positions[item[key]]] = _merge(merged[positions[item[key]]], item, path + ('*',))
            else:
                merged.append(item)
        return merged
    return managed


def shell_terminal_settings(existing, managed, variables):
    """Merge the managed Windows Terminal settings into settings.json text.

    Entries of managed lists that reference an undefined ${NAME} are dropped; list entries are matched by
    their identity key, and everything not in the managed settings is kept.
    """
    existing = existing.lstrip('\ufeff')
    current = json.loads(_strip_jsonc(existing)) if existing.strip() else {}
    merged = _merge(current, _expand(managed, variables))
    return {
        'changed': merged != current,
        'content': json.dumps(merged, indent=4, ensure_ascii=False) + '\n',
    }


class FilterModule:
    def filters(self):
        return {
            'shell_terminal_settings': shell_terminal_settings,
            'shell_windows_items': shell_windows_items,
            'shell_unix_items': shell_unix_items,
            'shell_link_items': shell_link_items,
            'shell_units': shell_units,
            'shell_unit_items': shell_unit_items,
        }
