#!/usr/bin/python

import os

from ansible.module_utils.basic import AnsibleModule


def inspect(path):
    if os.path.islink(path):
        return {'type': 'link', 'target': os.readlink(path)}
    if os.path.isdir(path):
        return {'type': 'directory'}
    if os.path.lexists(path):
        return {'type': 'file'}
    return {'type': 'missing'}


def read(path):
    with open(path, encoding='utf-8', errors='surrogateescape') as handle:
        return handle.read().replace('\r', '').rstrip('\n')


def evaluate(item):
    path = item['path']
    state = item['state']
    kind = item['type']

    if state == 'link' and path == item['src']:
        return None, None

    current = inspect(path)

    if current['type'] == 'missing':
        return 'create', None

    if kind == 'external':
        if current['type'] == 'link' and current['target'] == item['src']:
            return None, None
        if current['type'] == 'directory' and not os.listdir(path):
            return 'replace', None
        return None, 'An existing path occupies a configured link'

    if state == 'directory':
        if current['type'] == 'directory' or (
            current['type'] == 'link' and os.path.isdir(path)
        ):
            return None, None
        return None, 'A file occupies a directory destination'

    if state == 'file' or kind == 'file':
        if current['type'] == 'directory':
            return None, 'A directory occupies a file destination'
        if current['type'] == 'link' and current['target'] == item['src']:
            return None, None
        try:
            existing = read(path)
        except OSError:
            existing = None
        if existing != item['content']:
            if existing is not None and current['type'] == 'file' and any(
                os.path.isfile(default) and read(default) == existing
                for default in item['defaults']
            ):
                return 'replace', None
            return None, 'Existing file contains other configuration'
        return ('replace' if state == 'link' else None), None

    if current['type'] == 'link':
        return ('replace' if current['target'] != item['src'] else None), None

    if current['type'] != 'directory':
        return None, 'A file occupies a directory destination'

    if os.listdir(path):
        return None, 'Existing directory is not empty'

    return 'replace', None


def apply(item, action):
    path = item['path']
    os.makedirs(os.path.dirname(path), exist_ok=True)

    if action == 'replace':
        if os.path.isdir(path) and not os.path.islink(path):
            os.rmdir(path)
        else:
            os.unlink(path)

    if item['state'] == 'directory':
        os.makedirs(path, exist_ok=True)
    elif item['state'] == 'file':
        with open(path, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(item['content'] + '\n')
    else:
        os.symlink(item['src'], path)


def main():
    module = AnsibleModule(
        argument_spec={
            'items': {
                'type': 'list',
                'elements': 'dict',
                'required': True,
                'options': {
                    'path': {'type': 'str', 'required': True},
                    'state': {
                        'type': 'str',
                        'required': True,
                        'choices': ['file', 'directory', 'link'],
                    },
                    'src': {'type': 'str'},
                    'content': {'type': 'str'},
                    'defaults': {'type': 'list', 'elements': 'str', 'default': []},
                    'type': {
                        'type': 'str',
                        'default': 'directory',
                        'choices': ['file', 'directory', 'external'],
                    },
                },
            },
        },
        supports_check_mode=True,
    )

    planned = []
    conflicts = []

    for item in module.params['items']:
        if item['state'] == 'link' and not item['src']:
            module.fail_json(msg='Link items require src: ' + item['path'])
        if item['content'] is None:
            item['content'] = ''
        action, conflict = evaluate(item)
        if conflict:
            conflicts.append(conflict + ': ' + item['path'])
        elif action:
            planned.append((item, action))

    if conflicts:
        module.fail_json(msg='; '.join(conflicts), conflicts=conflicts)

    changes = [
        {
            'path': item['path'],
            'action': action,
            'state': item['state'],
            'src': item['src'],
        }
        for item, action in planned
    ]
    diff = [
        {
            'before_header': item['path'],
            'after_header': item['path'],
            'before': '' if action == 'create' else 'existing\n',
            'after': (
                '-> ' + item['src'] if item['state'] == 'link' else item['state']
            ) + '\n',
        }
        for item, action in planned
    ]

    if not module.check_mode:
        for item, action in planned:
            apply(item, action)

    module.exit_json(changed=bool(planned), changes=changes, diff=diff)


if __name__ == '__main__':
    main()
