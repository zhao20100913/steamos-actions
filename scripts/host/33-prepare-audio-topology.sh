#!/usr/bin/env bash
# 33-prepare-audio-topology.sh —— 可选：从源码重建 liuqin 音频拓扑
#
# ⚠️ 默认不需要：项目固定闭包里的 tplg（firmware 树 qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin）
#    已随 31-vendor-device-sources.sh 拷入，UCM2 也一样。本步只在你希望从 audioreach-topology
#    重新构建（比如跟踪上游改动）时跑，结果覆盖 packages/liuqin-audio/src/ 下的 tplg。
#
# 用法: bash scripts/host/33-prepare-audio-topology.sh <xiaomipad 检出>
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

DEV="${1:?用法: 33-prepare-audio-topology.sh <xiaomipad 检出>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIO_PKG="$HERE/../../packages/liuqin-audio"
AUDIOREACH_COMMIT=2af1f1ebb8d4fd03b5f53891467ddde2e208a8a0

[[ -f "$DEV/tools/build-liuqin-audio-topology.sh" ]] || die "检出里没有 build-liuqin-audio-topology.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
log "克隆 audioreach-topology（固定 commit）..."
git clone --depth 1 https://github.com/linux-msm/audioreach-topology.git "$TMP/topology" || die "克隆失败"
( cd "$TMP/topology" && git fetch --depth 1 origin "$AUDIOREACH_COMMIT" && git checkout --detach "$AUDIOREACH_COMMIT" ) || true

mkdir -p "$AUDIO_PKG/src"
AUDIOREACH_TOPOLOGY_DIR="$TMP/topology" \
OUTPUT="$AUDIO_PKG/src/Xiaomi-Pad-6-Pro-tplg.bin" \
sh "$DEV/tools/build-liuqin-audio-topology.sh" || die "拓扑重建失败"
log "已重建 tplg: $AUDIO_PKG/src/Xiaomi-Pad-6-Pro-tplg.bin"
