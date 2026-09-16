"""Developer ID release gate: sign, notarize and staple app and branded DMG."""
import hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/ZipRipper.app'
DMG = ROOT / 'dist/packages/ZipRipper-0.5.3-macOS-arm64.dmg'

def run(*args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if result.returncode:
        # Notary credentials and local account paths must never appear in CI errors.
        raise SystemExit(f'{Path(str(args[0])).name} failed ({result.returncode}); release stopped')
    return result.stdout

def notarize(path, evidence):
    auth = (['--keychain-profile', os.environ['NOTARY_PROFILE']] if os.environ.get('NOTARY_PROFILE')
            else ['--key', os.environ['APPLE_API_KEY_PATH'], '--key-id', os.environ['APPLE_API_KEY_ID'],
                  '--issuer', os.environ['APPLE_API_ISSUER_ID']])
    if os.environ.get('SIGNING_KEYCHAIN'):
        auth += ['--keychain', os.environ['SIGNING_KEYCHAIN']]
    result = json.loads(run('xcrun', 'notarytool', 'submit', path, *auth, '--wait', '--output-format', 'json'))
    evidence[path.name] = {'status': result.get('status'), 'submissionId': result.get('id')}
    if result.get('status') != 'Accepted':
        raise SystemExit('Apple did not accept ' + path.name + '; no distribution created')
    print('Apple accepted ' + path.name, flush=True)

def main():
    identity = os.environ['MACOS_SIGN_IDENTITY']
    if not identity.startswith('Developer ID Application:'): raise SystemExit('Developer ID Application identity required')
    import plistlib
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    if info['CFBundleShortVersionString'] != '0.5.3': raise SystemExit('Unexpected app version')
    ref = os.environ.get('GITHUB_REF', '')
    if ref.startswith('refs/tags/') and ref != 'refs/tags/v0.5.3': raise SystemExit('Tag/version mismatch')
    for path in sorted(APP.rglob('*')):
        if not path.is_file() or path.is_symlink(): continue
        with path.open('rb') as stream: magic = stream.read(4)
        if magic in [bytes.fromhex(x) for x in ('cffaedfe','cefaedfe','cafebabe','bebafeca')]:
            run('codesign','--force','--options','runtime','--timestamp','--sign',identity,path)
    run('codesign','--force','--options','runtime','--timestamp','--sign',identity,APP)
    run('codesign','--verify','--deep','--strict',APP)
    evidence = {}
    with tempfile.TemporaryDirectory(prefix='zipripper-notary-') as work:
        archive = Path(work) / 'ZipRipper.zip'
        run('ditto','-c','-k','--keepParent',APP,archive)
        notarize(archive,evidence)
    run('xcrun','stapler','staple',APP)
    run('xcrun','stapler','validate',APP)
    print('App stapled; packaging branded DMG', flush=True)
    run(sys.executable,ROOT/'scripts/make-dmg.py')
    notarize(DMG,evidence)
    run('xcrun','stapler','staple',DMG)
    run('xcrun','stapler','validate',DMG)
    run('codesign','--verify','--deep','--strict',APP)
    run('codesign','--verify','--strict',DMG)
    run('spctl','--assess','--type','execute',APP)
    run('spctl','--assess','--type','open','--context','context:primary-signature',DMG)
    (DMG.parent/'SHA256SUMS.txt').write_text(hashlib.sha256(DMG.read_bytes()).hexdigest()+'  '+DMG.name+'\n')
    (DMG.parent/'release-verification.json').write_text(json.dumps({'version':'0.5.3','apple':evidence,'gatekeeper':'accepted','stapled':['app','dmg']},indent=2)+'\n')
    print('App and DMG accepted, stapled and Gatekeeper verified.', flush=True)

if __name__ == '__main__': main()
