#!/usr/bin/env python3
"""Run the unchanged official comparator on two existing videos, on CPU only."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[2]
EXPECTED='e143c28e4b3acb885662e0aa238aa00ca17cbcc82077f465f2ce57d0f1225590'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference',type=Path,default=ROOT/'附件/参考/参考.mp4')
    p.add_argument('--candidate',type=Path,default=ROOT/'结果/本次运行/result.mp4')
    p.add_argument('--out',type=Path,default=ROOT/'结果/本次评测')
    p.add_argument('--check',action='store_true');a=p.parse_args()
    comparator=ROOT/'附件/tools/minimax_h3_compare.py'
    if sha(comparator)!=EXPECTED:raise ValueError('official comparator identity mismatch')
    if not a.reference.is_file() or not a.candidate.is_file():raise ValueError('both existing video files are required; generation is disabled')
    command=[sys.executable,str(comparator),'--tasks=fl2va',
        '--model-path=/not-used-for-existing-video-comparison',
        '--reference-fl2va-video='+str(a.reference.resolve()),
        '--infinilm-fl2va-video='+str(a.candidate.resolve()),'--output-dir='+str(a.out.resolve())]
    identity=dict(comparator_sha256=EXPECTED,reference_sha256=sha(a.reference),candidate_sha256=sha(a.candidate),
        command=command,generation_requested=False,official_result='NOT_ISSUED',official_threshold=None)
    if a.check:
        print('EXISTING_EVALUATION_INPUTS_PASS',json.dumps(identity));return 0
    if sys.version_info[:2]!=(3,11) or platform.system()!='Linux' or platform.machine()!='x86_64':
        raise ValueError('run in the designated Linux x86_64 / CPython 3.11 environment; --check is portable')
    a.out.mkdir(parents=True,exist_ok=True)
    manifest=json.loads((ROOT/'附件/manifest.json').read_text());expected={x['path']:x['sha256'] for x in manifest['files']}
    with tempfile.TemporaryDirectory(prefix='fl2va-existing-eval-') as td:
        target=Path(td)/'pylibs';target.mkdir()
        for name in ('python_deps_base.tar.gz','python_deps_metrics.tar.gz'):
            f=ROOT/'附件/offline'/name
            if sha(f)!=expected['附件/offline/'+name]:raise ValueError('offline metric dependency mismatch')
            with tarfile.open(f) as t:
                for member in t.getmembers():
                    if member.isfile() and member.name.endswith('.whl') and not Path(member.name).name.startswith(('._','torchvision')):
                        with zipfile.ZipFile(io.BytesIO(t.extractfile(member).read())) as z:z.extractall(target)
        env=os.environ.copy();env.update(PYTHONPATH=str(target),HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',
            CUDA_VISIBLE_DEVICES='',HIP_VISIBLE_DEVICES='',ROCR_VISIBLE_DEVICES='')
        r=subprocess.run(command,env=env,capture_output=True,text=True)
    (a.out/'official-comparison.log').write_text(r.stdout+r.stderr)
    identity.update(comparator_exit=r.returncode,scope='Existing-video comparison only; no generation time or official acceptance inferred')
    (a.out/'comparison-invocation.json').write_text(json.dumps(identity,indent=2)+'\n')
    print(r.stdout,end='');print(r.stderr,end='',file=sys.stderr)
    print('EXISTING_COMPARISON_EXIT',r.returncode,'official_threshold=null')
    return r.returncode
if __name__=='__main__':raise SystemExit(main())
