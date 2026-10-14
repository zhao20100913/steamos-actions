#!/usr/bin/env bash
# 03-finalize-image.sh —— 卸载 → 校验 → 收缩 → （可选）固定 UUID
# 用法: sudo scripts/host/03-finalize-image.sh <rootfs.img> [挂载点]
#
# 环境变量：
#   SHRINK_IMAGE   true（默认）/ false —— 是否 e2fsck + resize2fs -M + truncate
#   FS_UUID        设置 ext4 固定 UUID（默认不设置；liuqin 用 PARTLABEL 挂根，不需要）
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
[[ "${EUID}" -eq 0 ]] || { echo "需要 root" >&2; exit 1; }

IMG="${1:-rootfs.img}"
MOUNT="${2:-/mnt/rootfs}"
FS_UUID="${FS_UUID:-}"
SHRINK="${SHRINK_IMAGE:-true}"

umount -R "$MOUNT" 2>/dev/null || umount "$MOUNT" 2>/dev/null || warn "挂载点未挂载: $MOUNT"
sync

# workflow 里这一步是 if: always()：前面失败时镜像可能不存在，只做卸载即可
if [[ ! -e "$IMG" ]]; then
  warn "镜像 $IMG 不存在（前面的步骤失败了？）——只做卸载，跳过校验/收缩"
  exit 0
fi

e2fsck -fy "$IMG" >/dev/null 2>&1 || warn "e2fsck 报告问题（已尝试修复）"

if [[ "$SHRINK" == "true" ]]; then
  before="$(du -h --apparent-size "$IMG" | cut -f1)"
  if resize2fs -M "$IMG" >/dev/null 2>&1; then
    blocks="$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}')"
    bsize="$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')"
    if [[ -n "$blocks" && -n "$bsize" ]]; then
      truncate -s "$((blocks * bsize))" "$IMG"
      log "镜像已收缩: $before → $(du -h --apparent-size "$IMG" | cut -f1)"
    else
      warn "缩容后未能算出块数，文件未截断"
    fi
  else
    warn "resize2fs -M 失败，保持 $before（仍可刷写）"
  fi
fi

if [[ -n "$FS_UUID" ]]; then
  tune2fs -U "$FS_UUID" "$IMG" >/dev/null 2>&1 || warn "设置 UUID 失败（fstab 用 PARTLABEL，不影响启动）"
fi
log "最终镜像: $(ls -lh "$IMG" | awk '{print $5}')  逻辑大小 $(du -h --apparent-size "$IMG" | cut -f1)"

# 体检：截断是否自洽（文件不得小于文件系统）
fs_size=$(( $(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}') * $(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}') ))
file_size=$(stat -c%s "$IMG")
if [[ "$file_size" -lt "$fs_size" ]]; then
  warn "镜像比文件系统短 $((fs_size - file_size)) 字节（会挂载失败）"
else
  log "几何自洽：文件 $file_size ≥ 文件系统 $fs_size"
fi
