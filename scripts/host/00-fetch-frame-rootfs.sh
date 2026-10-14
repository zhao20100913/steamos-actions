#!/usr/bin/env bash
# 00-fetch-frame-rootfs.sh —— 取 Steam Frame 官方镜像并切出 rootfs 分区
#
# 底包形态（实测 steamframe-oobe-repair-20260922.5153644-0.3.0）：
#   .img.bz2（~4GB）→ 解压后 ~7.5GB 的 GPT 整盘镜像，5 个分区：
#     esp(256M) / efi-A(64M) / rootfs-A(5G, btrfs) / var-A(256M) / home(100M)
#
#   ⚠️ rootfs-A.img 是 btrfs 文件系统镜像，不是 ext4+zstd 载荷 —— 后续必须按文件系统
#      直接挂载（subvolid=5），见 01-lay-rootfs.sh。
#
# 磁盘紧张时走「流式两遍」：第 1 遍只取前 4MiB 解析 GPT 分区表，第 2 遍
# curl | bunzip2 | dd 精确切出 rootfs 分区 —— 全程只落盘 ~5GB。
#
# 环境变量：
#   FRAME_IMAGE_URL  官方恢复镜像地址（默认 steamframe-repair-latest.img.bz2）
#   WORK             工作目录（默认 /mnt/frame-work，需 >= 8GB 空闲）
#   OUT              产出目录（默认 $WORK/out）
#
# 产出（$OUT 下）：
#   rootfs.frame     rootfs 分区原样镜像（~5GB，可 loop 挂载）
#   frame-gpt.txt    GPT 解析记录（分区表）
#   frame-os-release Frame 的 os-release 副本（记录底包版本）
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEAD="$WORK/frame-head.bin"
PART="$WORK/frame-rootfs.part"
FRAME="$OUT/rootfs.frame"

sudo mkdir -p "$WORK" "$OUT"

# 候选地址：`steamframe-repair-latest` 别名在 CDN 上可能 404（CI 实测），
# 版本化文件名作为兜底；两个都试。函数把 bz2 流直接吐给 stdout。
CANDIDATES=(
  "$FRAME_IMAGE_URL"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2"
)
DLOAD() {
  local u rc=1
  for u in "${CANDIDATES[@]}"; do
    if curl -fsSL --retry 3 "$u" 2>/dev/null; then rc=0; break; fi
  done
  [[ "$rc" -eq 0 ]] || die "所有底包地址都取不到"
}

# 第 1 遍：只取前 4MiB 解析 GPT。head 提前关管道会让 curl/bunzip2 收到 SIGPIPE，
# 属预期行为，用 || true 吞掉。
DLOAD | bunzip2 2>/dev/null | head -c $((4 * 1024 * 1024)) > "$HEAD" || true
[[ -s "$HEAD" ]] || die "底包头部为空"

read -r OFF LEN NAME < <(python3 "$HERE/parse-gpt.py" "$HEAD" rootfs || die "GPT 解析失败")
log "rootfs 分区: $NAME 偏移=$OFF 长度=$LEN"
printf '%s\t%s\t%s\n' "$OFF" "$LEN" "$NAME" > "$PART"

# 第 2 遍：流式切出 rootfs 分区（精确字节，不等整盘解压）
log "流式切分 rootfs 分区（$((LEN / 1024 / 1024)) MiB）..."
DLOAD | bunzip2 2>/dev/null | \
  dd of="$FRAME" bs=1M iflag=skip_bytes,count_bytes skip="$OFF" count="$LEN" status=none
[[ -s "$FRAME" ]] || die "切出的 rootfs 为空"

# 记录底包版本（能读就读，读不到不致命）
mkdir -p "$WORK/frame-mnt"
sudo mount -o loop,ro,subvolid=5 "$FRAME" "$WORK/frame-mnt" 2>/dev/null && {
  sudo cp "$WORK/frame-mnt/etc/os-release" "$OUT/frame-os-release" 2>/dev/null || true
  sudo umount "$WORK/frame-mnt" 2>/dev/null || true
}
log "完成：$FRAME"
ls -lh "$FRAME"
