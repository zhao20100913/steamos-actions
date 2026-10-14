#!/usr/bin/env bash
# 30-prepare-stock-inputs.sh —— 校验并打包「原厂固件 analysis 产物」为 stock-inputs.tar.gz
#
# 背景：liuqin 的小米 ABL 会对 boot.img 携带的 DTB 应用原厂 DTBO overlay，并要求 DTB
# 带 __symbols__ sink（见 xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh）。因此
# 构建 boot.img 必须要有原厂产物：
#   analysis/dtbo/entry.N         （44 个 DTBO 条目）
#   analysis/vendor_boot/dtbs/dtb-XX.dtb （14 个基础 DTB）
#
# 这些产物从<b>本机</b>原厂固件提取（不能跨机使用；涉及出厂数据请遵循原项目指引）。
# 提取方式：按 xiaomipad-6pro-mainline 的文档（docs/BUILD.md / CI.md）准备 ROM 后，
# 由该项目的准备管线生成 analysis/ 目录。本脚本只负责<b>校验数量并打包</b>。
#
# 用法: bash scripts/host/30-prepare-stock-inputs.sh <analysis 目录> [输出 tar]
# 产出：stock-inputs.tar.gz（上传到任意可直连 URL，填给 workflow 的 stock_inputs_url）
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

SRC="${1:?用法: 30-prepare-stock-inputs.sh <analysis 目录> [输出 tar]}"
OUT_TAR="${2:-$PWD/stock-inputs.tar.gz}"

DTBO="$SRC/dtbo"
BASE="$SRC/vendor_boot/dtbs"
[[ -d "$DTBO" ]] || die "缺少 $DTBO"
[[ -d "$BASE" ]] || die "缺少 $BASE"

n_overlay=$(find "$DTBO" -maxdepth 1 -type f -regex '.*/entry\.[0-9]+' | wc -l)
n_base=$(find "$BASE" -maxdepth 1 -type f -regex '.*/dtb-[0-9][0-9]\.dtb' | wc -l)
log "dtbo 条目: $n_overlay / 期望 44；基础 dtb: $n_base / 期望 14"
[[ "$n_overlay" -eq 44 ]] || die "dtbo 条目数不对（上游 build-bootimg.sh 会强校验）"
[[ "$n_base" -eq 14 ]] || die "基础 dtb 数不对"

tar -czf "$OUT_TAR" -C "$SRC" dtbo vendor_boot
log "已打包: $OUT_TAR"
sha256sum "$OUT_TAR"
