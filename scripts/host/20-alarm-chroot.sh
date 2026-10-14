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
# GitHub 托管 runner 偶发对部分域名（如 mirror.archlinuxarm.org）解析失败：
# 显式写入公共解析器 + pacman 同步/安装带重试（见下方 chroot 脚本）。
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 223.5.5.5\n' | sudo tee "$MNT/etc/resolv.conf" >/dev/null
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

log "pacman-key 初始化 + 更新仓库 + 安装 base-devel（多镜像，最多 3 次重试）..."
# 2026-10 实测：官方 mirror.archlinuxarm.org 返回 502 / DNS 不稳定（GitHub runner 上直接
# "Could not resolve host"）。改用实测可用的镜像列表（pacman 会按 Server 顺序自动切换）：
#   https://fl.us.mirror.archlinuxarm.org          （官方美国镜像，200）
#   https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm （清华，200）
#   https://mirrors.ustc.edu.cn/archlinuxarm          （中科大，200）
sudo tee "$MNT/etc/pacman.conf" >/dev/null <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Server = https://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo

[extra]
Server = https://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo

[alarm]
Server = https://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo

[aur]
Server = https://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
EOF
sudo chroot "$MNT" /bin/bash -c "
  set -e
  pacman-key --init
  pacman-key --populate archlinuxarm
  ok=0
  for attempt in 1 2 3; do
    echo '[20] 第 '\$attempt'/3 次尝试同步仓库...'
    if pacman -Sy --noconfirm && pacman -S --noconfirm --needed base-devel git rsync cpio gcc; then
      ok=1
      break
    fi
    echo '[20] 第 '\$attempt' 次失败（DNS/镜像可能暂时不可用），5 秒后重试' >&2
    sleep 5
  done
  if [ \"\$ok\" != 1 ]; then
    echo '[20] 3 次同步均失败' >&2
    exit 1
  fi
  useradd -m builder 2>/dev/null || true
"
log "ALARM chroot 就绪: $MNT"
