#!/usr/bin/env bash
# 21-build-pkg.sh —— 在 ALARM chroot 里构建本仓库 packages/ 下全部 PKGBUILD
# 用法: sudo scripts/host/21-build-pkg.sh <chroot 挂载点> <packages 目录> <输出目录>
# 产出：<输出目录>/*.pkg.tar.*（直接供 rootfs 组装时 pacman -U）
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "需要 root"

MNT="${1:-/mnt/alarm}"
SRC="${2:-packages}"
OUT="${3:-pkgs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -x "$MNT/usr/bin/pacman" ]] || die "chroot 未就绪（先跑 20-alarm-chroot.sh）"

rm -rf "$OUT"; mkdir -p "$OUT"
# 把本仓库 packages/ 拷进 chroot（包含各包 src/ 里的载荷，PKGBUILD 的 source= 指向它们）
sudo rm -rf "$MNT/build"; sudo mkdir -p "$MNT/build"
sudo cp -a "$(cd "$SRC" && pwd)/." "$MNT/build/"

for pkgdir in "$(cd "$SRC" && pwd)"/*/; do
  [[ -f "$pkgdir/PKGBUILD" ]] || continue
  name="$(basename "$pkgdir")"
  log "构建 $name"
  if ! sudo chroot "$MNT" /bin/bash -c "
    set -e
    chown -R builder:builder /build
    cd /build/$name
    sudo -u builder makepkg -f --noconfirm --skipchecksums
  "; then
    die "构建 $name 失败"
  fi
  sudo find "$MNT/build/$name" -maxdepth 1 -name '*.pkg.tar.*' -exec cp {} "$OUT/" \;
done

log "构建完成，共 $(ls -1 "$OUT"/*.pkg.tar.* 2>/dev/null | wc -l) 个包："
ls -1 "$OUT" 2>/dev/null | sed 's/^/    /'
