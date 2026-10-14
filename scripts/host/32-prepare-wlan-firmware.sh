#!/usr/bin/env bash
# 32-prepare-wlan-firmware.sh —— 用你自己的原厂 QCA6490 目录重新生成 WCN6855 固件集
#
# ⚠️ 默认不需要本步骤：xiaomipad 项目的 device/firmware 已随 31-vendor-device-sources.sh
#    拷入 liuqin-firmware/src/firmware（含项目生成的 board-2.bin.zst，固定闭包）。
#    只有当你持有自己的原厂 qca6490 目录（amss20.bin / m3.bin / regdb.bin / bd_m81gf.elf，
#    每个文件都有固定 sha256）且想按自己的 ROM 重新生成时才跑它 —— 生成结果会
#    覆盖 liuqin-firmware/src/firmware/ath11k/WCN6855/ 下的对应文件。
#
# 用法: bash scripts/host/32-prepare-wlan-firmware.sh <xiaomipad 检出> [vendor qca6490 目录]
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

DEV="${1:?用法: 32-prepare-wlan-firmware.sh <xiaomipad 检出> [vendor dir]}"
VENDOR_DIR="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_PKG="$HERE/../../packages/liuqin-firmware"

if [[ -z "$VENDOR_DIR" || ! -d "$VENDOR_DIR" ]]; then
  log "未提供 vendor 目录 —— 保持项目固定闭包，跳过重新生成"
  exit 0
fi
# 用户给的 tar 可能带一层 qca6490 子目录：解析出真正含 amss20.bin 的目录
RESOLVED="$(find "$VENDOR_DIR" -maxdepth 3 -type f -name 'amss20.bin' -printf '%h\n' | head -n1)"
if [[ -n "$RESOLVED" ]]; then
  VENDOR_DIR="$RESOLVED"
  log "vendor 目录解析为: $VENDOR_DIR"
fi

# 固定 bdencoder 二进制（build-liuqin-wlan.py 会校验 ENCODER_SHA）
BDENCODER="$DEV/tools/local/ath11k-bdencoder"
if [[ ! -x "$BDENCODER" ]]; then
  log "检出里没有 tools/local/ath11k-bdencoder —— 用 qca-swiss-army-knife 构建"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 https://github.com/quic/qca-swiss-army-knife.git "$TMP/qsa"
  ( cd "$TMP/qsa" && make -C tools/scripts/ath11k 2>/dev/null || gcc -O2 -o ath11k-bdencoder tools/scripts/ath11k/ath11k-bdencoder.c ) || die "bdencoder 构建失败"
  BDENCODER="$TMP/qsa/tools/scripts/ath11k/ath11k-bdencoder"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 "$DEV/tools/build-liuqin-wlan.py" \
  --vendor "$VENDOR_DIR" \
  --base-board "$DEV/device/firmware/usr/lib/firmware/ath11k/WCN6855/hw2.0/board-2.bin.zst" \
  --bdencoder "$BDENCODER" \
  --out "$TMP/wlan" || die "build-liuqin-wlan.py 失败（vendor 文件与固定 sha256 不匹配？）"

rm -rf "$FW_PKG/src/firmware/ath11k/WCN6855"
cp -a "$TMP/wlan" "$FW_PKG/src/firmware/ath11k/WCN6855"
log "已用你的 vendor 目录重新生成 WCN6855 固件集 → $FW_PKG/src/firmware/ath11k/WCN6855"
