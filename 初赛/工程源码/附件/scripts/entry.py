#!/usr/bin/env python3
"""One public entry for rebuilding, generating and checking the submission."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tarfile
import time

ROOT=Path(__file__).resolve().parents[2]
INNER=ROOT/'附件'
DEFAULT_MODEL=Path('/public/home/aclsylqidf/shared/MiniMax-H3')

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024**2),b''):h.update(block)
    return h.hexdigest()

def find_model(explicit):
    path=Path(explicit or os.getenv('SHARED') or DEFAULT_MODEL).expanduser().resolve()
    if not any((path/suffix).is_file() for suffix in ('diffusers/modular_model_index.json','modular_model_index.json')):
        raise ValueError('未找到比赛模型。请指定：bash run.sh native --model /模型目录')
    return path

def find_frame(explicit,model,expected):
    if explicit:
        path=Path(explicit).expanduser().resolve()
        if not path.is_file() or digest(path)!=expected:raise ValueError('指定首帧与统一样例不符')
        return path
    personal=Path(os.getenv('IFAB_AFS_HOME') or Path.home())
    bases=[personal,model,model.parent,ROOT.parent]
    candidates=[personal/'sample_first_frame.jpg']
    if os.getenv('FIRST_FRAME'):candidates.insert(0,Path(os.environ['FIRST_FRAME']))
    for base in bases:
        if base.is_dir():
            for pattern in ('*.jpg','*.jpeg','*.png','*/*.jpg','*/*.jpeg','*/*.png'):
                candidates.extend(base.glob(pattern))
    seen=set()
    for path in candidates:
        path=path.expanduser().resolve()
        if path in seen:continue
        seen.add(path)
        if path.is_file() and path.stat().st_size<=10*1024**2 and digest(path)==expected:return path
    raise ValueError('未找到统一首帧。请指定：bash run.sh native --first-frame /样例图片路径')

def commands(model,frame,state,action):
    prep=[sys.executable,str(INNER/'scripts/prepare_submission.py'),'--store',str(state)]
    prep+=['--first-frame',str(frame)] if action=='native' else ['--build-only']
    labels={'build-core':'构建Core','build-lm':'构建LM','native':'生成视频并评测'}
    steps=[('准备离线材料',prep,300),
           (labels[action],['bash',str(INNER/'scripts/run_fl2va.sh'),'--inside',action],1560)]
    env=os.environ.copy()
    for key in list(env):
        if key.startswith(('H3_','REPRO_')):env.pop(key,None)
    for key in ('SDK_ARTIFACT','SDK_ARTIFACT_SHA256','LM_ARTIFACT','LM_ARTIFACT_SHA256','EVALUATION_CONFIG',
                'FIRST_FRAME','PROMPT','SEED','STEPS','NUM_FRAMES','HEIGHT','WIDTH',
                'H3_CONDITION_TRACE','H3_CONDITION_TRACE_RUN','H3_CONDITION_TRACE_DIR',
                'AMD_SERIALIZE_KERNEL','AMD_SERIALIZE_COPY','HIP_LAUNCH_BLOCKING','CUDA_LAUNCH_BLOCKING'):
        env.pop(key,None)
    env.update(IFAB_AFS_HOME=str(state),SHARED=str(model),FIRST_FRAME=str(state/'sample_first_frame.jpg'))
    return steps,env

def run_stage(command,env,log,label,limit=None):
    process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    started=time.monotonic();stopped=None
    old={}
    def stop(signum,_frame):
        nonlocal stopped
        stopped=signum
        try:os.killpg(process.pid,signal.SIGKILL if signum==signal.SIGALRM else signum)
        except ProcessLookupError:pass
        if signum!=signal.SIGALRM:signal.alarm(45)
    for signum in (signal.SIGTERM,signal.SIGINT,signal.SIGALRM):old[signum]=signal.signal(signum,stop)
    try:
        while True:
            try:rc=process.wait(timeout=min(30,max(0.1,limit-(time.monotonic()-started))) if limit is not None and stopped is None else 30)
            except subprocess.TimeoutExpired:
                elapsed=time.monotonic()-started
                print(f'  {label}进行中，已用{int(elapsed)}秒',flush=True)
                if stopped is None and limit is not None and elapsed>=limit:stop(signal.SIGTERM,None)
                continue
            if stopped is not None:return 128+(signal.SIGTERM if stopped==signal.SIGALRM else stopped)
            return rc if rc>=0 else 128-rc
    finally:
        signal.alarm(0)
        for signum,handler in old.items():signal.signal(signum,handler)
        if process.poll() is None:
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            process.wait()

def collect(state,destination,source_sha):
    status={key:value for key,value in (token.split('=',1) for token in (state/'songshan/fl2va-last-status.txt').read_text().split())}
    if any(status.get(key)!='0' for key in ('exit','compute_exit','export_exit')):raise ValueError('运行未完整成功，请查看日志')
    stamp=status['log_prefix'].removeprefix('fl2va-')
    if len(stamp)!=14 or not stamp.isdigit():raise ValueError('结果记录的时间标识无效')
    archive=state/'songshan'/('fl2va-output-'+stamp+'.tar.gz')
    with tarfile.open(archive) as t:
        config=json.load(t.extractfile('validation-output/config.json'))
        evaluation=json.load(t.extractfile('validation-output/evaluation.json'))
        if config.get('task')!='native' or config.get('source_archive_sha256')!=source_sha:
            raise ValueError('输出与本次源码身份不符')
        if evaluation['generation_exit']!=0 or evaluation['specifications']['status']!='PASS':raise ValueError('生成或规格检查未通过')
        for item in t.getmembers():
            if item.isfile() and Path(item.name).parent.as_posix()=='validation-output':
                (destination/Path(item.name).name).write_bytes(t.extractfile(item).read())
    print('完成：'+str(destination/'result.mp4'),flush=True)
    value=evaluation.get('similarity',{}).get('metrics',{}).get('ssim_match_percent')
    print('规格：PASS；平均SSIM：'+(f'{value:.4f}%' if value is not None else '待评测')+'；官方通过阈值待确认。',flush=True)
    return archive

def main():
    deadline=time.monotonic()+1620
    parser=argparse.ArgumentParser(description='分阶段复现：build-core → build-lm → native；check只比较已有视频。')
    parser.add_argument('action',nargs='?',choices=('build-core','build-lm','native','check'))
    parser.add_argument('--model');parser.add_argument('--first-frame');parser.add_argument('--work-dir',type=Path)
    parser.add_argument('--plan',action='store_true',help='只显示所选阶段，不执行')
    args=parser.parse_args()
    if args.action is None:parser.print_help();return 0
    config=json.loads((INNER/'submission.json').read_text())
    current=ROOT/'结果/本次运行'
    if args.action=='check':
        candidate=current/'result.mp4'
        if not candidate.is_file():raise ValueError('尚无可比较视频；请先运行native，失败时查看结果/本次运行/运行.log')
        return subprocess.call([sys.executable,str(INNER/'scripts/evaluate_existing.py'),'--candidate',str(candidate)])
    model=find_model(args.model) if args.action=='native' else Path(args.model or os.getenv('SHARED') or DEFAULT_MODEL)
    frame=find_frame(args.first_frame,model,config['generation_config']['first_frame_sha256']) if args.action=='native' else None
    state=(args.work_dir or Path(os.getenv('IFAB_AFS_HOME') or Path.home())/'fl2va-r10-submission').expanduser().resolve()
    steps,env=commands(model,frame,state,args.action)
    if args.plan:
        print(json.dumps(dict(model=str(model),first_frame=str(frame),work_dir=str(state),
                              steps=[dict(stage=label,command=command) for label,command,_ in steps]),ensure_ascii=False,indent=2));return 0
    if sys.version_info[:2]!=(3,11) or platform.system()!='Linux' or platform.machine()!='x86_64':
        raise ValueError('请在比赛指定的Linux x86_64 / Python3.11环境运行；--help和--plan不使用算力')
    if args.action in ('build-lm','native'):
        required='core' if args.action=='build-lm' else 'lm'
        if not list((state/'songshan').glob('reproduction-'+required+'-'+config['source_archive_sha256'][:12]+'-*.json')):
            raise ValueError('缺少配套'+required+'构建；请先执行build-core，再执行build-lm')
    if args.action=='native':
        if current.exists():
            history=state/'history';history.mkdir(parents=True,exist_ok=True)
            shutil.move(str(current),str(history/('result-'+str(time.time_ns()))))
        current.mkdir(parents=True,exist_ok=True)
        log_path=current/'运行.log'
    else:
        logs=state/'logs';logs.mkdir(parents=True,exist_ok=True)
        log_path=logs/(args.action+'-'+str(time.time_ns())+'.log')
    with log_path.open('w') as log:
        for index,(label,command,limit) in enumerate(steps,1):
            print(f'[{index}/{len(steps)}] {label}',flush=True)
            log.write(json.dumps(dict(stage=label,command=command),ensure_ascii=False)+'\n');log.flush()
            remaining=deadline-time.monotonic()
            if remaining<=0:print('本阶段达到27分钟保护时限，已停止',file=sys.stderr);return 124
            rc=run_stage(command,env,log,label,min(limit,remaining))
            if rc:
                print(f'{label}失败，已停止。完整日志：{log_path}',file=sys.stderr,flush=True);return rc
    if args.action=='native':collect(state,current,config['source_archive_sha256'])
    else:print('本阶段完成。日志：'+str(log_path),flush=True)
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,KeyError,tarfile.TarError) as exc:
        print(str(exc),file=sys.stderr);raise SystemExit(2)
