"""Reject private local paths, signing material and obvious credentials in public files."""
import re, subprocess, sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
files=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
patterns=[re.compile(r'/'+'Users/'+r'[^/\s"\']+'),re.compile(r'-----BEGIN '+'(?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),re.compile(r'gh[pousr]_' + r'[A-Za-z0-9]{30,}'),re.compile(r'github_pat_' + r'[A-Za-z0-9_]{40,}')]
failures=[]
for name in files:
 if not name:continue
 p=root/name
 if not p.is_file():continue
 if p.suffix.lower() in {'.p8','.p12','.pem','.keychain'} or p.name.startswith('.env'):
  failures.append(name);continue
 data=p.read_bytes().decode('utf8',errors='ignore')
 if any(pattern.search(data) for pattern in patterns):failures.append(name)
if failures:
 print('Public audit failed in files: '+', '.join(failures));sys.exit(1)
print('Public file audit passed.')
