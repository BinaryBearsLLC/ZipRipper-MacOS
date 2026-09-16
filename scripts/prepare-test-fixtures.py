#!/usr/bin/env python3
"""Prepare real password-recovery fixtures without installing system software.

Upstream archives and the official macOS 7-Zip test tool have pinned SHA-256.
Generated archives have random encryption salts; existing files are never replaced.
Their member contents, encryption and compression are checked before reuse.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

TOOL = {
    'filename': '7z2603-mac.tar.xz',
    'url': 'https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz',
    'sha256': '5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480',
}
SAMPLES = [
  {
    "file": "hp0.rar",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/RAR/hp0.rar",
    "sha256": "ab2b58c43ecd7a2005a2fd78ac8cdeb84e488542f5f5f6807f9da59952e6ea1b"
  },
  {
    "file": "p0.rar",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/RAR/p0.rar",
    "sha256": "f34759ca3f03bd592d98e6ac72567a7fcc203aa1a5f72b8c5a95a8f446a93599"
  },
  {
    "file": "pm0.rar",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/RAR/pm0.rar",
    "sha256": "b794ed85220ff5b0c5469c6ffca468357ec4bfce1f406eb7115f222c70948abc"
  },
  {
    "file": "rar5-hp0-password.rar",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/RAR5/rar5-hp0-password.rar",
    "sha256": "1f60bfc2c2e0f5cba64d27a3bdc90ea55ee01dfc5cb0fe7004ba1a231e4e8a98"
  },
  {
    "file": "rar5-p0-password.rar",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/RAR5/rar5-p0-password.rar",
    "sha256": "5a71e17e3a456752c4b9f34ee808eff648e2ff233e027868e669c4e479c7701d"
  },
  {
    "file": "test-3-RC4-40-open-testpassword.pdf",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/PDF/new-pdf-collection/test-3-RC4-40-open-testpassword.pdf",
    "sha256": "e9e80b5eb2d767004b8a235efe8941da8361234b847b27570945ed871b134d78"
  },
  {
    "file": "test-5-RC4-128-open-testpassword.pdf",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/PDF/new-pdf-collection/test-5-RC4-128-open-testpassword.pdf",
    "sha256": "dc8f8d6c4e7fe9f995da9c4e3c868e62ed452a52af55b91a0069949a1ac1c1d4"
  },
  {
    "file": "test-7-AES-128-open-testpassword.pdf",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/PDF/new-pdf-collection/test-7-AES-128-open-testpassword.pdf",
    "sha256": "e80841477f695f8a9b5a2c61b5318812f51a811d9ab834df6462e87a2c8946f1"
  },
  {
    "file": "test-X-AES-256-open-testpassword.pdf",
    "url": "https://raw.githubusercontent.com/openwall/john-samples/a2f3a3ed7819ce94f8280b0bbfc23ba576817cce/PDF/new-pdf-collection/test-X-AES-256-open-testpassword.pdf",
    "sha256": "3e11aa07ee8238b8ff42a5dd2ee3a0a01fe79fe176102e0472d085f45e8365fa"
  }
]
CASES = [
  {
    "file": "zip-traditional.zip",
    "format": "PKZIP",
    "marker": "$pkzip$",
    "password": "ZipRipper42!"
  },
  {
    "file": "zip-aes256.zip",
    "format": "ZIP",
    "marker": "$zip2$",
    "password": "ZipRipper42!"
  },
  {
    "file": "seven-header.7z",
    "format": "7z",
    "marker": "$7z$",
    "password": "ZipRipper42!"
  },
  {
    "file": "seven-data.7z",
    "format": "7z",
    "marker": "$7z$",
    "password": "ZipRipper42!"
  },
  {
    "file": "rar5-hp0-password.rar",
    "format": "RAR5",
    "marker": "$rar5$",
    "password": "password"
  },
  {
    "file": "rar5-p0-password.rar",
    "format": "RAR5",
    "marker": "$rar5$",
    "password": "password"
  },
  {
    "file": "test-3-RC4-40-open-testpassword.pdf",
    "format": "PDF",
    "marker": "$pdf$",
    "password": "testpassword"
  },
  {
    "file": "test-5-RC4-128-open-testpassword.pdf",
    "format": "PDF",
    "marker": "$pdf$",
    "password": "testpassword"
  },
  {
    "file": "test-7-AES-128-open-testpassword.pdf",
    "format": "PDF",
    "marker": "$pdf$",
    "password": "testpassword"
  },
  {
    "file": "test-X-AES-256-open-testpassword.pdf",
    "format": "PDF",
    "marker": "$pdf$",
    "password": "testpassword"
  },
  {
    "file": "hp0.rar",
    "format": "rar",
    "marker": "$RAR3$",
    "password": "password"
  }
]
WORDS = 'incorrect\nZipRipper42!\npassword\nopenwall\nhashcat\ntestpassword\ntest\n123456\nsecret\n'
MESSAGE = b'ZipRipper local validation fixture.\n' * 20
FIRST = b'First archive file payload\n' * 10
SECOND = b'Second archive file payload\n' * 10


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def preserve_write(path, data, mode=0o644):
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file() or path.read_bytes() != data:
            raise ValueError(f'Existing file differs; preserved without changes: {path}')
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as output:
        output.write(data)
    path.chmod(mode)


def fetch(path, url, expected):
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file() or sha256(path.read_bytes()) != expected:
            raise ValueError(f'Checksum mismatch; existing file preserved: {path}')
        print(f'Verified {path.name}', flush=True)
        return
    print(f'Downloading {url}', flush=True)
    request = urllib.request.Request(url, headers={'User-Agent': 'ZipRipper-fixture-builder/1'})
    with urllib.request.urlopen(request, timeout=90) as response:
        if not response.url.startswith('https://'):
            raise ValueError('Refusing a non-HTTPS redirect')
        data = response.read()
    if sha256(data) != expected:
        raise ValueError(f'Download checksum mismatch: {url}')
    preserve_write(path, data)


def command(tool, arguments, cwd):
    result = subprocess.run([str(tool), *map(str, arguments)], cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise ValueError(f'7-Zip failed ({result.returncode}): {result.stderr.decode(errors="replace")}')
    return result.stdout


def validate_archive(tool, archive, members):
    """members maps basename to (password, plaintext, expected ZIP method)."""
    if archive.is_symlink() or not archive.is_file():
        raise ValueError(f'Not a regular fixture archive: {archive}')
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as z:
            entries = z.infolist()
            if len(entries) != len(members):
                raise ValueError(f'Unexpected ZIP member count: {archive}')
            actual = {}
            for entry in entries:
                name = Path(entry.filename).name
                if name not in members or name in actual:
                    raise ValueError(f'Unexpected ZIP member: {archive}: {entry.filename}')
                password, contents, method = members[name]
                if not entry.flag_bits & 1 or entry.compress_type != method:
                    raise ValueError(f'Wrong encryption/compression: {archive}: {entry.filename}')
                actual[name] = entry.filename
    else:
        password = next(iter(members.values()))[0]
        listing = command(tool, ['l', '-slt', '-ba', f'-p{password}', archive], archive.parent).decode()
        names = [line[7:] for line in listing.splitlines() if line.startswith('Path = ')]
        if len(names) != len(members) or 'Encrypted = +' not in listing:
            raise ValueError(f'Unexpected 7z contents or encryption: {archive}')
        actual = {Path(name).name: name for name in names}
        if set(actual) != set(members):
            raise ValueError(f'Unexpected 7z members: {archive}')
    for name, (password, expected, _) in members.items():
        contents = command(tool, ['x', '-so', f'-p{password}', archive, actual[name]], archive.parent)
        if contents != expected:
            raise ValueError(f'Fixture payload mismatch: {archive}: {name}')


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=root/'.local/fixtures')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise ValueError('Fixture generation uses the official macOS 7-Zip binary and requires macOS')
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    # Fetch only a local test tool. No package manager or system installation.
    tool_archive = destination/'.downloads'/TOOL['filename']
    fetch(tool_archive, TOOL['url'], TOOL['sha256'])
    with tarfile.open(tool_archive, 'r:xz') as tar:
        member = next(m for m in tar.getmembers() if m.name.lstrip('./') == '7zz')
        if not member.isfile():
            raise ValueError('Official 7-Zip archive does not contain a regular 7zz executable')
        binary = tar.extractfile(member).read()
    tool = destination/'.tools/7zz'
    preserve_write(tool, binary, 0o755)
    for sample in SAMPLES:
        fetch(destination/sample['file'], sample['url'], sample['sha256'])
    preserve_write(destination/'message.txt', MESSAGE)
    preserve_write(destination/'words.txt', WORDS.encode())
    preserve_write(destination/'mixed-words.txt', b'AlphaSecret42\nBetaSecret73\n')
    preserve_write(destination/'cases.json', (json.dumps(CASES, indent=2)+'\n').encode())
    preserve_write(destination/'upstream-fixtures.json', (json.dumps(SAMPLES, indent=2)+'\n').encode())
    jobs = [
        ('zip-digits.zip', {'message.txt': ('17', MESSAGE, 8)}, [('message.txt', '17', ['-tzip', '-mem=ZipCrypto', '-mm=Deflate'])]),
        ('zip-traditional.zip', {'message.txt': ('ZipRipper42!', MESSAGE, 8)}, [('message.txt', 'ZipRipper42!', ['-tzip', '-mem=ZipCrypto', '-mm=Deflate'])]),
        ('zip-aes256.zip', {'message.txt': ('ZipRipper42!', MESSAGE, 99)}, [('message.txt', 'ZipRipper42!', ['-tzip', '-mem=AES256', '-mm=Deflate'])]),
        ('seven-header.7z', {'message.txt': ('ZipRipper42!', MESSAGE, None)}, [('message.txt', 'ZipRipper42!', ['-t7z', '-mhe=on'])]),
        ('seven-data.7z', {'message.txt': ('ZipRipper42!', MESSAGE, None)}, [('message.txt', 'ZipRipper42!', ['-t7z', '-mhe=off'])]),
        ('mixed-passwords.zip', {'first.txt': ('AlphaSecret42', FIRST, 8), 'second.txt': ('BetaSecret73', SECOND, 8)}, [('first.txt', 'AlphaSecret42', ['-tzip', '-mem=ZipCrypto', '-mm=Deflate']), ('second.txt', 'BetaSecret73', ['-tzip', '-mem=ZipCrypto', '-mm=Deflate'])]),
        ('unsupported-member.zip', {'first.txt': ('AlphaSecret42', FIRST, 8), 'second.txt': ('BetaSecret73', SECOND, 12)}, [('first.txt', 'AlphaSecret42', ['-tzip', '-mem=ZipCrypto', '-mm=Deflate']), ('second.txt', 'BetaSecret73', ['-tzip', '-mem=ZipCrypto', '-mm=BZip2'])]),
    ]
    with tempfile.TemporaryDirectory(prefix='.fixture-build-', dir=destination) as temporary:
        work = Path(temporary)
        for name, data in [('message.txt', MESSAGE), ('first.txt', FIRST), ('second.txt', SECOND)]:
            (work/name).write_bytes(data)
            os.utime(work/name, (1704067200, 1704067200))
        for filename, members, steps in jobs:
            target = destination/filename
            if not target.exists() and not target.is_symlink():
                candidate = work/filename
                for member_name, password, options in steps:
                    command(tool, ['a', *options, f'-p{password}', candidate, member_name], work)
                validate_archive(tool, candidate, members)
                # Link atomically without replacing a pre-existing destination.
                os.link(candidate, target)
            validate_archive(tool, target, members)
            print(f'Validated and preserved {filename}', flush=True)
    print(f'Fixtures ready: {destination}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError, StopIteration) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
