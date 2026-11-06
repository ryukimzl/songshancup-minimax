#!/bin/bash
# FL2VA：每次只做一个显式任务；无自动追加、自动回退或自动重编。
usage() {
    cat <<'HELP'
用法: bash run_fl2va.sh <build-core|build-lm|native>
任务必须显式指定；无参数时立即退出，不默认生成。
平台批作业：入口选择 run_fl2va.sh，参数填单个任务名，并保存启动配置。
native      单次完整规格：928x768、124帧、24fps、50步、带音频
build-core  干净构建 Core 与其 Python 绑定，导出独立产物；不推理
build-lm    构建 LM 绑定，导出独立产物；不构建 Core，不推理

可选环境：SHARED、PROMPT、SEED、STEPS、NUM_FRAMES、HEIGHT、WIDTH、FIRST_FRAME。
不设置时使用固定 r10 诊断候选与样例；尺寸 HEIGHT/WIDTH 必须同时指定。
复用新构建产物：SDK_ARTIFACT / SDK_ARTIFACT_SHA256；LM_ARTIFACT / LM_ARTIFACT_SHA256。
构建成功后自动登记产物，下一步骤按源码与SDK指纹复用。
native 自动保存 evaluation.json / evaluation.log；无相似度阈值或统一性能Baseline时标为待评测。
默认核对已保存参考；EVALUATION_CONFIG 可显式指定其他完整配置。
构建产物校验通过只说明身份与文件完整，不代表正确性或参赛许可验收。
HELP
}
if [ "$#" -eq 0 ]; then
    echo 'FL2VA_TASK_REQUIRED：必须指定 build-core、build-lm 或 native；本次未启动任何任务。' >&2
    usage >&2
    exit 2
fi
case "${1:-}" in --help|-h) usage; exit 0 ;; esac
case "${1:-}" in
    --inside) [ "$#" -eq 2 ] || { usage >&2; exit 2; }
              MODE="$2" ;;
    *) [ "$#" -eq 1 ] || { usage >&2; exit 2; }
       MODE="$1"; MODE="${MODE#MODE=}"
       case "$MODE" in native|build-core|build-lm) ;;
           *) usage; exit 2 ;; esac
       if timeout --signal=TERM --kill-after=45s 1560 bash "$0" --inside "$MODE"; then
           exit 0
       else
           wrapper_rc=$?
           printf 'FL2VA_WRAPPER_EXIT rc=%s task=%s timeout_limit_seconds=1560\n' "$wrapper_rc" "$MODE" >&2
           exit "$wrapper_rc"
       fi ;;
esac
case "$MODE" in native|build-core|build-lm) ;; *) exit 2 ;; esac
set -euo pipefail
umask 002
UPLOADS="${IFAB_AFS_HOME:-$HOME}"
PERSIST="$UPLOADS/songshan"
SHARED="${SHARED:-/public/home/aclsylqidf/shared/MiniMax-H3}"
export SHARED
SOURCE_SHA256=b6cbebac036ccdcaeaf77a05ee4d4258d5aa0bc279e1aaf1d427f27f2e743125
SOURCE_NAME=fl2va_source_20261105_r10.tar.gz
GPUS=0,1,2,3,4,5,6,7
export GPUS
WORK=""
for base in "${TMPDIR:-}" /tmp /var/tmp; do
    [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
    mkdir -p "$base/songshan" 2>/dev/null || continue
    WORK="$(mktemp -d "$base/songshan/fl2va.XXXXXX")" && break
done
[ -n "$WORK" ] || { echo "没有可写工作目录"; exit 2; }
mkdir -p "$WORK/tmp"
export WORK TMPDIR="$WORK/tmp" TMP="$WORK/tmp" TEMP="$WORK/tmp"
INFINI_ROOT="$WORK/.infini"
export INFINI_ROOT
mkdir -p "$PERSIST" "$WORK/validation-output"
LOG="$WORK/fl2va-job.log"
exec 3>&1 4>&2
exec >> "$LOG" 2>&1
finish() {
    compute_rc=$?
    set +e
    trap - EXIT TERM INT
    export_rc=0
    printf 'FL2VA_COMPUTE_EXIT rc=%s\n' "$compute_rc"
    if [ "$MODE" = native ] && [ ! -f "$WORK/validation-output/evaluation.json" ]; then
        python3 - "$WORK/validation-output/evaluation.json" "$compute_rc" <<'FAILED_EVALUATION_PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(schema=1,local_basic_gate='FAIL',
    reason='生成或准备阶段未完成',process_exit=int(sys.argv[2]),official_result='NOT_ISSUED'),ensure_ascii=False,indent=2)+'\n')
FAILED_EVALUATION_PY
        echo 'EVAL_LOCAL_BASIC_GATE FAIL：生成或准备未完成'
    fi
    exec 1>&3 2>&4
    cat "$LOG"
    stamp=$(date +%Y%m%d%H%M%S)
    if [ -d "$WORK/validation-output" ]; then
        if [ "$MODE" = build-core ] && [ "$compute_rc" -ne 0 ]; then
            # Preserve potentially useful build files without treating them as
            # an installed SDK, a successful build or a reusable Core artifact.
            python3 - "$SOURCE_SHA256" <<'PARTIAL_CORE_PY'
import hashlib,json,os,pathlib,shutil,sys
work=pathlib.Path(os.environ['WORK']);core=work/'src/InfiniCore';out=work/'validation-output'
paths={};copied={};build=core/'build'
for name in ('libinfinicore_cpp_api.so','libinfiniop.so','libinfinirt.so','libinfiniccl.so'):
    matches=list(build.rglob(name)) if build.is_dir() else []
    if len(matches)==1 and matches[0].is_file():
        dest=out/'partial-core/lib'/name;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(matches[0],dest);paths[name]=str(matches[0].relative_to(core))
        copied[name]=hashlib.sha256(dest.read_bytes()).hexdigest()
if copied and (core/'include').is_dir():shutil.copytree(core/'include',out/'partial-core/include')
(out/'partial-core.json').write_text(json.dumps(dict(schema=1,source_archive_sha256=sys.argv[1],
    source_paths=paths,sha256=copied,status='UNVERIFIED_PARTIAL',complete_core_artifact=False,
    reason='Files captured after failure; not an installed or validated SDK; cannot register as successful Core'),indent=2)+'\n')
print('PARTIAL_CORE_CAPTURED libraries='+str(len(copied))+' status=UNVERIFIED_PARTIAL',flush=True)
PARTIAL_CORE_PY
            [ "$?" -eq 0 ] || export_rc=5
        fi
        # Console retention can truncate early output; snapshot the complete raw
        # log through the compute exit and partial-file capture before export.
        cp "$LOG" "$WORK/validation-output/fl2va-job.log" || export_rc=5
        # Export a regular archive; do not recreate AFS directories or chmod them.
        python3 - "$WORK/validation-output" "$PERSIST/fl2va-output-${stamp}.tar.gz" > "$WORK/artifact_export.log" 2>&1 <<'EXPORT_ARTIFACTS_PY'
"""Write evidence as one regular archive; do not set remote directory metadata."""
import gzip
import hashlib
import json
from pathlib import Path
import sys
import tarfile


class DigestWriter:
    def __init__(self, raw):
        self.raw=raw
        self.digest=hashlib.sha256()
        self.size=0
    def write(self, data):
        written=self.raw.write(data)
        if written!=len(data):raise OSError('short artifact write')
        self.digest.update(data)
        self.size+=written
        return written
    def flush(self):self.raw.flush()


def normalized(info):
    if not (info.isfile() or info.isdir()):
        raise ValueError('unsupported evidence entry: '+info.name)
    info.uid=info.gid=0
    info.uname=info.gname=''
    info.mode=0o755 if info.isdir() else 0o644
    info.mtime=0
    info.pax_headers={}
    return info


def export(source, target):
    source=Path(source);target=Path(target)
    if not source.is_dir():raise ValueError('missing evidence directory')
    with target.open('xb') as raw:
        writer=DigestWriter(raw)
        with gzip.GzipFile(filename='',mode='wb',fileobj=writer,compresslevel=3,mtime=0) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|',format=tarfile.PAX_FORMAT) as archive:
                archive.add(str(source),arcname='validation-output',recursive=True,filter=normalized)
        writer.flush()
    return dict(path=str(target),bytes=writer.size,sha256=writer.digest.hexdigest())


def main():
    try:
        result=export(sys.argv[1],sys.argv[2])
    except (OSError,ValueError,tarfile.TarError) as exc:
        print('ARTIFACT_EXPORT_FAIL',type(exc).__name__,str(exc),flush=True)
        raise SystemExit(5)
    print('ARTIFACT_EXPORT_PASS',json.dumps(result),flush=True)


if __name__=='__main__':main()
EXPORT_ARTIFACTS_PY
        [ "$?" -eq 0 ] || export_rc=5
        cat "$WORK/artifact_export.log"
        cat "$WORK/artifact_export.log" >> "$LOG"
    fi
    if [ "$compute_rc" -eq 0 ] && [ "$export_rc" -eq 0 ] && { [ "$MODE" = build-core ] || [ "$MODE" = build-lm ]; }; then
        python3 - "$MODE" "$PERSIST" "$SOURCE_SHA256" "$WORK/artifact_export.log" <<'PUBLISH_BUILD_PY'
import datetime,json,os,pathlib,sys,uuid
mode,persist,source,log=sys.argv[1:];kind='core' if mode=='build-core' else 'lm'
lines=pathlib.Path(log).read_text().splitlines()
r=json.loads(next(line.split(' ',1)[1] for line in lines if line.startswith('ARTIFACT_EXPORT_PASS ')))
receipt=dict(schema=1,kind=kind,source_archive_sha256=source,artifact=r['path'],sha256=r['sha256'])
if kind=='lm':receipt.update(sdk_artifact=os.environ['SDK_ARTIFACT'],sdk_artifact_sha256=os.environ['SDK_ARTIFACT_SHA256'])
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d%H%M%S%f')
target=pathlib.Path(persist)/('reproduction-'+kind+'-'+source[:12]+'-'+stamp+'-'+uuid.uuid4().hex[:6]+'.json')
with target.open('x') as f:json.dump(receipt,f);f.write('\n')
print('BUILD_REGISTERED',kind,str(target))
PUBLISH_BUILD_PY
        [ "$?" -eq 0 ] || export_rc=5
    fi
    for file in "$LOG"; do
        if [ -f "$file" ]; then
            gzip -c "$file" > "$PERSIST/fl2va-${stamp}-$(basename "$file").gz" || export_rc=5
        fi
    done
    final_rc=$compute_rc
    if [ "$final_rc" -eq 0 ] && [ "$export_rc" -ne 0 ]; then final_rc=5; fi
    if ! printf 'exit=%s compute_exit=%s export_exit=%s log_prefix=fl2va-%s\n' "$final_rc" "$compute_rc" "$export_rc" "$stamp" > "$PERSIST/fl2va-last-status.txt"; then
        export_rc=5
        if [ "$final_rc" -eq 0 ]; then final_rc=5; fi
    fi
    printf 'FL2VA_JOB_EXIT rc=%s compute_rc=%s export_rc=%s\n' "$final_rc" "$compute_rc" "$export_rc"
    exit "$final_rc"
}


trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
say() { echo "[$(date +%H:%M:%S)] $*"; echo "[$(date +%H:%M:%S)] $*" >&3; }
check_archive() { printf '%s  %s\n' "$2" "$1" | sha256sum -c -; }
echo "FL2VA_SCRIPT_VERSION=20261106-r10-one-build task=$MODE"



untar() {
    mkdir -p "$2"
    tar --warning=no-unknown-keyword -xzf "$1" -C "$2" > "$WORK/.untar.out" 2>&1
    local rc=$?
    grep -v "LIBARCHIVE.xattr\|Ignoring unknown" "$WORK/.untar.out" | tail -2 || true
    return $rc
}



python3 - <<'ARGUMENTS_PY'
import os
if bool(os.getenv('HEIGHT'))!=bool(os.getenv('WIDTH')):
    raise ValueError('HEIGHT and WIDTH must be supplied together')
for key in ('HEIGHT','WIDTH'):
    if os.getenv(key) and (int(os.environ[key])<128 or int(os.environ[key])%32):
        raise ValueError(key+' must be >=128 and divisible by 32')
if int(os.getenv('STEPS','50'))<2 or int(os.getenv('NUM_FRAMES','124'))<1:
    raise ValueError('STEPS must be >=2 and NUM_FRAMES must be positive')
int(os.getenv('SEED','42'))
ARGUMENTS_PY

check_archive "$UPLOADS/$SOURCE_NAME" "$SOURCE_SHA256"
# Dependency hashes are pinned below, before any extraction or compilation.
check_archive "$UPLOADS/python_deps_base.tar.gz" 704341786e71c23ea6cb5812cc5b4af5f244e0a3bc110fcef1bdc7984250ba0b
check_archive "$UPLOADS/python_deps_models.tar.gz" 488611f264b1d126f1c0ac6ef3ccfa3de978f56e23e2fb89b220ae235d8404dd
check_archive "$UPLOADS/python_deps_metrics.tar.gz" a694cdca68d1b9d1974ce7402df60edf599b09f44f78ee0d70c777e8e98dad88
if [ "$MODE" = build-core ] || [ "$MODE" = build-lm ]; then check_archive "$UPLOADS/build_tool_xmake.tar.gz" 99df17ad8eaaba5d1e918c6915ba210b08b7931203fb6241e096e9010526f8f1; fi
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part00" bfaa757e842676886c87e896e5829302a7ed9410dd3e10de12280614e89ec488
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part01" 33113a801a3a34511f6db536a848221f68eddcb5a4db30a05d8d122df11970e6
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part02" 1e287480287f0a187257e7fcfd50572e62dac5a9323cddce06e7cf8d5d0149a2
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part03" 5c25cd0275d8da39cbc72d7b0dde24a32ea305c51b3073edb7a9599e4c76781c
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part04" dcd9aed482d4b9d5e8d911de05c6449a825110f7de3aa49b9f06acd735534a24
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part05" 98e8e63ea06dfd32424b935a1afc1119711d0f0f11e4c0ab7c8fe9295a3a3c50
check_archive "$UPLOADS/flash_attention/flash_attention.whl.part06" 7c4e4b3d0eb30d6a90864e780755b5496a2a35ce22ec72d877642f0b020fd3d1
check_archive "$UPLOADS/flash_attention/triton_dtk2604.whl" e397b16365da22508353ce44a45f5be82f8ee58e49853a3df06aa8f6f83d5581
if [ -z "${FIRST_FRAME:-}" ]; then check_archive "$UPLOADS/sample_first_frame.jpg" 1e71abf29876f248088a11211a350ed3d26a0c68aa34f6e45738771eb2d45a22; fi

restore_artifact() {
    # Archives written by this script contain only regular files/directories.
    local path="$1" digest="$2" kind="$3" dest="$4"
    check_archive "$path" "$digest"
    python3 - "$path" "$kind" "$dest" "$SOURCE_SHA256" <<'RESTORE_PY'
import hashlib,json,pathlib,sys,tarfile
path,kind,dest,source=sys.argv[1:]
dest=pathlib.Path(dest);dest.mkdir()
with tarfile.open(path) as t:
    members=t.getmembers()
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not(m.isfile() or m.isdir()):
            raise ValueError('unsafe artifact member: '+m.name)
    t.extractall(dest)
root=dest/'validation-output'
report=json.loads((root/'build.json').read_text())
if report.get('schema')!=1 or report.get('build_pass') is not True or report['kind']!=kind or report['source_archive_sha256']!=source:
    raise ValueError('artifact source/kind mismatch')
for name,sha in report['files'].items():
    p=pathlib.PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts:raise ValueError('invalid manifest path')
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=sha:
        raise ValueError('artifact checksum mismatch: '+name)
print('BUILD_ARTIFACT_IDENTITY_PASS',kind)
RESTORE_PY
}
# Resolve only successful exports for this exact source snapshot.
if [ "$MODE" != build-core ]; then
    python3 - "$MODE" "$PERSIST" "$SOURCE_SHA256" "$WORK/build-selection.json" <<'SELECT_BUILD_PY'
import json,os,pathlib,sys
mode,persist,source,target=sys.argv[1:];persist=pathlib.Path(persist)
def latest(kind):
    candidates=sorted(persist.glob('reproduction-'+kind+'-'+source[:12]+'-*.json'),reverse=True)
    if not candidates:raise RuntimeError('先完成 build-'+kind+'，或显式指定匹配产物')
    r=json.loads(candidates[0].read_text())
    if r['kind']!=kind or r['source_archive_sha256']!=source:raise ValueError('构建登记不匹配')
    return r
sdk=os.getenv('SDK_ARTIFACT');sdk_sha=os.getenv('SDK_ARTIFACT_SHA256')
lm=os.getenv('LM_ARTIFACT');lm_sha=os.getenv('LM_ARTIFACT_SHA256')
if mode=='native' and not lm:
    r=latest('lm');lm=r['artifact'];lm_sha=r['sha256']
    if not sdk:sdk=r['sdk_artifact'];sdk_sha=r['sdk_artifact_sha256']
if not sdk:
    r=latest('core');sdk=r['artifact'];sdk_sha=r['sha256']
if not sdk_sha or (mode=='native' and not lm_sha):raise ValueError('产物需要对应 SHA256')
pathlib.Path(target).write_text(json.dumps(dict(sdk=sdk,sdk_sha=sdk_sha,lm=lm,lm_sha=lm_sha)))
SELECT_BUILD_PY
    SDK_ARTIFACT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sdk"])' "$WORK/build-selection.json")"
    SDK_ARTIFACT_SHA256="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sdk_sha"])' "$WORK/build-selection.json")"
    cp "$WORK/build-selection.json" "$WORK/validation-output/build-selection.json"
    export SDK_ARTIFACT SDK_ARTIFACT_SHA256
    restore_artifact "$SDK_ARTIFACT" "$SDK_ARTIFACT_SHA256" core "$WORK/sdk-import"
    mkdir -p "$INFINI_ROOT"
    cp -R "$WORK/sdk-import/validation-output/sdk/." "$INFINI_ROOT/"
    CORE_STAGED_BINDING="$WORK/sdk-import/validation-output/core-binding.so"
fi
restore_lm() {
    LM_ARTIFACT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lm"])' "$WORK/build-selection.json")"
    LM_ARTIFACT_SHA256="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lm_sha"])' "$WORK/build-selection.json")"
    restore_artifact "$LM_ARTIFACT" "$LM_ARTIFACT_SHA256" lm "$WORK/lm-import"
    python3 - "$WORK/lm-import/validation-output/build.json" "$INFINI_ROOT" <<'LM_SDK_PY'
import hashlib,json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text());sdk=pathlib.Path(sys.argv[2])
for name,sha in r['sdk_libraries'].items():
    if hashlib.sha256((sdk/'lib'/name).read_bytes()).hexdigest()!=sha:
        raise ValueError('LM binding was built against another SDK: '+name)
LM_SDK_PY
    mkdir -p "$WORK/src/InfiniLM/python/infinilm/lib"
    cp "$WORK/lm-import/validation-output/lm-binding.so" "$WORK/src/InfiniLM/python/infinilm/lib/_infinilm.cpython-311-x86_64-linux-gnu.so"
}
set +u
if source /opt/dtk/env.sh; then
    :
else
    rc=$?
    echo "DTK 环境加载失败 rc=$rc"
    exit 2
fi
set -u
export PATH="$WORK/bin:/opt/dtk/cuda/cuda/bin:/opt/dtk/bin:${PATH:-/usr/bin:/bin}"
export LD_LIBRARY_PATH="$INFINI_ROOT/lib:/opt/dtk/cuda/cuda/lib64:/opt/dtk/lib:/opt/hyhal/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="$WORK/pylibs:$WORK/src/InfiniCore/python:$WORK/src/InfiniLM/python"
export PYBIND11_INCLUDE="$WORK/pylibs/pybind11/include"
export PYTHON_INCLUDE=/usr/local/include/python3.11
export XMAKE_ROOT=y XMAKE_GLOBALDIR="$WORK/.xmake" NINETOOTHED_ARCH=gfx936
export ROCM_PATH=/opt/dtk HIP_PATH=/opt/dtk/hip
export MIOPEN_DISABLE_CACHE=1
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
unset MIOPEN_FIND_MODE HIP_LAUNCH_BLOCKING AMD_SERIALIZE_KERNEL
unset H3_FP H3_TRACE H3_STAGE H3_CONDITION_TRACE H3_CONDITION_TRACE_RUN H3_CONDITION_TRACE_DIR
unset H3_CONDITION_CAPTURE H3_CONDITION_CAPTURE_RUN H3_CONDITION_CAPTURE_DIR H3_CONDITION_CAPTURE_DETAIL
# Historical workspace/collective environment settings are not a correctness fix.
untar "$UPLOADS/$SOURCE_NAME" "$WORK"
find "$WORK/src" -name '._*' -delete
for part in python_deps_base python_deps_models python_deps_metrics; do untar "$UPLOADS/$part.tar.gz" "$WORK/$part"; done
python3 - "$WORK" <<'WHEELS'
from pathlib import Path
import sys,zipfile
work=Path(sys.argv[1]);target=work/'pylibs';target.mkdir()
for part in ('python_deps_base','python_deps_models','python_deps_metrics'):
    for p in sorted((work/part).glob('*.whl')):
        if p.name.startswith(('._','torchvision')):continue
        with zipfile.ZipFile(p) as z:z.extractall(target)
vision=work/'src/validation/deps/torchvision-0.24.0-cp311-cp311-linux_x86_64.whl'
import hashlib
if hashlib.sha256(vision.read_bytes()).hexdigest()!='71b388edcd7326de3fbdd3a2cc0176943443e18b0c6643050fe436b199f47855':
    raise ValueError('validated torchvision wheel identity differs')
with zipfile.ZipFile(vision) as z:
    if z.testzip() is not None:raise ValueError('torchvision wheel corrupt')
    z.extractall(target)
print('WHEELS_READY validated_torchvision_reused')
WHEELS
# Kept for dependency/legacy compatibility; native Core MHA remains reference math.
cat "$UPLOADS"/flash_attention/flash_attention.whl.part0{0,1,2,3,4,5,6} > "$WORK/flash_attn.whl"
python3 - "$WORK" "$UPLOADS/flash_attention/triton_dtk2604.whl" <<'FLASH_PY'
from pathlib import Path
import sys,zipfile
work=Path(sys.argv[1])
for p,size in ((work/'flash_attn.whl',658898543),(Path(sys.argv[2]),105484167)):
    if p.stat().st_size!=size:raise ValueError('dependency size mismatch: '+str(p))
    with zipfile.ZipFile(p) as z:z.extractall(work/'pylibs')
matches=list((work/'pylibs').glob('flash_attn_2_cuda*.so'))
if len(matches)!=1:raise ValueError('expected one flash attention extension')
FLASH_PY
FA_SO_PATH="$(find "$WORK/pylibs" -maxdepth 1 -name 'flash_attn_2_cuda*.so')"
export FA_SO_PATH

if [ "$MODE" = build-core ] || [ "$MODE" = build-lm ]; then
    untar "$UPLOADS/build_tool_xmake.tar.gz" "$WORK/bin"
    chmod +x "$WORK/bin/xmake"
    "$WORK/bin/xmake" g --network=private
    if [ "$MODE" = build-core ]; then
        cd "$WORK/src/InfiniCore"
        PYTHONPATH="src:$WORK/src/ntops/src:$WORK/src/ninetoothed/src:$WORK/pylibs" \
          NINETOOTHED_OPS=relu,swiglu,kv_caching python3 scripts/build_ntops.py
        "$WORK/bin/xmake" f -y -cv --hygon-dcu=y --hygon-arch=gfx936 \
            --cuda=/opt/dtk/cuda/cuda --ccl=y --aten=y --ninetoothed=y --omp=n
        "$WORK/bin/xmake" --version > "$WORK/validation-output/xmake-version.txt"
        say "BUILD_PHASE_BEGIN core-graph target=_infinicore"
        # _infinicore -> infinicore_cpp_api -> infiniop/infinirt/infiniccl.
        # Build the complete dependency graph once, before installing headers.
        "$WORK/bin/xmake" build -j "$(nproc)" _infinicore
        say "BUILD_PHASE_DONE core-graph"
        say "BUILD_PHASE_BEGIN core-install"
        # Only install graph members; default test/utility targets were not built.
        for target in infinirt infiniop infiniccl infinicore_cpp_api _infinicore; do
            "$WORK/bin/xmake" install -y "$target"
        done
        say "BUILD_PHASE_DONE core-install"
    else
        cd "$WORK/src/InfiniLM"
        "$WORK/bin/xmake" f -y -cv
        "$WORK/bin/xmake" build -j "$(nproc)" _infinilm
        "$WORK/bin/xmake" install -y _infinilm
    fi
    # Export plain files, dereferencing local SDK symlinks before packaging.
    python3 - "$MODE" "$SOURCE_SHA256" <<'BUILD_MANIFEST_PY'
import hashlib,json,os,pathlib,shutil,sys
work=pathlib.Path(os.environ['WORK']);out=work/'validation-output'
sdk=pathlib.Path(os.environ['INFINI_ROOT']);kind='core' if sys.argv[1]=='build-core' else 'lm'
libraries={n:hashlib.sha256((sdk/'lib'/n).read_bytes()).hexdigest() for n in
           ('libinfinicore_cpp_api.so','libinfiniop.so','libinfinirt.so','libinfiniccl.so')}
if kind=='core':
    for sub in ('include','lib'):shutil.copytree(sdk/sub,out/'sdk'/sub)
    matches=list((work/'src/InfiniCore/python/infinicore/lib').glob('_infinicore*.so'))
else:matches=list((work/'src/InfiniLM/python/infinilm/lib').glob('_infinilm*.so'))
if len(matches)!=1:raise ValueError('expected exactly one built Python binding')
shutil.copyfile(matches[0],out/(kind+'-binding.so'))
files={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest()
       for p in out.rglob('*') if p.is_file()}
report=dict(schema=1,kind=kind,source_archive_sha256=sys.argv[2],sdk_libraries=libraries,
            files=files,build_pass=True,numerical_validation_pass=False)
(out/'build.json').write_text(json.dumps(report,indent=2)+'\n')
print('BUILD_ONLY_PASS',kind,'numerical_validation_pass=false')
BUILD_MANIFEST_PY
    say "BUILD_ONLY_DONE：不自动推理；数值与稳定性仍需验证"
    exit 0
fi

mkdir -p "$WORK/src/InfiniCore/python/infinicore/lib"
cp "$CORE_STAGED_BINDING" "$WORK/src/InfiniCore/python/infinicore/lib/_infinicore.cpython-311-x86_64-linux-gnu.so"
restore_lm
export FL2VA_TASK="$MODE" FL2VA_SOURCE_SHA256="$SOURCE_SHA256"
python3 "$WORK/src/validation/native_runtime.py"
DEFAULT_STEPS=50; DEFAULT_HEIGHT=928; DEFAULT_WIDTH=768

STEPS="${STEPS:-$DEFAULT_STEPS}"
HEIGHT="${HEIGHT:-$DEFAULT_HEIGHT}"; WIDTH="${WIDTH:-$DEFAULT_WIDTH}"
FIRST_FRAME="${FIRST_FRAME:-$UPLOADS/sample_first_frame.jpg}"
[ -r "$FIRST_FRAME" ] || { say "首帧不可读：$FIRST_FRAME"; exit 2; }
ARGS=(--gpus="$GPUS" --height="$HEIGHT" --width="$WIDTH" --steps="$STEPS" --seed="${SEED:-42}")

cd "$WORK/src/InfiniLM"
python3 - "$MODE" "$FIRST_FRAME" "$HEIGHT" "$WIDTH" "$STEPS" <<'CONFIG_PY'
import hashlib,json,os,pathlib,sys
path=pathlib.Path(sys.argv[2])
report=dict(task=sys.argv[1],first_frame_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            height=int(sys.argv[3]),width=int(sys.argv[4]),steps=int(sys.argv[5]),
            frames=int(os.getenv('NUM_FRAMES','124')),seed=int(os.getenv('SEED','42')),
            fps=24,audio_output=True,prompt=os.getenv('PROMPT','A dog falls asleep'),source_archive_sha256=os.environ['FL2VA_SOURCE_SHA256'])
(pathlib.Path(os.environ['WORK'])/'validation-output/config.json').write_text(json.dumps(report,indent=2)+'\n')
print('GENERATION_CONFIG',json.dumps(report))
CONFIG_PY
python3 "$WORK/src/validation/prepare_native_evaluation.py" \
    "$WORK/validation-output/config.json" "$WORK/validation-output/runtime_identity.json" \
    "$WORK/src/validation/native_reference.json" "$PERSIST" \
    "$WORK/validation-output/evaluation_config_resolved.json" "${EVALUATION_CONFIG:-}"
say "单次 FL2VA：${HEIGHT}x${WIDTH} ${STEPS}步；生成后自动评测"
cat > "$WORK/run_and_measure.py" <<'MEASURE_PY'
"""Run the entry as an ordinary Python child. Never import torch or touch CUDA.

CLI: process_monitor.py OUTPUT_DIRECTORY ENTRY [ENTRY_ARGS...]
GPU allocator metrics are explicitly unavailable; model-provided timing remains
in the original stdout log. This monitor waits for actual child completion.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import traceback


def main():
    out=Path(sys.argv[1]);entry=sys.argv[2]
    out.mkdir(parents=True,exist_ok=True)
    command=[sys.executable,'-u',entry,*sys.argv[3:]]
    (out/'generator-command.json').write_text(json.dumps(command,indent=2)+'\n')
    process=None;stop_signal=None;error=None;child_rc=None;rc=2

    def signal_child(signum):
        if process is not None:
            try:os.killpg(process.pid,signum)
            except ProcessLookupError:pass

    def interrupted(signum,_frame):
        nonlocal stop_signal
        if stop_signal is None:
            stop_signal=signum
            signal_child(signum)
            signal.alarm(5)
        else:
            signal_child(signal.SIGKILL)

    def stop_deadline(_signum,_frame):
        signal_child(signal.SIGKILL)

    signal.signal(signal.SIGTERM,interrupted)
    signal.signal(signal.SIGINT,interrupted)
    signal.signal(signal.SIGALRM,stop_deadline)
    start=time.monotonic()
    try:
        process=subprocess.Popen(command,start_new_session=True)
        if stop_signal is not None:
            signal_child(stop_signal)
        child_rc=process.wait()
        rc=128+stop_signal if stop_signal is not None else (child_rc if child_rc>=0 else 128-child_rc)
    except BaseException as exc:
        error=type(exc).__name__+': '+str(exc)
        traceback.print_exc()
        signal_child(signal.SIGKILL)
        if process is not None:
            child_rc=process.wait()
        rc=128+stop_signal if stop_signal is not None else 2
    finally:
        signal.alarm(0)
        elapsed=time.monotonic()-start
        rss=None;rss_error=None
        try:
            import resource
            rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
            if sys.platform=='darwin':rss/=1024
        except Exception as exc:
            rss_error=type(exc).__name__+': '+str(exc)
        report=dict(status='INTERRUPTED' if stop_signal is not None else 'PASS' if rc==0 else 'FAIL',
            error=error,child_returncode=child_rc,monitor_exit_code=rc,
            generation_process_wall_seconds=elapsed,host_process_peak_rss_kib=rss,
            host_rss_scope='RUSAGE_CHILDREN.ru_maxrss: maximum among waited child processes, not aggregate tree memory',
            host_rss_error=rss_error,gpu=None,gpu_metrics_status='PENDING',
            resource_scope='External wall time and partial host RSS only. GPU memory not measured; no torch/CUDA calls in monitor.')
        try:
            (out/'process_metrics.json').write_text(json.dumps(report,indent=2)+'\n')
        except Exception:
            traceback.print_exc()
            if rc==0:rc=5
        print('GENERATION_PROCESS_EXIT',rc,'child_returncode='+str(child_rc),flush=True)
    return rc


if __name__=='__main__':
    raise SystemExit(main())
MEASURE_PY
if python3 -X faulthandler -u "$WORK/run_and_measure.py" "$WORK/validation-output" examples/minimax_h3.py fl2va --model-path="$SHARED" \
    --text="${PROMPT:-A dog falls asleep}" --first-frame="$FIRST_FRAME" \
    --num-frames="${NUM_FRAMES:-124}" --output="$WORK/validation-output/result.mp4" "${ARGS[@]}" \
    > "$WORK/validation-output/generation.log" 2>&1; then
    GENERATION_RC=0
else
    GENERATION_RC=$?
fi
cat "$WORK/validation-output/generation.log"
export FIRST_FRAME
python3 - "$WORK/validation-output" "$GENERATION_RC" "$WORK/validation-output/evaluation_config_resolved.json" <<'EVALUATE_PY'
import hashlib,importlib.util,json,math,os,pathlib,re,sys
out=pathlib.Path(sys.argv[1]);generation_rc=int(sys.argv[2]);settings_path=pathlib.Path(sys.argv[3])
settings={};settings_error=None
try:
    if settings_path.exists():settings=json.loads(settings_path.read_text())
    elif os.getenv('EVALUATION_CONFIG'):raise ValueError('显式指定的评测配置不存在')
except Exception as exc:settings_error=str(exc)
config=json.loads((out/'config.json').read_text());process=json.loads((out/'process_metrics.json').read_text()) if (out/'process_metrics.json').exists() else {}
report=dict(schema=1,official_result='NOT_ISSUED',configuration=config,generation_exit=generation_rc,
            specifications={'status':'PENDING'},similarity={'status':'PENDING','reason':'缺少标准视频'},
            performance={'status':'PARTIAL','process':process},stability={'status':'PENDING','reason':'本次仅运行一次，未验证重复稳定性'},
            semantic_and_first_frame_official_review={'status':'PENDING','reason':'需要出题方评测标准'},
            engineering={'weight_percent':20,'status':'REVIEW_REQUIRED','reason':'九齿贡献、源码规范、复现及答辩由评审判断'},
            final_weights_percent={'specifications':20,'similarity':30,'performance_resources':30,'engineering':20},
            score=None,settings_error=settings_error,preflight=settings.get('preflight'),
            submission_readiness={'status':'NOT_CLEARED','reasons':[
                'VAE模型计算仍使用第三方路径，未取得适用许可或完成九齿实现',
                '编译九齿算子不能证明海光实际分派经过九齿，待调用证据']},
            reference_precision_difference='原版参考强制VAE BF16；候选保留Diffusers混合精度；本次比较包含此差异')
if settings_error:report['similarity']={'status':'ERROR','reason':settings_error}
def spec(path):
    import av
    with av.open(str(path)) as c:
        if len(c.streams.video)!=1:raise ValueError('必须恰有一个视频流')
        v=c.streams.video[0];codec=v.codec_context.name;rate=float(v.average_rate)
        shape=(v.height,v.width);frames=sum(1 for _ in c.decode(video=0))
    with av.open(str(path)) as c:
        if len(c.streams.audio)!=1:raise ValueError('必须恰有一个音频流')
        a=c.streams.audio[0];audio_codec=a.codec_context.name;hz=a.codec_context.sample_rate
        channels=a.codec_context.channels;samples=sum(f.samples for f in c.decode(audio=0))
    actual=dict(height=shape[0],width=shape[1],frames=frames,fps=rate,video_codec=codec,
                audio_codec=audio_codec,audio_channels=channels,audio_sample_rate=hz,audio_samples=samples)
    expected=dict(height=config['height'],width=config['width'],frames=config['frames'],fps=float(config['fps']),
                  video_codec='h264',audio_codec='aac',audio_channels=2,audio_sample_rate=32000)
    return dict(status='PASS' if samples>0 and all(actual[k]==v for k,v in expected.items()) else 'FAIL',actual=actual,expected=expected)
if generation_rc:
    report['specifications']={'status':'FAIL','reason':'生成进程失败'}
else:
    try:report['specifications']=spec(out/'result.mp4')
    except Exception as exc:report['specifications']={'status':'FAIL','reason':str(exc)}
(out/'specifications.json').write_text(json.dumps(report['specifications'],ensure_ascii=False,indent=2)+'\n')
keys=('first_frame_sha256','prompt','height','width','frames','steps','seed','fps','audio_output')
def same_generation(other):return all(k in other and other[k]==config[k] for k in keys)
reference=settings.get('reference_video')
if reference and report['specifications']['status']=='PASS' and not settings_error:
    try:
        reference=pathlib.Path(reference)
        if not reference.is_absolute():reference=settings_path.parent/reference
        if not reference.is_file():raise ValueError('标准视频不可读')
        reference_sha256=hashlib.sha256(reference.read_bytes()).hexdigest()
        expected_sha256=settings.get('reference_video_sha256')
        if expected_sha256 and reference_sha256!=expected_sha256:raise ValueError('参考视频SHA256不匹配')
        script=pathlib.Path(os.environ['WORK'])/'src/InfiniLM/examples/minimax_h3_compare.py'
        module_spec=importlib.util.spec_from_file_location('fl2va_existing_comparator',script)
        comparator=importlib.util.module_from_spec(module_spec);sys.modules[module_spec.name]=comparator;module_spec.loader.exec_module(comparator)
        comparison=comparator.compare_video_streams(reference,out/'result.mp4')
        threshold=settings.get('ssim_min_percent');matched=same_generation(settings.get('reference_config',{}))
        value=comparison['ssim_match_percent']
        status='PENDING';reason='缺少相同生成配置证明或相似度阈值'
        if threshold is not None:
            threshold=float(threshold)
            if not math.isfinite(threshold) or not 0<=threshold<=100:raise ValueError('SSIM阈值必须是0到100之间的有限数值')
        if not comparison['metadata_size_match'] or not comparison['decoded_length_match']:status='FAIL';reason='参考规格不一致'
        elif matched and threshold is not None and value is not None:
            status='PASS' if value>=threshold else 'FAIL';reason='按用户提供的配置与阈值检查，非官方判分'
        report['similarity']=dict(status=status,reason=reason,reference=str(reference),reference_sha256=reference_sha256,
                                  reference_hash_verified=bool(expected_sha256),reference_provenance=settings.get('reference_provenance'),reference_config_matches=matched,
                                  threshold_percent=threshold,metrics=comparison)
    except Exception as exc:report['similarity']={'status':'ERROR','reason':str(exc)}
timing={}
for key,value in re.findall(r'^\s+([a-z0-9_.]+)\s+([0-9]+(?:\.[0-9]+)?)\s+s(?:\s|$)',(out/'generation.log').read_text(errors='replace'),re.M):timing[key]=float(value)
report['performance']['example_timings_seconds']=timing
report['performance']['timing_scope']='example.total.end_to_end includes model setup, generation and encoding; excludes job dependency setup and evaluation'
report['performance']['baseline_comparison']={'status':'PENDING','reason':'缺少统一配置、资源和计时范围的Baseline'}
report['performance']['reference_single_run_observation']=settings.get('reference_context',{}).get('performance')
report['performance']['reference_comparability']='单次观测；非统一稳态Baseline，VAE精度路径有差异，不自动计算加速比'
baseline=settings.get('baseline',{})
if baseline and not settings_error:
    try:
        seconds=float(baseline['end_to_end_seconds']);actual=timing.get('total.end_to_end')
        if not math.isfinite(seconds) or seconds<=0:raise ValueError('Baseline耗时必须为有限正数')
        valid=same_generation(baseline.get('generation_config',{})) and baseline.get('gpu_count')==8 and baseline.get('timing_scope')=='example.total.end_to_end'
        if valid and actual and actual>0:
            report['performance']['baseline_comparison']=dict(status='MEASURED',baseline_seconds=seconds,candidate_seconds=actual,speedup=seconds/actual,score=None)
    except Exception as exc:report['performance']['baseline_comparison']={'status':'ERROR','reason':str(exc)}
statuses=[report['specifications']['status'],report['similarity']['status']]
gate='FAIL' if any(x in ('FAIL','ERROR') for x in statuses) else 'PASS' if all(x=='PASS' for x in statuses) else 'PENDING'
report['local_basic_gate']=gate
report['preliminary']=dict(local_basic_gate=gate,official_result='NOT_ISSUED',
    reproducibility='构建来源记录在build-selection.json及runtime_identity.json，干净重建仍需平台验收')
(out/'evaluation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
lines=['EVAL_SPECIFICATIONS '+json.dumps(report['specifications'],ensure_ascii=False),
       'EVAL_SIMILARITY '+json.dumps(report['similarity'],ensure_ascii=False),f'EVAL_LOCAL_BASIC_GATE {gate}',
       'EVAL_PERFORMANCE '+json.dumps(report['performance'],ensure_ascii=False),
       'EVAL_STABILITY PENDING：单次生成不能证明重复稳定性',
       'EVAL_ENGINEERING REVIEW_REQUIRED weight=20%',
       'EVAL_FINAL_SCORE PENDING：不自行计算官方分数',
       'EVAL_SUBMISSION_READINESS NOT_CLEARED',
       'EVAL_OFFICIAL_RESULT NOT_ISSUED']
(out/'evaluation.log').write_text('\n'.join(lines)+'\n');print('\n'.join(lines))
raise SystemExit(4 if gate=='FAIL' else 0)
EVALUATE_PY
say "FL2VA_SINGLE_RUN_DONE：评测信息已保存，待评测不等于通过"
