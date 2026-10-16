#!/usr/bin/env bash
# 00-fetch-frame-rootfs.sh —— 取 Steam Frame 官方镜像并切出 rootfs 分区
#
# 底包形态（实测 steamframe-oobe-repair-20260922.5153644-0.3.0）：
#   .img.bz2（~4.07GB）→ 解压后 ~7.5GB 的 GPT 整盘镜像，5 个分区：
#     esp(256M) / efi-A(64M) / rootfs-A(5G, btrfs) / var-A(256M) / home(100M)
#
#   ⚠️ rootfs-A.img 是 btrfs 文件系统镜像，不是 ext4+zstd 载荷 —— 后续必须按文件系统
#      直接挂载（subvolid=5），见 01-lay-rootfs.sh。
#
# 下载策略（v4，2026-10-16 实测迭代）：
#   官方 CDN 对大文件单连接会波动式节流（时快 1.6MB/s、时慢 0.16MB/s、或直接断，
#   单流 4GB 在慢速模式要 7 小时，CI 三次实测都在 ~13MB 处被掐断）。
#   → 第 1 遍：只取前 4MiB 解析 GPT 分区表（小请求稳定通过）。
#   → 第 2 遍：把整个 .bz2 拆成 8MiB 分块、12 路并行下载，每块独立重试补齐；
#     小连接即使处于慢速模式也能各自推进，最后拼合校验总字节数再流式解压。
#   磁盘峰值：完整 bz2(~4.1GB) + rootfs.frame(5GB) ≈ 9.1GB。
#
# 环境变量：
#   FRAME_IMAGE_URL  官方恢复镜像地址（默认 steamframe-repair-latest.img.bz2）
#   WORK             工作目录（默认 /mnt/frame-work，需 >= 12GB 空闲）
#   OUT              产出目录（默认 $WORK/out）
#
# 产出（$OUT 下）：
#   rootfs.frame     rootfs 分区原样镜像（~5GB，可 loop 挂载）
#   frame-gpt.txt    GPT 解析记录（分区表）
#   frame-os-release Frame 的 os-release 副本（记录底包版本）
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
log "00 脚本版本 v4（分段并行下载版，2026-10-16）"

FRAME_IMAGE_URL="${FRAME_IMAGE_URL:-https://steamdeck-images.steamos.cloud/recovery/steamframe-repair-latest.img.bz2}"
WORK="${WORK:-/mnt/frame-work}"
OUT="${OUT:-$WORK/out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEAD="$WORK/frame-head.bin"
PART="$WORK/frame-rootfs.part"
BZ2="$WORK/frame-full.img.bz2"
CHUNKDIR="$WORK/frame-chunks"
FRAME="$OUT/rootfs.frame"
CHUNK=$((8 * 1024 * 1024))           # 8MiB/块，低于 CDN 实测的 ~13MB 节流窗口
PARALLEL=12

sudo mkdir -p "$WORK" "$OUT"

# ---- 磁盘预检：完整 bz2 + rootfs.frame 峰值 ≈ 9.1GB -------------------------
FREE_KB=$(df -k --output=avail "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
log "磁盘可用: $((FREE_KB / 1024 / 1024)) GiB（$WORK）"
if [[ "$FREE_KB" -lt $((8 * 1024 * 1024)) ]]; then
  log "可用空间不足 8GiB，尝试深度清理…"
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
              /usr/local/share/boost "$AGENT_TOOLSDIRECTORY/CodeQL" 2>/dev/null || true
  sudo apt-get clean 2>/dev/null || true
  FREE_KB=$(df -k --output=avail "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
  log "清理后磁盘可用: $((FREE_KB / 1024 / 1024)) GiB"
  [[ "$FREE_KB" -lt $((8 * 1024 * 1024)) ]] && die "磁盘可用不足 8GiB，无法保存底包与 rootfs.frame"
fi

# ---- 候选地址：latest 别名是稳定指针（302→当前版本化文件），版本化文件名兜底，
#      目录索引自动发现最新版本（防旧版本被 CDN 清理后失联）。-----------------
CANDIDATES=(
  "$FRAME_IMAGE_URL"
  "https://steamdeck-images.steamos.cloud/recovery/steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2"
)
_discovered="$(curl -fsSL --max-time 30 "https://steamdeck-images.steamos.cloud/recovery/" 2>/dev/null \
  | grep -oE 'steamframe-oobe-repair-[^"<]*img\.bz2' | sort -V | tail -1 || true)"
[[ -n "$_discovered" ]] && CANDIDATES+=("https://steamdeck-images.steamos.cloud/recovery/$_discovered")

# 解析出可用地址与总字节数（跟随 302，取最终 Content-Length）
resolve_best_url() {
  local u cl
  for u in "${CANDIDATES[@]}"; do
    cl="$(curl -fsSI -L --max-time 60 "$u" 2>/dev/null \
      | awk 'tolower($0) ~ /^content-length:/{gsub("\r","",$2); print $2}' | tail -1)"
    if [[ -n "$cl" ]] && [[ "$cl" -gt 1000000 ]]; then
      echo "$u $cl"; return 0
    fi
  done
  return 1
}

# 第 1 遍：只取前 4MiB 解析 GPT（head 提前关管道会 SIGPIPE，属预期，静音吞掉）。
DLOAD_HEAD() {
  local u rc=1
  for u in "${CANDIDATES[@]}"; do
    if curl -fL -sS --connect-timeout 30 --max-time 300 "$u" 2>/dev/null; then rc=0; break; fi
  done
  return "$rc"
}
DLOAD_HEAD | bunzip2 2>/dev/null | head -c $((4 * 1024 * 1024)) > "$HEAD" || true
[[ -s "$HEAD" ]] || die "底包头部为空（连 4MiB 都取不到）"

read -r OFF LEN NAME < <(python3 "$HERE/parse-gpt.py" "$HEAD" rootfs || die "GPT 解析失败")
log "rootfs 分区: $NAME 偏移=$OFF 长度=$LEN"
printf '%s\t%s\t%s\n' "$OFF" "$LEN" "$NAME" > "$PART"

# 第 2 遍：分段并行下载完整 .bz2
BEST_URL="" TOTAL=0
read -r BEST_URL TOTAL < <(resolve_best_url) || die "无法解析底包地址/大小"
log "底包: $BEST_URL"
log "总大小: $TOTAL 字节（≈$((TOTAL / 1024 / 1024 / 1024))GiB），分块 $(( (TOTAL + CHUNK - 1) / CHUNK )) 个"
log "开始分段并行下载（$PARALLEL 路）…"

rm -rf "$CHUNKDIR"; mkdir -p "$CHUNKDIR"
export CHUNK TOTAL BEST_URL CHUNKDIR

# 分块下载 worker：i=块号，s/e 字节区间，每块最多 5 次尝试
chunk_worker() {
  local i="$1" s e f t
  s=$(( i * CHUNK )); e=$(( s + CHUNK - 1 ))
  [[ "$e" -ge "$TOTAL" ]] && e=$(( TOTAL - 1 ))
  f="$CHUNKDIR/$(printf "%05d" "$i")"
  for t in 1 2 3 4 5; do
    curl -fL -sS --connect-timeout 30 --max-time 300 -r "$s-$e" "$BEST_URL" -o "$f" && return 0
    sleep 3
  done
  return 1
}
export -f chunk_worker

seq 0 $(( (TOTAL + CHUNK - 1) / CHUNK - 1 )) | xargs -P "$PARALLEL" -n 1 bash -c 'chunk_worker "$1"' _

# 补齐缺失/不完整分块（最多 3 轮）
MISSING=()
for wave in 1 2 3; do
  MISSING=()
  for i in $(seq 0 $(( (TOTAL + CHUNK - 1) / CHUNK - 1 ))); do
    f="$CHUNKDIR/$(printf "%05d" "$i")"
    want="$CHUNK"; [[ "$i" -eq $(( (TOTAL + CHUNK - 1) / CHUNK - 1 )) ]] && want=$(( TOTAL - ( (TOTAL + CHUNK - 1) / CHUNK - 1 ) * CHUNK ))
    got="$(stat -c%s "$f" 2>/dev/null || echo 0)"
    [[ "$got" -eq "$want" ]] || MISSING+=("$i")
  done
  [[ "${#MISSING[@]}" -eq 0 ]] && break
  log "第 $wave 轮补齐缺失分块（${#MISSING[@]} 个）…"
  printf '%s\n' "${MISSING[@]}" | xargs -P "$PARALLEL" -n 1 bash -c 'chunk_worker "$1"' _
done
[[ "${#MISSING[@]}" -eq 0 ]] || die "分块下载未完成（仍缺 ${#MISSING[@]} 个分块）"

cat "$CHUNKDIR"/* > "$BZ2"
rm -rf "$CHUNKDIR"
[[ "$(stat -c%s "$BZ2")" -eq "$TOTAL" ]] || die "底包拼合校验失败（$(stat -c%s "$BZ2")/$TOTAL 字节）"
log "底包下载完成并校验通过（$TOTAL 字节）"

# 第 3 遍：流式解压并切出 rootfs 分区。
# ⚠️ 成败只看目标文件字节数 == LEN：dd 切满 count 字节后会自动关闭管道，上游
#    bunzip2 收到 SIGPIPE 属"切完即停"的正常现象，不能按管道退出码判断。
log "流式切分 rootfs 分区（$((LEN / 1024 / 1024)) MiB）…"
rm -f "$FRAME"
bunzip2 -c "$BZ2" 2>/dev/null | \
  dd of="$FRAME" bs=1M iflag=skip_bytes,count_bytes skip="$OFF" count="$LEN" status=none || true
if [[ ! -e "$FRAME" ]] || [[ "$(stat -c%s "$FRAME")" -ne "$LEN" ]]; then
  die "切出的 rootfs 字节数不符（$(stat -c%s "$FRAME" 2>/dev/null || echo 0)/$LEN）"
fi
rm -f "$BZ2"
log "rootfs.frame 字节数校验通过（$LEN 字节）"

# 记录底包版本（能读就读，读不到不致命）
mkdir -p "$WORK/frame-mnt"
sudo mount -o loop,ro,subvolid=5 "$FRAME" "$WORK/frame-mnt" 2>/dev/null && {
  sudo cp "$WORK/frame-mnt/etc/os-release" "$OUT/frame-os-release" 2>/dev/null || true
  sudo umount "$WORK/frame-mnt" 2>/dev/null || true
}
log "完成：$FRAME"
ls -lh "$FRAME"
