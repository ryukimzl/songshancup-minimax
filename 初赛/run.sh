#!/bin/bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
usage() {
    echo '统一入口：bash run.sh <build-core|build-lm|native|check>'
    echo '每次只执行所选阶段；自动校验源码并准备缺少的离线依赖。'
}
case "${1:-}" in
    ''|--help|-h) usage; exit 0 ;;
    build-core|build-lm|native|check) ;;
    *) usage >&2; exit 2 ;;
esac
if [ ! -f "$root/离线依赖/恢复.sh" ]; then
    echo '缺少 离线依赖/恢复.sh。InfiniFabric 项目复制上限为128MiB：整个目录放个人AFS时可直接运行；若用平台项目，只传 run.sh、工程源码/ 和 离线依赖/中的清单与脚本，12个二进制放个人AFS（$IFAB_AFS_HOME）。' >&2
    exit 3
fi
bash "$root/离线依赖/恢复.sh"
exec bash "$root/工程源码/run.sh" "$@"
