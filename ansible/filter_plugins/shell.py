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


class FilterModule:
    def filters(self):
        return {
            'shell_windows_items': shell_windows_items,
            'shell_unix_items': shell_unix_items,
            'shell_link_items': shell_link_items,
            'shell_units': shell_units,
            'shell_unit_items': shell_unit_items,
        }
