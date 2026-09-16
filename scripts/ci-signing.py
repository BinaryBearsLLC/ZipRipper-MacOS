"""Ephemeral Apple signing setup. Credential values are never printed or committed."""
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        # CalledProcessError would include secret-bearing command arguments.
        raise SystemExit(f'{args[0]} signing operation failed (exit {result.returncode}); credentials redacted')


def main():
    work = Path(os.environ['RUNNER_TEMP']) / 'zipripper-signing'
    state = work / 'state.json'
    if sys.argv[1] == 'cleanup':
        if state.exists():
            keys = json.loads(state.read_text())
            run('security', 'list-keychains', '-d', 'user', '-s', *keys)
        keychain = work / 'signing.keychain-db'
        if keychain.exists():
            run('security', 'delete-keychain', str(keychain))
        if work.exists():
            shutil.rmtree(work)
        return
    required = ('APPLE_API_KEY_BASE64', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER_ID',
                'APPLE_CERTIFICATE_P12_BASE64', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_SIGNING_IDENTITY')
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit('Required signing secrets missing: ' + ', '.join(missing))
    identity = os.environ['APPLE_SIGNING_IDENTITY']
    if not identity.startswith('Developer ID Application:'):
        raise SystemExit('An Apple Developer ID Application identity is required')
    os.umask(0o077)
    work.mkdir(mode=0o700)
    existing = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
    state.write_text(json.dumps(existing))
    password = secrets.token_urlsafe(32)
    print(f'::add-mask::{password}', flush=True)
    keychain = str(work / 'signing.keychain-db')
    run('security', 'create-keychain', '-p', password, keychain)
    run('security', 'set-keychain-settings', '-lut', '21600', keychain)
    run('security', 'unlock-keychain', '-p', password, keychain)
    run('security', 'list-keychains', '-d', 'user', '-s', keychain, *existing)
    certificate, api_key = work / 'certificate.p12', work / 'api-key.p8'
    try:
        certificate.write_bytes(base64.b64decode(os.environ['APPLE_CERTIFICATE_P12_BASE64'], validate=True))
        api_key.write_bytes(base64.b64decode(os.environ['APPLE_API_KEY_BASE64'], validate=True))
        run('security', 'import', str(certificate), '-k', keychain,
            '-P', os.environ['APPLE_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign')
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, keychain)
        run('xcrun', 'notarytool', 'store-credentials', 'zipripper-release', '--key', str(api_key),
            '--key-id', os.environ['APPLE_API_KEY_ID'], '--issuer', os.environ['APPLE_API_ISSUER_ID'],
            '--keychain', keychain)
    finally:
        certificate.unlink(missing_ok=True)
        api_key.unlink(missing_ok=True)
    with open(os.environ['GITHUB_ENV'], 'a') as env:
        for key, value in {'MACOS_SIGN_IDENTITY': identity, 'SIGNING_KEYCHAIN': keychain,
                           'NOTARY_PROFILE': 'zipripper-release', 'SIGNED_MACOS': '1'}.items():
            if '\n' in value or '\r' in value:
                raise SystemExit('Invalid signing configuration')
            env.write(f'{key}={value}\n')
    print('Temporary signing identity and notarization profile configured')


if __name__ == '__main__':
    main()
