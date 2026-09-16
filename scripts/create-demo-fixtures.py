#!/usr/bin/env python3
"""Create and validate the local synthetic demo kit; never overwrite existing files.
Requires pypdf with cryptography, local 7zz and RAR 6.x (for RAR3 creation).
Tools stay local. RAR is a separately licensed trial tool, not redistributed.
"""
import argparse, hashlib, json, os, subprocess, tempfile
from pathlib import Path
from pypdf import PdfWriter, PdfReader
from pypdf.generic import DecodedStreamObject, NameObject, DictionaryObject

ROOT = Path(__file__).resolve().parent.parent
CASES = [
 ('zip-traditional.zip', 'ZIP traditional', 'PKZIP', 'CopperFalcon981!', ['-tzip', '-mem=ZipCrypto']),
 ('zip-aes256.zip', 'ZIP AES-256', 'ZIP', 'AmberOtter985!', ['-tzip', '-mem=AES256']),
 ('seven-header.7z', '7z encrypted headers', '7z', 'SilverMaple989!', ['-t7z', '-mhe=on']),
 ('seven-data.7z', '7z encrypted data', '7z', 'VioletRobin993!', ['-t7z', '-mhe=off', '-m0=Copy']),
 ('rar3-header.rar', 'RAR3 encrypted headers', 'rar', 'GoldenBadger997!', ['-ma4']),
 ('rar5-header.rar', 'RAR5 encrypted headers', 'RAR5', 'CrimsonPanda1001!', ['-ma5']),
 ('pdf-r2.pdf', 'PDF R2 · RC4 40-bit', 'PDF', 'IndigoHeron1005!', 'RC4-40'),
 ('pdf-r3.pdf', 'PDF R3 · RC4 128-bit', 'PDF', 'ScarletWillow1009!', 'RC4-128'),
 ('pdf-r4.pdf', 'PDF R4 · AES-128', 'PDF', 'AzureFox1013!', 'AES-128'),
 ('pdf-r5.pdf', 'PDF R5 · AES-256', 'PDF', 'EmeraldLynx1017!', 'AES-256-R5'),
 ('pdf-r6.pdf', 'PDF R6 · AES-256', 'PDF', 'IvoryRaven1021!', 'AES-256'),
]
PAYLOAD = b'ZipRipper synthetic demo. This file contains no private data.\n' * 12

def command(args, cwd=None):
    r = subprocess.run(list(map(str,args)), cwd=cwd, capture_output=True, timeout=90)
    if r.returncode: raise ValueError(f'Command failed: {args[0]}: {r.stderr.decode(errors="replace")}')
    return r.stdout

def preserve(path, data):
    if path.exists():
        if not path.is_file() or path.read_bytes() != data: raise ValueError(f'Existing file differs; preserved: {path}')
    else:
        with path.open('xb') as f: f.write(data)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--destination',type=Path,default=ROOT/'test-files')
    ap.add_argument('--sevenzip',type=Path,default=ROOT/'.local/fixtures/.tools/7zz')
    ap.add_argument('--rar',type=Path,default=ROOT/'.local/demo-tools/rar/rar')
    ap.add_argument('--runtime',type=Path,default=ROOT/'.local/runtime')
    args=ap.parse_args()
    args.runtime=args.runtime.resolve(); args.sevenzip=args.sevenzip.resolve(); args.rar=args.rar.resolve()
    dest=args.destination.resolve(); dest.mkdir(parents=True,exist_ok=True)
    words=[]; seen=set()
    with (args.runtime/'run/password.lst').open(encoding='utf8') as f:
        for line in f:
            word=line.rstrip('\r\n')
            if word and not word.startswith('#!comment:') and word not in seen:
                seen.add(word); words.append(word)
            if len(words)==2000: break
    assert len(words)==2000
    for i,(_,_,_,password,_) in enumerate(CASES): words[980+i*4]=password
    preserve(dest/'wordlist-2000.txt', ('\n'.join(words)+'\n').encode())
    manifest=[]; vectors=[]
    # Stage on the destination filesystem so no-overwrite hard-link publication
    # also works when --destination is an external volume or mount point.
    with tempfile.TemporaryDirectory(prefix='.zipripper-demo-', dir=dest) as temporary:
        work=Path(temporary); (work/'message.txt').write_bytes(PAYLOAD)
        for i,(filename,name,fmt,password,options) in enumerate(CASES):
            target=dest/filename; candidate=work/filename
            if not target.exists():
                if filename.endswith('.pdf'):
                    writer=PdfWriter(); page=writer.add_blank_page(width=612,height=792)
                    stream=DecodedStreamObject(); stream.set_data(b'BT /F1 18 Tf 54 720 Td (ZipRipper synthetic password test) Tj 0 -28 Td (No private data. See manifest.json for the test password.) Tj ET')
                    font=DictionaryObject({NameObject('/Type'):NameObject('/Font'),NameObject('/Subtype'):NameObject('/Type1'),NameObject('/BaseFont'):NameObject('/Helvetica')})
                    page[NameObject('/Resources')]=DictionaryObject({NameObject('/Font'):DictionaryObject({NameObject('/F1'):writer._add_object(font)})})
                    page[NameObject('/Contents')]=writer._add_object(stream)
                    writer.add_metadata({'/Title': name+' synthetic test'})
                    writer.encrypt(password, owner_password=password+'-owner',algorithm=options)
                    writer.write(candidate)
                elif filename.endswith('.rar'):
                    command([args.rar,'a','-idq',*options,'-hp'+password,candidate,'message.txt'],cwd=work)
                else: command([args.sevenzip,'a',*options,'-p'+password,candidate,'message.txt'],cwd=work)
                os.link(candidate,target)
            if target.is_symlink(): raise ValueError(f'Refusing symlink fixture: {target}')
            if filename.endswith('.pdf'):
                reader=PdfReader(target); assert reader.is_encrypted and reader.decrypt(password)
                assert 'ZipRipper synthetic password test' in reader.pages[0].extract_text()
                revision=int(reader.trailer['/Encrypt']['/R'])
            else:
                assert command([args.sevenzip,'x','-so','-p'+password,target,'message.txt'])==PAYLOAD
                revision=None
            hashline=command([args.runtime/'run/extract-hash',target]).decode().strip().splitlines()[0]
            # Normalize the synthetic filename; data and parameters remain exact.
            hashline='benchmark:'+hashline.split(':',2)[1]
            item={'file':filename,'name':name,'format':fmt,'password':password,'wordlistLine':981+i*4,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'pdfRevision':revision}
            manifest.append(item)
            if filename!='seven-data.7z': vectors.append({'id':filename.split('.')[0], 'name':name,'format':fmt,'hashLine':hashline,'password':password,'metal':filename!='pdf-r6.pdf'})
            print(f'Validated {filename}: line {item["wordlistLine"]}',flush=True)
    preserve(dest/'manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    preserve(dest/'benchmark-vectors.json',(json.dumps(vectors,indent=2)+'\n').encode())
    print('Ready:',dest)

if __name__=='__main__': main()
