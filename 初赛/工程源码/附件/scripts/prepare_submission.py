#!/usr/bin/env python3
"""Verify delivered files and stage offline inputs; never compile or load a model."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

ROOT=Path(__file__).resolve().parents[2]
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda:f.read(1024**2),b''):h.update(data)
    return h.hexdigest()
def verify():
    data=json.loads((ROOT/'附件/manifest.json').read_text())
    for row in data['files']:
        f=ROOT/row['path']
        if not f.is_file() or f.stat().st_size!=row['bytes'] or digest(f)!=row['sha256']:
            raise ValueError('delivered file identity mismatch: '+row['path'])
    print('SUBMISSION_FILES_INTEGRITY_PASS; this is not official acceptance',flush=True)
    return json.loads((ROOT/'附件/submission.json').read_text())
def copy_checked(source,target):
    target.parent.mkdir(parents=True,exist_ok=True)
    if target.exists():
        if digest(source)!=digest(target):raise ValueError('refusing overwrite of different file: '+str(target))
    else:
        with tempfile.NamedTemporaryFile(dir=target.parent,prefix='.'+target.name+'-',delete=False) as f:
            temporary=Path(f.name)
        try:
            shutil.copy2(source,temporary)
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check',action='store_true');p.add_argument('--store',type=Path)
    p.add_argument('--first-frame',type=Path);p.add_argument('--build-only',action='store_true');a=p.parse_args()
    config=verify()
    if a.check:return
    if a.store is None or (not a.build_only and a.first_frame is None):p.error('supply --store and either --build-only or --first-frame')
    if not a.build_only and digest(a.first_frame)!=config['generation_config']['first_frame_sha256']:
        raise ValueError('the organizer sample image does not match the recorded input')
    store=a.store.expanduser().resolve();store.mkdir(parents=True,exist_ok=True)
    for row in config['runtime_inputs']:copy_checked(ROOT/row['package_path'],store/row['store_path'])
    if not a.build_only:copy_checked(a.first_frame,store/'sample_first_frame.jpg')
    copy_checked(ROOT/'附件/参考/参考.mp4',store/'songshan/baseline-20261105121609-30339b-reference.mp4')
    print('SUBMISSION_INPUTS_READY',store,flush=True)
if __name__=='__main__':main()
