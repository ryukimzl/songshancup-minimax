#!/usr/bin/env bash
# 从 GitHub Release 下载本目录的 12 个离线依赖二进制，
# 按原始中文文件名落盘，并逐项校验 SHA256（与 传输清单.json 一致）。
#
# 用法：
#   bash 下载依赖.sh
#   https_proxy=http://127.0.0.1:7890 bash 下载依赖.sh    # 需要代理时
set -euo pipefail

REPO="ryukimzl/songshancup-minimax"
TAG="v0-r10-deps"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# 资源名（ASCII）| 原始文件名 | SHA256
MAP=(
  "build_tool_xmake.tar.gz|构建工具_Xmake.tar.gz|99df17ad8eaaba5d1e918c6915ba210b08b7931203fb6241e096e9010526f8f1"
  "python_deps_base.tar.gz|Python基础依赖.tar.gz|704341786e71c23ea6cb5812cc5b4af5f244e0a3bc110fcef1bdc7984250ba0b"
  "python_deps_models.tar.gz|Python模型依赖.tar.gz|488611f264b1d126f1c0ac6ef3ccfa3de978f56e23e2fb89b220ae235d8404dd"
  "python_deps_metrics.tar.gz|视频评测依赖.tar.gz|a694cdca68d1b9d1974ce7402df60edf599b09f44f78ee0d70c777e8e98dad88"
  "triton_dtk2604.whl|Triton依赖.whl|e397b16365da22508353ce44a45f5be82f8ee58e49853a3df06aa8f6f83d5581"
  "flash_attention.whl.part00|FlashAttention.part01|bfaa757e842676886c87e896e5829302a7ed9410dd3e10de12280614e89ec488"
  "flash_attention.whl.part01|FlashAttention.part02|33113a801a3a34511f6db536a848221f68eddcb5a4db30a05d8d122df11970e6"
  "flash_attention.whl.part02|FlashAttention.part03|1e287480287f0a187257e7fcfd50572e62dac5a9323cddce06e7cf8d5d0149a2"
  "flash_attention.whl.part03|FlashAttention.part04|5c25cd0275d8da39cbc72d7b0dde24a32ea305c51b3073edb7a9599e4c76781c"
  "flash_attention.whl.part04|FlashAttention.part05|dcd9aed482d4b9d5e8d911de05c6449a825110f7de3aa49b9f06acd735534a24"
  "flash_attention.whl.part05|FlashAttention.part06|98e8e63ea06dfd32424b935a1afc1119711d0f0f11e4c0ab7c8fe9295a3a3c50"
  "flash_attention.whl.part06|FlashAttention.part07|7c4e4b3d0eb30d6a90864e780755b5496a2a35ce22ec72d877642f0b020fd3d1"
)

if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "缺少 sha256sum / shasum，无法校验" >&2
  exit 1
fi

fail=0
for row in "${MAP[@]}"; do
  IFS='|' read -r asset original want <<<"$row"

  if [[ -f "$original" ]] && [[ "$(sha256_of "$original")" == "$want" ]]; then
    echo "[skip] $original 已存在且校验通过"
    continue
  fi

  tmp="${original}.part"
  echo "[get ] $original  <=  $BASE/$asset"
  if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -C - -o "$tmp" "$BASE/$asset"; then
    echo "[fail] 下载失败：$asset" >&2
    rm -f "$tmp"
    fail=1
    continue
  fi

  got="$(sha256_of "$tmp")"
  if [[ "$got" != "$want" ]]; then
    echo "[fail] 校验失败：$original" >&2
    echo "       期望 $want" >&2
    echo "       实际 $got" >&2
    rm -f "$tmp"
    fail=1
    continue
  fi

  mv -f "$tmp" "$original"
  echo "[ ok ] $original  SHA256 校验通过"
done

if [[ "$fail" -ne 0 ]]; then
  echo "存在失败项，修复后重跑本脚本（已完成的会跳过）。" >&2
  exit 1
fi

echo "全部 12 个依赖就绪，可执行：bash ../run.sh build-core"
