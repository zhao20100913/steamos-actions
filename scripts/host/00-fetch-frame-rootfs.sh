#!/usr/bin/env bash
# 00-fetch-frame-rootfs.sh —— 取 Steam Frame 官方镜像并切出 rootfs 分区
#
# 底包形态（实测 steamframe-oobe-repair-20260922.5153644-0.3.0）：
#   .img.zip（~4.06GB）→ lun0.img ≈ 7GiB 的 GPT 整盘镜像，5 个分区：
#     esp(256M, FAT) / efi-A(64M) / rootfs-A(5G, btrfs) / var-A(256M) / home(100M)
#   .img.bz2（~4.07GB）→ 同一镜像的 bzip2 版
#
#   ⚠️ rootfs-A 是 btrfs（超块在分区内偏移 64KiB，magic 在超块+64B）——
#      后续必须按文件系统直接挂载（subvolid=5），见 01-lay-rootfs.sh。
#
# 下载策略（v7，2026-10-17，稳定版）：
#   1) 官方 CDN 对大文件单连接波动式节流 → 把整个文件拆成 8MiB 分块、12 路并行
#      下载，每块独立重试补齐，拼合后校验总字节数。
#   2) 内容校验用 zip 优先：`unzip -p` 落盘时会做全流 CRC32 校验（zip 是严格门，
#      任何内容损坏都退出非零；对比 bzip2 会忽略"流结束后的尾部垃圾"而误放行）。
#   3) 切分必须"落盘后用文件输入 dd"：GNU dd 从管道读时单次 read 只有 ~64KiB，
#      `bs=1M skip/count` 按条记录计数导致输出远小于预期（实测 5GiB 只出 320MiB）
#      —— 此前 v3~v6 的"切出 25.7MB"失败正是这个 dd 管道 bug，不是 CDN 内容坏。
#      文件输入时 dd 可填满 bs，skip=320 count=5120（1MiB 块）精确切出。
#   4) 最多 6 轮：每轮换源重下（zip 版本化 / bz2 latest / bz2 版本化）。
#   磁盘峰值：zip(4.06GB) + lun0.img(7GiB) + rootfs.frame(5GiB) ≈ 16.1GB。
#
# 环境变量：
#   FRAME_IMAGE_URL  官方恢复镜像地址（默认 steamframe-repair-latest.img.bz2）
#   WORK             工作目录（默认 /mnt/frame-work，需 >= 18GB 空闲）
#   OUT              产出目录（默认 $WORK/out）
#
# 产出（$OUT 下）：
#   rootfs.frame     rootfs 分区原样镜像（~5GB，可 loop 挂载，btrfs）
#   frame-gpt.txt    GPT 解析记录（分区表）
#   frame-os-release Frame 的 os-release 副本（记录底包版本）
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
log "00 脚本版本 v7（zip 优先+严格 CRC+落盘切分，2026-10-17）"

FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEAD="$WORK/frame-head.bin"
PART="$WORK/frame-rootfs.part"
ARC="$WORK/frame-full.img"
IMG_RAW="$WORK/frame-lun0.img"
CHUNKDIR="$WORK/frame-chunks"
FRAME="$OUT/rootfs.frame"
CHUNK=$((8 * 1024 * 1024))           # 8MiB/块
PARALLEL=12

command -v unzip >/dev/null 2>&1 || { log "安装 unzip…"; sudo apt-get update -qq && sudo apt-get install -y -qq unzip; }
sudo mkdir -p "$WORK" "$OUT"

# ---- 磁盘预检：zip + lun0.img + rootfs.frame 峰值 ≈ 16.1GB ------------------
FREE_KB=$(df -k --output=avail "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
log "磁盘可用: $((FREE_KB / 1024 / 1024)) GiB（$WORK）"
if [[ "$FREE_KB" -lt $((18 * 1024 * 1024)) ]]; then
  log "可用空间不足 18GiB，尝试深度清理…"
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
              /usr/local/share/boost "$AGENT_TOOLSDIRECTORY/CodeQL" 2>/dev/null || true
  sudo apt-get clean 2>/dev/null || true
  FREE_KB=$(df -k --output=avail "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
  log "清理后磁盘可用: $((FREE_KB / 1024 / 1024)) GiB"
  [[ "$FREE_KB" -lt $((18 * 1024 * 1024)) ]] && die "磁盘可用不足 18GiB，无法保存底包与 rootfs.frame"
fi

# ---- 候选地址：zip 版本化（主，unzip 严格 CRC 门）+ bz2 latest/版本化（回退）----
CANDIDATES=(
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.zip"
  "$FRAME_IMAGE_URL"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2"
)
_discovered="$(curl -fsSL --max-time 30 "https://steamdeck-images.steamos.cloud/recovery/" 2>/dev/null \
  | grep -oE 'steamframe-oobe-repair-[^"<]*(img\.zip|img\.bz2)' | sort -V | tail -1 || true)"
[[ -n "$_discovered" ]] && CANDIDATES+=("https://steamdeck-images.steamos.cloud/recovery/$_discovered")

kind_of() { case "$1" in *.zip) echo zip;; *.bz2) echo bz2;; *) echo bz2;; esac; }

# 分块下载 worker：i=块号，s/e 字节区间，每块最多 5 次尝试
chunk_worker() {
  local i="$1" s e f t
  s=$(( i * CHUNK )); e=$(( s + CHUNK - 1 ))
  [[ "$e" -ge "$TOTAL" ]] && e=$(( TOTAL - 1 ))
  f="$CHUNKDIR/$(printf "%05d" "$i")"
  for t in 1 2 3 4 5; do
    curl -fL -sS --connect-timeout 30 --max-time 300 -r "$s-$e" "$DL_URL" -o "$f" && return 0
    sleep 3
  done
  return 1
}
export -f chunk_worker

pass=0
for cycle in 1 2 3 4 5 6; do
  U="${CANDIDATES[$(( (cycle - 1) % ${#CANDIDATES[@]} ))]}"
  TYPE="$(kind_of "$U")"
  TOTAL="$(curl -fsSI -L --max-time 60 "$U" 2>/dev/null \
    | awk 'tolower($0) ~ /^content-length:/{gsub("\r","",$2); print $2}' | tail -1 || true)"
  [[ -n "$TOTAL" ]] && [[ "$TOTAL" -gt 1000000 ]] || { log "第 $cycle 轮候选不可用（$U），跳过"; continue; }
  log "第 $cycle 轮下载（$PARALLEL 路，${TYPE} 源 ${U##*/}，$TOTAL 字节）…"

  # 分段并行下载 + 补齐
  rm -rf "$CHUNKDIR"; mkdir -p "$CHUNKDIR"
  export CHUNK TOTAL CHUNKDIR DL_URL="$U"
  NCHUNK=$(( (TOTAL + CHUNK - 1) / CHUNK ))
  seq 0 $(( NCHUNK - 1 )) | xargs -P "$PARALLEL" -n 1 bash -c 'chunk_worker "$1"' _
  MISSING=()
  for wave in 1 2 3; do
    MISSING=()
    for i in $(seq 0 $(( NCHUNK - 1 ))); do
      f="$CHUNKDIR/$(printf "%05d" "$i")"
      want="$CHUNK"; [[ "$i" -eq $(( NCHUNK - 1 )) ]] && want=$(( TOTAL - (NCHUNK - 1) * CHUNK ))
      got="$(stat -c%s "$f" 2>/dev/null || echo 0)"
      [[ "$got" -eq "$want" ]] || MISSING+=("$i")
    done
    [[ "${#MISSING[@]}" -eq 0 ]] && break
    log "第 $cycle 轮第 $wave 波补齐缺失分块（${#MISSING[@]} 个）…"
    printf '%s\n' "${MISSING[@]}" | xargs -P "$PARALLEL" -n 1 bash -c 'chunk_worker "$1"' _
  done
  [[ "${#MISSING[@]}" -eq 0 ]] || { log "第 $cycle 轮仍缺 ${#MISSING[@]} 个分块，换源重试"; continue; }

  cat "$CHUNKDIR"/* > "$ARC"
  rm -rf "$CHUNKDIR"
  [[ "$(stat -c%s "$ARC")" -eq "$TOTAL" ]] || { log "第 $cycle 轮拼合大小不符（$(stat -c%s "$ARC")/$TOTAL），重试"; continue; }
  log "第 $cycle 轮下载完成（$TOTAL 字节），解压到整盘镜像…"

  # 解压落盘（zip: unzip -p 内置全流 CRC32 严格门；bz2: 流内 CRC/截断会失败）
  rm -f "$IMG_RAW"
  if [[ "$TYPE" == "zip" ]]; then
    if ! unzip -p "$ARC" lun0.img > "$IMG_RAW" 2>/dev/null; then
      log "第 $cycle 轮 unzip CRC 校验失败（内容损坏），换源重下"; rm -f "$ARC"; continue
    fi
  else
    if ! bunzip2 -c "$ARC" > "$IMG_RAW" 2>/dev/null; then
      log "第 $cycle 轮 bunzip2 解压失败（内容损坏），换源重下"; rm -f "$ARC"; continue
    fi
  fi
  rm -f "$ARC"
  log "第 $cycle 轮整盘镜像: $(stat -c%s "$IMG_RAW") 字节"

  # GPT 解析 rootfs 分区（镜像 GPT 在 LBA1=偏移 512，parse-gpt.py 标准兼容）
  head -c $((4 * 1024 * 1024)) "$IMG_RAW" > "$HEAD"
  OFF="" LEN="" NAME=""
  read -r OFF LEN NAME < <(python3 "$HERE/parse-gpt.py" "$HEAD" rootfs || true)
  [[ -n "$OFF" ]] || { log "第 $cycle 轮 GPT 解析失败，换源重试"; rm -f "$IMG_RAW"; continue; }
  log "rootfs 分区: $NAME 偏移=$OFF 长度=$LEN"
  printf '%s\t%s\t%s\n' "$OFF" "$LEN" "$NAME" > "$PART"

  # 切分必须 1MiB 块对齐（rootfs-A = 320MiB 偏移 / 5GiB 长度，天然对齐）
  if [[ $((OFF % 1048576)) -ne 0 ]] || [[ $((LEN % 1048576)) -ne 0 ]]; then
    die "rootfs 分区非 1MiB 对齐（$OFF/$LEN），请改用字节级 dd"
  fi
  log "流式切分 rootfs 分区（$((LEN / 1024 / 1024)) MiB）…"
  rm -f "$FRAME"
  dd if="$IMG_RAW" bs=1M skip=$((OFF / 1048576)) count=$((LEN / 1048576)) of="$FRAME" status=none
  rm -f "$IMG_RAW"
  if [[ "$(stat -c%s "$FRAME")" -eq "$LEN" ]]; then
    pass=1; log "rootfs.frame 字节数校验通过（$LEN 字节）"; break
  fi
  log "第 $cycle 轮切出字节数不符（$(stat -c%s "$FRAME" 2>/dev/null || echo 0)/$LEN），换源重下"
done
[[ "$pass" -eq 1 ]] || die "底包 6 轮下载+内容校验均失败"

# 记录底包版本（能读就读，读不到不致命）
mkdir -p "$WORK/frame-mnt"
sudo mount -o loop,ro,subvolid=5 "$FRAME" "$WORK/frame-mnt" 2>/dev/null && {
  sudo cp "$WORK/frame-mnt/etc/os-release" "$OUT/frame-os-release" 2>/dev/null || true
  sudo umount "$WORK/frame-mnt" 2>/dev/null || true
}
log "完成：$FRAME"
ls -lh "$FRAME"
