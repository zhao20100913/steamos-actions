#!/usr/bin/env bash
# 04-verify-kernel-match.sh —— 校验 boot.img 的内核版本与 rootfs 里的模块目录一致
#
# 为什么必须有这道闸：内核只从 /usr/lib/modules/$(uname -r)/ 找模块，且模块 vermagic 必须与
# 内核完全一致。内核包与 boot.img 只要取自不同构建，就会「rootfs 有模块但内核一个都不加载」
# → 刷进去黑屏、且日志上看不出构建错误。这道校验把它变成构建失败。
#
# 用法: 04-verify-kernel-match.sh <boot.img> <rootfs.img>
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

BOOT="${1:?用法: 04-verify-kernel-match.sh <boot.img> <rootfs.img>}"
IMG="${2:?}"
[[ -s "$BOOT" ]] || die "boot.img 不存在: $BOOT"
[[ -s "$IMG"  ]] || die "rootfs.img 不存在: $IMG"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1) 从 Android boot image 抠出内核，读版本串
#    头布局：magic(8) / kernel_size(u32, 偏移 8)；内核段从 4096 页边界开始（mkbootimg 默认页大小）
[[ "$(head -c 8 "$BOOT")" == "ANDROID!" ]] || die "$BOOT 不是 Android boot image"
KSIZE="$(od -An -tu4 -j8 -N4 "$BOOT" | tr -d ' ')"
[[ "$KSIZE" -gt 0 ]] || die "读不到 kernel_size"
dd if="$BOOT" of="$TMP/k.bin" bs=4096 skip=1 count=$(( (KSIZE + 4095) / 4096 )) status=none
truncate -s "$KSIZE" "$TMP/k.bin"   # 去掉按页取整带来的尾部零填充

sig="$(head -c2 "$TMP/k.bin" | od -An -tx1 | tr -d ' \n')"
case "$sig" in
  1f8b) gunzip -c "$TMP/k.bin" > "$TMP/k.raw" 2>/dev/null || die "gunzip 内核失败" ;;
  *)    cp "$TMP/k.bin" "$TMP/k.raw" ;;
esac

# 内核里的字符串是 NUL 分隔的，先按 NUL 切成行再匹配
BOOT_VER="$(tr '\0' '\n' < "$TMP/k.raw" 2>/dev/null | grep -m1 -E '^Linux version [0-9]' | awk '{print $3}' || true)"
[[ -n "$BOOT_VER" ]] || die "没能在 boot.img 内核里读到 'Linux version …'"
log "boot.img 内核版本: $BOOT_VER"

# 2) 读 rootfs.img 里的模块目录名（debugfs 直接读，无需挂载/root）
command -v debugfs >/dev/null || die "需要 debugfs（e2fsprogs）"
MODS="$(debugfs -R 'ls -l /usr/lib/modules' "$IMG" 2>/dev/null \
  | awk 'NF>1{print $NF}' | grep -vE '^\.{1,2}$' | grep -E '[0-9]' || true)"
[[ -n "$MODS" ]] || die "rootfs.img 的 /usr/lib/modules 下没有任何版本目录（内核模块没装？）"
log "rootfs 里的模块目录："
printf '%s\n' "$MODS" | sed 's/^/    /'

# 3) 比对：必须存在与 boot.img 内核版本完全相同的模块目录
match=0
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  [[ "$m" == "$BOOT_VER" ]] && match=1
done <<< "$MODS"
if [[ "$match" -ne 1 ]]; then
  die "内核与模块版本不一致：boot.img 内核 '$BOOT_VER'，rootfs 里只有 '$(printf '%s' "$MODS" | tr '\n' ' ')'\n     → 刷进去必然黑屏。修法：内核构建与 boot.img 用同一次构建产物。"
fi
log "版本一致 ✓（$BOOT_VER）"

# depmod 产物也要在，否则目录名对了也加载不了
if debugfs -R "stat /usr/lib/modules/$BOOT_VER/modules.dep" "$IMG" >/dev/null 2>&1; then
  log "depmod 产物存在 ✓"
else
  warn "缺少 /usr/lib/modules/$BOOT_VER/modules.dep —— depmod 可能没跑，模块仍不会加载"
fi
log "校验通过：boot.img 与 rootfs 内核一致"
