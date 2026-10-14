#!/usr/bin/env bash
# 01-lay-rootfs.sh —— 把 Frame 的 rootfs 铺进我们自己的 ext4 镜像
# 用法: sudo scripts/host/01-lay-rootfs.sh <frame rootfs 分区镜像> <rootfs.img> [大小, 如 14G]
#
# 关键点（参考 Steamos-xiaomi-sheng 实测结论）：
#   * Frame 的 rootfs 分区是 btrfs，必须用 subvolid=5 挂到顶层，才能同时看到根子卷
#     和平级的 @var/@home 等子卷；只挂默认子卷的话 /var 是空的，systemd 起不来。
#   * 目标镜像尺寸自适应：先量源用量，目标不足时自动放大（否则 rsync 中途 ENOSPC）。
#   * 铺完立即删掉 ~5GB 的源分区镜像，给后面的 chroot 注入腾地方。
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "需要 root"

SRC="${1:?用法: 01-lay-rootfs.sh <frame rootfs 镜像> <rootfs.img> [size]}"
IMG="${2:?}"
SIZE="${3:-14G}"
MOUNT_SRC=/mnt/frame-src
MOUNT_DST=/mnt/rootfs

mkdir -p "$MOUNT_SRC" "$MOUNT_DST"
umount "$MOUNT_SRC" 2>/dev/null || true
umount "$MOUNT_DST" 2>/dev/null || true

# 1) 挂载 Frame 源分区（btrfs → subvolid=5 顶层；其它文件系统自动识别）
modprobe btrfs 2>/dev/null || true
FSTYPE="$(blkid -o value -s TYPE "$SRC" 2>/dev/null || true)"
log "源分区 $SRC: fstype=${FSTYPE:-未知}"
if [[ "$FSTYPE" == "btrfs" ]]; then
  mount -o loop,ro,subvolid=5 "$SRC" "$MOUNT_SRC" || die "btrfs 挂载失败（subvolid=5）"
else
  mount -o loop,ro "$SRC" "$MOUNT_SRC" || die "挂载 Frame rootfs 失败"
fi
trap 'umount "$MOUNT_SRC" 2>/dev/null || true; umount "$MOUNT_DST" 2>/dev/null || true' EXIT

# 2) 量源用量（排除运行期伪目录），目标尺寸 = max(给定下限, 源用量 + 1.5GiB 余量)
need_mb="$(du -sm --exclude=proc --exclude=sys --exclude=dev --exclude=run --exclude=tmp "$MOUNT_SRC" 2>/dev/null | cut -f1)"
need_mb=$(( need_mb + 1536 ))
_sz="${SIZE^^}"; _unit="${_sz: -1}"; _num="${_sz%?}"
case "$_unit" in
  G) want_mb=$(( ${_num%.*} * 1024 )) ;;
  M) want_mb=$(( ${_num%.*} )) ;;
  *) die "无法解析尺寸 $SIZE（只认 G/M 后缀）" ;;
esac
use_mb=$(( need_mb > want_mb ? need_mb : want_mb ))
log "源用量 ${need_mb} MiB（含余量），请求 ${want_mb} MiB → 创建 ${use_mb} MiB"

# 3) 创建 ext4 目标镜像（标签 rootfs，供事后校验；fstab 实际用 PARTLABEL）
truncate -s "${use_mb}M" "$IMG"
mkfs.ext4 -q -F -L rootfs "$IMG" || die "mkfs.ext4 失败"

# 4) 铺层：整棵 btrfs 顶层树（含各子卷内容）rsync 进 ext4
mount -o loop "$IMG" "$MOUNT_DST" || die "挂载目标镜像失败"
log "开始 rsync（btrfs 子卷只读属性自动忽略）..."
rsync -aHAX --info=progress2 \
  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp \
  "$MOUNT_SRC/" "$MOUNT_DST/" || die "rsync 失败"
sync
umount "$MOUNT_DST" || die "卸载目标失败"
log "铺层完成"

# 5) 腾空间：删掉源分区镜像（后续 chroot 注入很吃磁盘）
rm -f "$SRC"
log "已删除源镜像 $SRC"
ls -lh "$IMG"
