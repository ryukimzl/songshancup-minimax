#!/bin/bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
python3 - "$root" <<'PREPARE_PY'
import hashlib,json,os,shutil,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
manifest=json.loads((root/'传输清单.json').read_text())
relative=Path(manifest['engineering']['directory'])
if relative.is_absolute() or '..' in relative.parts:raise ValueError('非法源码路径')
project=root.parent/relative
submission=json.loads((project/'附件/submission.json').read_text())
store_path={row['package_path']:row['store_path'] for row in submission.get('runtime_inputs',[])}
expected=json.loads((project/'附件/manifest.json').read_text())['files']
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda:f.read(1024**2),b''):h.update(data)
    return h.hexdigest()
# Verify the source directory before restoring its missing offline inputs.
for row in expected:
    if not row['path'].startswith('附件/offline/'):
        if sha(project/row['path'])!=row['sha256']:raise ValueError('源码文件不符：'+row['path'])
afs_env=os.environ.get('IFAB_AFS_HOME')
afs=Path(afs_env or Path.home()).expanduser()
def under(path,base):
    try:
        path.resolve().relative_to(base.resolve());return True
    except ValueError:return False
def candidates(row):
    yield root/row['name'],False
    stored=store_path.get(row['package_path'])
    if stored:
        for base in (afs,afs/'songshan',Path.home(),Path.home()/'songshan'):
            yield base/stored,True
for row in manifest['files']:
    relative=Path(row['package_path'])
    if relative.is_absolute() or '..' in relative.parts or not str(relative).startswith('附件/offline/'):
        raise ValueError('非法依赖路径')
    source=None;from_afs=False;seen=[]
    for candidate,is_afs in candidates(row):
        if candidate.is_file():
            seen.append(str(candidate))
            if candidate.stat().st_size==row['bytes'] and sha(candidate)==row['sha256']:
                source,from_afs=candidate,is_afs
                break
    if source is None:
        raise ValueError('依赖缺失或校验不符：'+row['name']+'；已检查 '+', '.join(seen or ['无同名文件']))
    target=project/relative
    if target.is_symlink() or target.exists():
        if not target.is_file() or sha(target)!=row['sha256']:
            raise ValueError('已有依赖内容不同，未覆盖：'+str(target))
        continue
    target.parent.mkdir(parents=True,exist_ok=True)
    if from_afs or (afs_env and under(source,afs)):
        # 依赖已在 AFS 时只建链接，避免在 AFS 或临时工作区重复复制 913MB。
        target.symlink_to(source)
    else:
        with tempfile.NamedTemporaryFile(dir=target.parent,delete=False) as f:temporary=Path(f.name)
        try:
            shutil.copy2(source,temporary)
            temporary.replace(target)
        finally:temporary.unlink(missing_ok=True)
for row in expected:
    if sha(project/row['path'])!=row['sha256']:raise ValueError('工程文件校验不符：'+row['path'])
print('复现输入已就绪：'+str(project))
PREPARE_PY