#!/usr/bin/env bash
# 07-build-liuqin-kernel.sh —— 构建小米平板 6 Pro（liuqin）SteamOS 内核
#
# 复刻 xiaomipad-6pro-mainline/tools/build-liuqin-kernel.py 的配置流程
# （defconfig -> merge_config.sh -m 叠加 kernel/source.json 的片段 -> olddefconfig），
# 并在最后额外叠加本仓库 device/configs/liuqin-steamos.config
# （无 initramfs 直挂根所需的内建选项）。绕开上游的 config_sha256 门是为了
# 允许追加片段；如需与上游完全一致，可直接用上游 build-liuqin-kernel.py。
#
# 用法:
#   07-build-liuqin-kernel.sh --work DIR [--jobs N] [--commit SHA]
# 环境变量：
#   KERNEL_REPO / KERNEL_BRANCH / DEVICE_REPO / CROSS_COMPILE
# 产出（$WORK/out/ 下）：
#   kernel/          内核构建树（Image / dtb / .config / modules/）
#   kernel-modules.tar.gz  模块树（解到 / 后即 /lib/modules/<release>/）
#   kernel.release   内核版本串
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

WORK="${WORK:-$PWD/work}"
JOBS="${JOBS:-$(nproc)}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/yzddmr6/linux-sm8450-liuqin.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-liuqin-6.17}"
KERNEL_COMMIT="${KERNEL_COMMIT:-}"
DEVICE_REPO="${DEVICE_REPO:-https://github.com/yzddmr6/xiaomipad-6pro-mainline.git}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
STEAMOS_CONFIG="${STEAMOS_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/device/configs/liuqin-steamos.config}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work)   WORK="$2"; shift 2 ;;
    --jobs)   JOBS="$2"; shift 2 ;;
    --commit) KERNEL_COMMIT="$2"; shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done

mkdir -p "$WORK/out"
cd "$WORK"

# 1) 检出
[[ -d linux-sm8450-liuqin ]] || git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" linux-sm8450-liuqin
[[ -d xiaomipad-6pro-mainline ]] || git clone --depth 1 "$DEVICE_REPO" xiaomipad-6pro-mainline
KSRC="$WORK/linux-sm8450-liuqin"
if [[ -n "$KERNEL_COMMIT" ]]; then
  ( cd "$KSRC" && git fetch --depth 1 origin "$KERNEL_COMMIT" && git checkout --detach "$KERNEL_COMMIT" ) \
    || die "无法固定到 commit $KERNEL_COMMIT（确认在分支 $KERNEL_BRANCH 上）"
fi
log "内核: $(git -C "$KSRC" rev-parse --short HEAD) @ $(git -C "$KSRC" describe --tags 2>/dev/null || echo n/a)"

# 2) 片段清单（顺序与上游 source.json 一致）+ 我们的 SteamOS 片段
FRAGMENTS=()
while IFS= read -r p; do
  f="$WORK/xiaomipad-6pro-mainline/$p"
  [[ -f "$f" ]] || die "上游片段缺失: $f"
  FRAGMENTS+=("$f")
done < <(python3 -c "import json;print('\n'.join(json.load(open('xiaomipad-6pro-mainline/kernel/source.json'))['config_fragments']))")
FRAGMENTS+=("$STEAMOS_CONFIG")
log "配置片段: ${#FRAGMENTS[@]} 个（上游 10 + liuqin-steamos）"

DTB="$(python3 -c "import json;print(json.load(open('xiaomipad-6pro-mainline/kernel/source.json'))['dtb'])")"
OUT="$WORK/out/kernel"
mkdir -p "$OUT"

# 3) 配置（与上游 build-liuqin-kernel.py 相同语义）
log "make defconfig"
make -C "$KSRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig
log "merge_config.sh -m（叠加片段）"
sh "$KSRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "${FRAGMENTS[@]}" \
  | grep -E '^(Value of|ALERT|error)' || true
log "make olddefconfig"
make -C "$KSRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig

# 自检：无 initramfs 直挂根的内建项必须生效
for opt in CONFIG_EXT4_FS=y CONFIG_SCSI_UFS_QCOM=y CONFIG_DEVTMPFS=y CONFIG_DEVTMPFS_MOUNT=y CONFIG_INPUT_UINPUT=y; do
  grep -qx "$opt" "$OUT/.config" || die ".config 缺少 $opt（liuqin-steamos.config 未生效？）"
done
log "无 initramfs 关键选项已确认"

# 4) 构建
log "make Image $DTB modules (-j$JOBS)"
make -C "$KSRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image "$DTB" modules
make -C "$KSRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS" modules_install INSTALL_MOD_PATH="$OUT/modules"

# 5) 打包模块树 + 记录版本
tar -C "$OUT/modules" -czf "$WORK/out/kernel-modules.tar.gz" .
cp "$OUT/include/config/kernel.release" "$WORK/out/kernel.release"
log "内核版本: $(cat "$WORK/out/kernel.release")"
ls -lh "$OUT/arch/arm64/boot/Image" "$WORK/out/kernel-modules.tar.gz"
