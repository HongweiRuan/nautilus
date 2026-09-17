#!/usr/bin/env python3
import argparse,hashlib,io,json,subprocess,tarfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--repo',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
if a.output.exists():p.error('output already exists')
raw=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=a.repo)
files=sorted({x for x in raw.decode().split('\0') if x and (a.repo/x).is_file()})
status=subprocess.check_output(['git','status','--short','-uall'],cwd=a.repo,text=True)
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=a.repo,text=True).strip()
with tarfile.open(a.output,'w:gz') as tar:
 for name in files:tar.add(a.repo/name,arcname=name,recursive=False)
 data=json.dumps({'head':head,'status':status,'files':len(files)},indent=2).encode();info=tarfile.TarInfo('RUNTIME_PROVENANCE.json');info.size=len(data);tar.addfile(info,io.BytesIO(data))
print(json.dumps({'head':head,'files':len(files),'output':str(a.output),'sha256':hashlib.sha256(a.output.read_bytes()).hexdigest()}))
