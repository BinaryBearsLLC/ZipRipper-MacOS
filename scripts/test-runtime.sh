#!/bin/bash
# Real recovery verification against known-password fixtures, including a relocated copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${1:-$ROOT/.local/runtime}"
FIXTURES="${2:-$ROOT/.local/fixtures}"
/usr/bin/python3 - "$RUNTIME" "$FIXTURES" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

runtime, fixtures = (Path(p).resolve() for p in sys.argv[1:])
cases = json.loads((fixtures / 'cases.json').read_text())
words = fixtures / 'words.txt'
originals = {case['file']: hashlib.sha256((fixtures/case['file']).read_bytes()).hexdigest() for case in cases}
env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
for name in ['PERL5LIB','PERLLIB','PERL5OPT','DYLD_LIBRARY_PATH','DYLD_FALLBACK_LIBRARY_PATH']:
    env.pop(name, None)
results = []

def call(args, cwd, timeout=120):
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if p.returncode:
        raise AssertionError(f'{args[0]} exited {p.returncode}: {p.stderr[-4000:]}')
    return p

with tempfile.TemporaryDirectory(prefix='ZipRipper validation è ') as temporary:
    base = Path(temporary)
    moved = base / 'Moved runtime with spaces è'
    shutil.copytree(runtime, moved, symlinks=True)
    for label, engine in [('original', runtime), ('relocated', moved)]:
        call([engine/'perl/bin/perl', '-MCompress::Raw::Lzma', '-MCompress::Zlib', '-MDigest::MD5', '-e', 'print "modules loaded\\n"'], base)
        for index, case in enumerate(cases):
            job = base / f'{label} job {index}'
            job.mkdir()
            archive = fixtures / case['file']
            hash_path, pot, session = job/'hash.txt', job/'passwords.pot', job/'session'
            extracted = call([engine/'run/extract-hash', archive], job)
            assert case['marker'] in extracted.stdout, (case, extracted.stdout, extracted.stderr)
            hash_path.write_text(extracted.stdout)
            bad = job/'wrong.txt'
            bad.write_text('deliberately-invalid-9ZQp8XT\n')
            call([engine/'bin/john', f'--format={case["format"]}', f'--wordlist={bad}', f'--pot={pot}', f'--session={session}', hash_path], job)
            assert not pot.exists() or not pot.read_text().strip(), f'False positive for {case["file"]}'
            recovered = call([engine/'bin/john', f'--format={case["format"]}', f'--wordlist={words}', f'--pot={pot}', f'--session={session}', '--progress-every=1', hash_path], job)
            found = call([engine/'bin/john', f'--format={case["format"]}', f'--pot={pot}', '--show', hash_path], job)
            assert f':{case["password"]}' in found.stdout, (case, found.stdout, recovered.stderr)
            result = {'location':label, 'file':case['file'], 'format':case['format'], 'wrongPasswordRejected':True, 'recovered':True}
            results.append(result)
            print(f'PASS {label}: {case["file"]}', flush=True)
    # John forwards SIGTERM to its fork workers as graceful SIGINT. A parent-only
    # SIGINT assumes terminal group delivery and is unsuitable for Foundation.Process.
    job = base/'checkpoint job'
    job.mkdir()
    chosen = next(c for c in cases if c['format'] == '7z')
    hash_path = job/'hash.txt'
    hash_path.write_text(call([moved/'run/extract-hash', fixtures/chosen['file']], job).stdout)
    session, pot = job/'session', job/'passwords.pot'
    log = job/'checkpoint.log'
    def interrupt(args):
        with log.open('ab') as out:
            proc = subprocess.Popen([str(a) for a in args], cwd=job, env=env, stdout=out, stderr=out)
            time.sleep(3)
            assert proc.poll() is None, log.read_text()
            proc.send_signal(signal.SIGTERM)
            code = proc.wait(timeout=30)
            assert code in (0, 1, 2), (code, log.read_text())
            return code
    first_code = interrupt([moved/'bin/john', '--format=7z', '--mask=?a?a?a?a?a?a?a?a', '--fork=2', '--progress-every=1', f'--session={session}', f'--pot={pot}', hash_path])
    assert (job/'session.rec').is_file(), log.read_text()
    assert (job/'session.2.rec').is_file(), log.read_text()
    before = (job/'session.rec').read_bytes()
    second_code = interrupt([moved/'bin/john', f'--restore={session}'])
    assert (job/'session.rec').is_file(), log.read_text()
    assert before != (job/'session.rec').read_bytes(), 'Checkpoint did not advance after restore'
    results.append({'forkWorkers':2,'pauseSignal':'SIGTERM','firstExitCode':first_code,'restoreExitCode':second_code,'checkpointAdvanced':True})
    print('PASS CPU fork=2 pause + restore + advancing checkpoint', flush=True)
    (fixtures/'checkpoint-evidence.log').write_text(log.read_text())
for name, expected in originals.items():
    assert hashlib.sha256((fixtures/name).read_bytes()).hexdigest() == expected, f'Input modified: {name}'
report = {'runtime':str(runtime), 'validatedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'results':results, 'inputsUnchanged':True}
(fixtures/'runtime-validation.json').write_text(json.dumps(report, indent=2)+'\n')
print(f'PASS {len(cases)} formats/variants in both locations; source archives unchanged')
PY
