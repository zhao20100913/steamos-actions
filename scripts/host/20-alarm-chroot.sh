#!/usr/bin/env bash
# 20-alarm-chroot.sh —— 准备 Arch Linux ARM (aarch64) 原生 chroot（arm64 runner 上用）
#
# 用法: sudo scripts/host/20-alarm-chroot.sh [挂载点，默认 /mnt/alarm]
# 环境变量：ALARM_MIRROR（默认 os.archlinuxarm.org 最新 aarch64 tarball）
# 幂等：chroot 已就绪（有 /usr/bin/pacman）时直接退出。
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "需要 root"

MNT="${1:-/mnt/alarm}"
ALARM_MIRROR="${ALARM_MIRROR:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"

if [[ -x "$MNT/usr/bin/pacman" ]]; then
  log "chroot 已存在: $MNT"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'sudo rm -rf "$TMP"' EXIT
sudo rm -rf "$MNT"; sudo mkdir -p "$MNT"

log "下载 ALARM tarball..."
curl -fsSL --retry 3 "$ALARM_MIRROR" -o "$TMP/alarm.tar.gz" || die "ALARM 下载失败"
sudo tar -xzf "$TMP/alarm.tar.gz" -C "$MNT" || die "ALARM 解包失败"

# 网络与伪文件系统
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sysfs "$MNT/sys"

cleanup() {
  sudo umount "$MNT/sys" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
}
trap cleanup EXIT

log "pacman-key 初始化 + 更新仓库 + 安装 base-devel..."
sudo chroot "$MNT" /bin/bash -c "
  set -e
  pacman-key --init
  pacman-key --populate archlinuxarm
  pacman -Sy --noconfirm
  pacman -S --noconfirm --needed base-devel git rsync cpio gcc
  useradd -m builder 2>/dev/null || true
"
log "ALARM chroot 就绪: $MNT"
