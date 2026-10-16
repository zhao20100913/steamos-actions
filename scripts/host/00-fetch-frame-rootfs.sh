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
log "00 脚本版本 v3（字节数校验版，2026-10-16）"

FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEAD="$WORK/frame-head.bin"
PART="$WORK/frame-rootfs.part"
FRAME="$OUT/rootfs.frame"

sudo mkdir -p "$WORK" "$OUT"

# 候选地址：latest 别名是稳定指针（302→当前版本化文件，实测可用），
# 版本化文件名是兜底（防别名失效）；另从官方目录索引自动发现最新版本
# （防旧版本被 CDN 清理后失联）。DLOAD 只报告成败不 die，由调用方处理失败。
CANDIDATES=(
  "$FRAME_IMAGE_URL"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2"
)
_discovered="$(curl -fsSL --max-time 30 "https://steamdeck-images.steamos.cloud/recovery/" 2>/dev/null \
  | grep -oE 'steamframe-oobe-repair-[^"<]*img\.bz2' | sort -V | tail -1 || true)"
[[ -n "$_discovered" ]] && CANDIDATES+=("https://steamdeck-images.steamos.cloud/recovery/$_discovered")

# 大文件全量流易被 CDN 掐断（CI 实测），full 模式加 --retry 5 + --retry-all-errors
# 覆盖连接级错误；head 模式只取前 4MiB（head 提前关管道会 SIGPIPE，属预期，
# 不重试）。-sS 保留错误信息便于排查（pass 1 的 head 模式在调用处静音）。
DLOAD() {
  local mode="${1:-full}" u rc=1
  local _retry=()
  [[ "$mode" == "full" ]] && _retry=(--retry 5 --retry-delay 5 --retry-all-errors)
  for u in "${CANDIDATES[@]}"; do
    if curl -fL -sS --connect-timeout 30 --max-time 3600 "${_retry[@]}" "$u"; then
      rc=0; break
    fi
  done
  return "$rc"
}

# 第 1 遍：只取前 4MiB 解析 GPT。head 提前关管道会让 curl/bunzip2 收到 SIGPIPE，
# 属预期行为，用 || true 吞掉（head 模式静音，避免 SIGPIPE 报错刷屏）。
DLOAD head 2>/dev/null | bunzip2 2>/dev/null | head -c $((4 * 1024 * 1024)) > "$HEAD" || true
[[ -s "$HEAD" ]] || die "底包头部为空"

read -r OFF LEN NAME < <(python3 "$HERE/parse-gpt.py" "$HEAD" rootfs || die "GPT 解析失败")
log "rootfs 分区: $NAME 偏移=$OFF 长度=$LEN"
printf '%s\t%s\t%s\n' "$OFF" "$LEN" "$NAME" > "$PART"

# 第 2 遍：流式切出 rootfs 分区（精确字节，不等整盘解压）。
# ⚠️ 成败判断只看目标文件字节数 == LEN：dd 切满 count 字节后会自动关闭管道，
#    上游 curl 收到 SIGPIPE 报 curl:(23) "Failure writing output to destination"——
#    这是"切完即停"的正常现象，不是下载失败，绝不能按管道退出码判断（run #11/12
#    每次都实际下载成功，却因此被误判失败重下 3 次）。若流被真切断，文件会小于
#    LEN，靠字节数比对仍能正确重试。
log "流式切分 rootfs 分区（$((LEN / 1024 / 1024)) MiB）..."
ok=0
for attempt in 1 2 3; do
  rm -f "$FRAME"
  DLOAD 2>/dev/null | bunzip2 2>/dev/null | \
    dd of="$FRAME" bs=1M iflag=skip_bytes,count_bytes skip="$OFF" count="$LEN" status=none || true
  if [[ -e "$FRAME" ]] && [[ "$(stat -c%s "$FRAME")" -eq "$LEN" ]]; then
    ok=1; break
  fi
  log "第 $attempt 次全量下载失败（切出 $(stat -c%s "$FRAME" 2>/dev/null || echo 0)/$LEN 字节），10 秒后重试"
  sleep 10
done
[[ "$ok" -eq 1 ]] || die "所有底包地址都取不到（已重试 3 次）"
log "rootfs.frame 字节数校验通过（$LEN 字节）"

# 记录底包版本（能读就读，读不到不致命）
mkdir -p "$WORK/frame-mnt"
sudo mount -o loop,ro,subvolid=5 "$FRAME" "$WORK/frame-mnt" 2>/dev/null && {
  sudo cp "$WORK/frame-mnt/etc/os-release" "$OUT/frame-os-release" 2>/dev/null || true
  sudo umount "$WORK/frame-mnt" 2>/dev/null || true
}
log "完成：$FRAME"
ls -lh "$FRAME"
