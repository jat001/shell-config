#!/usr/bin/python3
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import pwd
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def request(url, method='GET'):
    for attempt in range(3):
        try:
            return urllib.request.urlopen(
                urllib.request.Request(url, method=method, headers={'User-Agent': 'shell-config-updater'}),
                timeout=60,
            )
        except urllib.error.HTTPError as error:
            if error.code not in (408, 429, 500, 502, 503, 504) or attempt == 2:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
        time.sleep(5 * (attempt + 1))


def version_key(value):
    match = re.fullmatch(r'v?(\d+(?:\.\d+){1,3})(?:\+(\d+))?', value)
    if not match:
        raise ValueError(f'Unexpected stable release tag: {value}')
    numbers = tuple(int(part) for part in match[1].split('.'))
    return numbers + (0,) * (4 - len(numbers)) + (int(match[2] or 0),)


def latest_asset(item):
    repository = item['repository']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid GitHub release repository')
    base = f'https://github.com/{repository}/releases'
    with request(f'{base}/latest', method='HEAD') as response:
        final = urllib.parse.urlsplit(response.url)
    prefix = f'/{repository}/releases/tag/'
    if final.hostname != 'github.com' or not final.path.startswith(prefix):
        raise ValueError('Unexpected latest-release redirect')
    tag = urllib.parse.unquote(final.path[len(prefix):])
    version_key(tag)
    version = tag.removeprefix('v').split('+', 1)[0]
    filename = item['asset'].replace('{version}', version)
    url = f'{base}/download/{urllib.parse.quote(tag, safe="")}/{urllib.parse.quote(filename)}'
    if filename in ('', '.', '..') or '/' in filename or '\\' in filename:
        raise ValueError('Invalid release asset filename')
    return tag, version, filename, url


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_text(path, text):
    descriptor, temporary = tempfile.mkstemp(prefix='.state-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as output:
            output.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def published_digest(item, tag, filename):
    checksum_asset = item.get('checksum_asset')
    if not checksum_asset:
        return None
    if '/' in checksum_asset or '\\' in checksum_asset:
        raise ValueError('Invalid checksum asset filename')
    url = f'https://github.com/{item["repository"]}/releases/download/'
    url += urllib.parse.quote(tag, safe='') + '/' + urllib.parse.quote(checksum_asset)
    with request(url) as response:
        text = response.read(1024 * 1024).decode('utf-8')
    for line in text.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2 and parts[1].lstrip('*') == filename and re.fullmatch(r'[A-Fa-f0-9]{64}', parts[0]):
            return parts[0].lower()
    raise ValueError(f'No published SHA256 was found for {filename}')


def cached_download(directory, filename, url, expected=None):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / filename
    checksum = directory / (filename + '.sha256')
    if path.exists() and checksum.exists():
        digest = file_hash(path)
        if digest != checksum.read_text().strip() or (expected is not None and digest != expected):
            raise ValueError(f'Cached download checksum failed: {path}')
        return path
    descriptor, temporary = tempfile.mkstemp(prefix='.download-', dir=directory)
    try:
        with os.fdopen(descriptor, 'wb') as output, request(url) as response:
            shutil.copyfileobj(response, output)
            content_length = response.headers.get('Content-Length')
            if content_length is not None and output.tell() != int(content_length):
                raise ValueError('The release download was incomplete')
        digest = file_hash(Path(temporary))
        if expected is not None and digest != expected:
            raise ValueError('The release download does not match its published SHA256')
        os.replace(temporary, path)
        write_text(checksum, digest + '\n')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return path


def managed_target(link, root):
    if link.is_symlink():
        resolved = link.resolve()
        if resolved.is_relative_to(root.resolve()):
            return resolved
    return None


def requested_user_units(item):
    units = item.get('restart_user_units', [])
    for unit in units:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:@-]*\.(?:service|socket|timer|path|target)', unit):
            raise ValueError('Invalid managed user unit name')
    return units


def restart_user_units(item, manifest):
    units = requested_user_units(item)
    if not units:
        return
    for name in manifest.get('users', []):
        try:
            account = pwd.getpwnam(name)
        except KeyError:
            continue
        runtime = Path('/run/user') / str(account.pw_uid)
        if not (runtime / 'bus').is_socket():
            continue
        for unit in units:
            if not (Path(account.pw_dir) / '.config/systemd/user' / unit).is_file():
                continue
            subprocess.run(
                ['systemctl', '--user', 'try-restart', '--', unit],
                check=True, user=account.pw_uid, group=account.pw_gid,
                extra_groups=os.getgrouplist(name, account.pw_gid),
                env={**os.environ, 'XDG_RUNTIME_DIR': str(runtime),
                     'DBUS_SESSION_BUS_ADDRESS': f'unix:path={runtime}/bus'},
                stdout=sys.stderr,
            )


def extract_archive(path, directory):
    with tarfile.open(path) as archive:
        if hasattr(tarfile, 'data_filter'):
            archive.extractall(directory, filter='data')
        else:
            for member in archive.getmembers():
                name = PurePosixPath(member.name)
                if name.is_absolute() or '..' in name.parts or not (member.isdir() or member.isfile()):
                    raise ValueError('Unsafe archive member')
            archive.extractall(directory)


def validate_binary(path):
    with path.open('rb') as stream:
        header = stream.read(64)
    machine = {'x86_64': 62, 'aarch64': 183}.get(platform.machine())
    if len(header) != 64 or header[:4] != b'\x7fELF' or header[4:6] != b'\x02\x01' or machine is None:
        raise ValueError('The downloaded binary is not a supported ELF executable')
    if int.from_bytes(header[18:20], 'little') != machine:
        raise ValueError('The downloaded binary has an unexpected architecture')
    offset = int.from_bytes(header[32:40], 'little')
    entry_size = int.from_bytes(header[54:56], 'little')
    entries = int.from_bytes(header[56:58], 'little')
    if entries == 0 or entry_size < 56 or path.stat().st_size < offset + entry_size * entries:
        raise ValueError('The downloaded ELF program headers are incomplete')


def install_binary(item, archive, destination, version):
    destination.parent.mkdir(parents=True, exist_ok=True)
    relative = Path(item.get('archive', '').replace('{version}', version)) / item['command']
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Invalid release binary path')
    if destination.exists():
        if not (destination / relative).is_file():
            raise ValueError(f'An incomplete release directory exists: {destination}')
        validate_binary(destination / relative)
        return destination / relative
    with tempfile.TemporaryDirectory(prefix='.install-', dir=destination.parent) as temporary:
        temporary = Path(temporary)
        if 'archive' in item:
            extract_archive(archive, temporary)
        else:
            shutil.copyfile(archive, temporary / item['command'])
        binary = temporary / relative
        validate_binary(binary)
        binary.chmod(0o755)
        os.replace(temporary, destination)
    return destination / relative


def publish_link(link, target):
    temporary_link = link.with_name('.' + link.name + '.new-' + uuid.uuid4().hex)
    try:
        temporary_link.symlink_to(target)
        os.replace(temporary_link, link)
    finally:
        if temporary_link.is_symlink():
            temporary_link.unlink()


def update_item(item, manifest, update, check, installed_only=False):
    name = item['name']
    if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*', name) or not re.fullmatch(
        r'[A-Za-z0-9_+-][A-Za-z0-9_.+-]*', item['command']
    ):
        raise ValueError('Invalid managed release name')
    requested_user_units(item)
    root = Path(manifest['root']) / name
    link = Path(manifest['bin']) / item['command']
    target = managed_target(link, root)
    kind = item.get('kind', 'archive' if 'archive' in item else 'binary')
    if kind not in ('archive', 'binary'):
        raise ValueError('Unknown release installation format')
    cache = Path(manifest['cache']) / name
    managed = target is not None
    if not managed and shutil.which(item['command']) is not None:
        return 'external'
    if installed_only and not managed and target is None:
        return 'unchanged'
    if managed and target is not None and not target.is_file():
        managed = False
    if managed and not update:
        return 'unchanged'
    tag, version, filename, url = latest_asset(item)
    if target is not None and target.is_file():
        current_tag = target.relative_to(root.resolve()).parts[0]
        if version_key(tag) <= version_key(current_tag):
            return 'unchanged'
    if check:
        return 'changed'
    expected = published_digest(item, tag, filename)
    asset = cached_download(cache / tag, filename, url, expected)
    binary = install_binary(item, asset, root / tag, version)
    link.parent.mkdir(parents=True, exist_ok=True)
    publish_link(link, binary)
    try:
        restart_user_units(item, manifest)
    except Exception:
        if target is not None:
            publish_link(link, target)
        else:
            link.unlink()
        raise
    return 'changed'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--update', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--installed-only', action='store_true')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if any(not Path(manifest[key]).is_absolute() for key in ('root', 'bin', 'cache')):
        raise ValueError('Release directories must be absolute paths')
    result = {'changed': [], 'external': [], 'unchanged': [], 'errors': []}
    with contextlib.ExitStack() as context:
        if not args.check:
            cache = Path(manifest['cache'])
            cache.mkdir(parents=True, exist_ok=True)
            lock = context.enter_context((cache / '.update.lock').open('a'))
            deadline = time.monotonic() + 30
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Another release update is still in progress')
                    time.sleep(0.5)
        for item in manifest['packages']:
            try:
                status = update_item(item, manifest, args.update, args.check, args.installed_only)
                result[status].append(item['name'])
            except Exception as error:
                result['errors'].append({'name': item['name'], 'error': str(error)})
    print(json.dumps(result))
    return 1 if result['errors'] else 0


if __name__ == '__main__':
    sys.exit(main())
