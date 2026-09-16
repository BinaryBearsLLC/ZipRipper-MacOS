#!/usr/bin/env python3
"""Fetch byte-identical pinned upstream source archives; never install packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.parse
import urllib.request


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=root / 'dependencies/manifest.json')
    parser.add_argument('--cache', type=Path, default=root / 'dependencies/cache')
    parser.add_argument('--source', choices=['original', 'github'], default='original')
    parser.add_argument('--mirror-base-url')
    parser.add_argument('--verify-only', action='store_true', help='Offline: require every cached archive and verify its checksum')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest['schemaVersion'] != 1:
        raise ValueError('Unsupported dependency manifest version')
    mirror = args.mirror_base_url or manifest.get('githubMirrorBaseURL')
    if args.source == 'github' and not mirror:
        raise ValueError('GitHub mirror is not configured. Use original sources or provide --mirror-base-url.')
    if args.source == 'github':
        parsed = urllib.parse.urlparse(mirror)
        if parsed.scheme != 'https' or parsed.hostname not in {'github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com'}:
            raise ValueError('Mirror must be an HTTPS GitHub release or raw-content base URL')
    args.cache.mkdir(parents=True, exist_ok=True)
    for item in manifest['dependencies']:
        name, expected = item['filename'], item['sha256']
        if Path(name).name != name or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
            raise ValueError('Invalid filename or SHA-256 in manifest')
        target = args.cache / name
        if target.exists():
            if digest(target) != expected:
                raise ValueError(f'Checksum mismatch: {target}. Existing file preserved; remove or quarantine it before retrying.')
            print(f'Verified {name}', flush=True)
            continue
        if args.verify_only:
            raise FileNotFoundError(f'Missing cached source archive: {target}')
        url = item['originalURL'] if args.source == 'original' else mirror.rstrip('/') + '/' + urllib.parse.quote(name)
        if urllib.parse.urlparse(url).scheme != 'https':
            raise ValueError('Dependency downloads require HTTPS')
        print(f'Downloading {name} from {url}', flush=True)
        fd, temporary = tempfile.mkstemp(prefix=name + '.', suffix='.partial', dir=args.cache)
        try:
            with os.fdopen(fd, 'wb') as output:
                request = urllib.request.Request(url, headers={'User-Agent': 'ZipRipper-source-fetcher/1'})
                with urllib.request.urlopen(request, timeout=90) as response:
                    if urllib.parse.urlparse(response.url).scheme != 'https':
                        raise ValueError('Refusing a non-HTTPS redirect')
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        output.write(block)
            if digest(Path(temporary)) != expected:
                raise ValueError(f'SHA-256 mismatch for {name}; downloaded file rejected')
            os.replace(temporary, target)
            print(f'Verified {name}', flush=True)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
