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

# 挂载伪文件系统：20 号脚本退出时会卸载，这里重新挂载，否则 chroot 里
# /proc、/dev 缺失会让 bash 进程替换（/dev/fd/N）失效，makepkg 报
# "pkgbuild.sh: line 73: /dev/fd/63: No such file or directory"。
for _p in "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev"; do
  sudo umount "$_p" 2>/dev/null || true
done
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

rm -rf "$OUT"; mkdir -p "$OUT"
# 把本仓库 packages/ 拷进 chroot。PKGBUILD 的 source=() 引用包目录根下的裸文件名/
# 目录（如 ucm2/、firmware/、*.c），而 31 号脚本把载荷放在 src/ 下——这里把各包
# src/ 内容合并到包目录根，makepkg 才能在构建目录找到全部 source 条目。
sudo rm -rf "$MNT/build"; sudo mkdir -p "$MNT/build"
sudo cp -a "$(cd "$SRC" && pwd)/." "$MNT/build/"
for _p in "$MNT"/build/*/; do
  if [[ -d "$_p/src" ]]; then
    sudo cp -a "$_p/src/." "$_p/"
  fi
done

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
