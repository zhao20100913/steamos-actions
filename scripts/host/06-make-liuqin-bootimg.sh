#!/usr/bin/env bash
# 06-make-liuqin-bootimg.sh —— 制作能被小米 ABL 接受的 liuqin boot.img
#
# liuqin 的 boot.img 契约（来自 xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh）：
#   * boot header v2 / pagesize 4096 / base 0 / kernel 为 gzip 的 Image；
#   * 内核 cmdline 从 DTB 的 /chosen/bootargs 读取（header 字段仅作记录）；
#   * DTB 必须叠加 liuqin-abl-boot-overlay（板级身份）+ 全量 __symbols__ sink
#     （ABL 会对镜像携带的 DTB 应用原厂 DTBO overlay，mainline DTB 没有 __symbols__
#      会直接 abort）——sink 需要原厂 analysis 产物（44 个 dtbo 条目 + 14 个基础 dtb）；
#   * 无 initramfs：ramdisk 传空 cpio，内核直挂根。
#
# 用法:
#   06-make-liuqin-bootimg.sh \
#     --work DIR --kernel-out DIR --boot-mode <single (userdata)|dual (linux_root)> \
#     [--stock-inputs-url URL | --stock-inputs-dir DIR]
#
# 环境变量（透传给上游 build-bootimg.sh 的覆盖项）：
#   CMDLINE / HEADER_CMDLINE / ABL_DTB02_IDS / STOCK_OVERLAY_DIR / STOCK_BASE_DIR ...
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

WORK="${WORK:-$PWD/work}"
KERNEL_OUT="${KERNEL_OUT:-$WORK/out/kernel}"
BOOT_MODE="${BOOT_MODE:-single (userdata)}"
STOCK_INPUTS_URL="${STOCK_INPUTS_URL:-}"
STOCK_INPUTS_DIR="${STOCK_INPUTS_DIR:-}"
OUT_DIR="${OUT_DIR:-$WORK/out}"

# 简易参数解析（也支持 --key value 形式）
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work)        WORK="$2"; shift 2 ;;
    --kernel-out)  KERNEL_OUT="$2"; shift 2 ;;
    --boot-mode)   BOOT_MODE="$2"; shift 2 ;;
    --stock-inputs-url)  STOCK_INPUTS_URL="$2"; shift 2 ;;
    --stock-inputs-dir)  STOCK_INPUTS_DIR="$2"; shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done

case "$BOOT_MODE" in
  "single (userdata)") LABEL="userdata" ;;
  "dual (linux_root)") LABEL="linux_root" ;;
  *) die "未知 boot_mode: $BOOT_MODE" ;;
esac
log "boot_mode=$BOOT_MODE → root=PARTLABEL=$LABEL"

XIAOMI="${XIAOMI_PROJECT:-$WORK/xiaomipad-6pro-mainline}"
KSRC="${KERNEL_SOURCE:-$WORK/linux-sm8450-liuqin}"
[[ -d "$XIAOMI/tools/lib" ]] || die "找不到 xiaomipad-6pro-mainline 检出（$XIAOMI）"

IMAGE="$KERNEL_OUT/arch/arm64/boot/Image"
DTB_RAW="$KERNEL_OUT/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb"
DTC="$KERNEL_OUT/scripts/dtc/dtc"
FDTOVERLAY="$KERNEL_OUT/scripts/dtc/fdtoverlay"
for f in "$IMAGE" "$DTB_RAW" "$DTC" "$FDTOVERLAY"; do
  [[ -r "$f" ]] || die "缺少内核构建产物: $f"
done

# 1) mkbootimg（AOSP 固定 commit，与上游 liuqin 项目一致）
MKBOOTIMG_DIR="$WORK/aosp-mkbootimg"
if [[ ! -x "$MKBOOTIMG_DIR/mkbootimg.py" ]]; then
  ( cd "$XIAOMI" && sh tools/fetch-aosp-mkbootimg.sh ) \
    || die "fetch-aosp-mkbootimg.sh 失败"
  cp -a "$XIAOMI/tools/local/aosp-mkbootimg" "$MKBOOTIMG_DIR"
fi

# 2) stock inputs（boot.img 被 ABL 接受的硬前提）
if [[ -n "$STOCK_INPUTS_URL" ]]; then
  mkdir -p "$WORK/stock"
  curl -fsSL --retry 3 "$STOCK_INPUTS_URL" -o "$WORK/stock/stock-inputs.tar.gz" \
    || die "stock inputs 下载失败: $STOCK_INPUTS_URL"
  tar -xzf "$WORK/stock/stock-inputs.tar.gz" -C "$WORK/stock" || die "stock inputs 解包失败"
  STOCK_INPUTS_DIR="$WORK/stock"
fi
if [[ -n "$STOCK_INPUTS_DIR" ]]; then
  STOCK_OVERLAY_DIR="${STOCK_OVERLAY_DIR:-$STOCK_INPUTS_DIR/analysis/dtbo}"
  STOCK_BASE_DIR="${STOCK_BASE_DIR:-$STOCK_INPUTS_DIR/analysis/vendor_boot/dtbs}"
else
  die "缺少 stock inputs（--stock-inputs-url 或 --stock-inputs-dir）。没有原厂 dtbo/vendor_boot 产物，ABL 不会接受这个 boot.img。生产方法见仓库 README。"
fi
n_overlay=$(find "$STOCK_OVERLAY_DIR" -maxdepth 1 -type f -regex '.*/entry\.[0-9]+' | wc -l)
n_base=$(find "$STOCK_BASE_DIR" -maxdepth 1 -type f -regex '.*/dtb-[0-9][0-9]\.dtb' | wc -l)
log "stock inputs: dtbo=$n_overlay 条目, base dtb=$n_base"
[[ "$n_overlay" -eq 44 ]] || warn "期望 44 个 dtbo 条目，实际 $n_overlay（上游 build-bootimg.sh 会强校验）"
[[ "$n_base" -eq 14 ]] || warn "期望 14 个基础 dtb，实际 $n_base"

# 3) 空 initramfs（SteamOS 无 initramfs，内核直挂根）
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RAMDISK="$TMP/empty.cpio.gz"
( cd "$TMP" && printf '' | cpio -o -H newc 2>/dev/null | gzip -n > "$RAMDISK" ) || \
  { : > "$RAMDISK"; }

# 4) cmdline：与上游 liuqin 首启串一致 + root=PARTLABEL=<label>
#    ⚠️ liuqin 的内核 cmdline 由 ABL 从 DTB /chosen/bootargs 读取，boot header 字段内核不读；
#    主 DTB 的 bootargs 是内核 DTS 里固定的默认串，追加参数必须先用 fdtoverlay 把
#    /chosen/bootargs 整个替换掉，且与传给 build-bootimg.sh 的 CMDLINE 完全一致
#    （上游脚本会用 grep -F 校验二者相等，不一致直接构建失败）。
BOOTARGS_BASE="earlycon=simplefb console=drm_log console=tty0 initcall_blacklist=simplefb_driver_init rootwait"
CMDLINE="${CMDLINE:-$BOOTARGS_BASE root=PARTLABEL=$LABEL}"
HEADER_CMDLINE="${HEADER_CMDLINE:-$CMDLINE}"
log "DT bootargs: $CMDLINE"

# 主 DTB 是二进制，字符串无法用源码语法匹配；统一走 overlay 替换（构建脚本会
# 在最终 DTS 上校验 bootargs == CMDLINE，不一致会失败，这里无需自行判断）。
log "替换 /chosen/bootargs（首启基底参数 + root=PARTLABEL=$LABEL）…"
cat > "$TMP/bootargs-overlay.dts" <<EOF
/dts-v1/;
/plugin/;
/ { fragment@0 { target-path = "/chosen"; __overlay__ { bootargs = "$CMDLINE"; }; }; };
EOF
"$DTC" -@ -q -I dts -O dtb -o "$TMP/bootargs-overlay.dtbo" "$TMP/bootargs-overlay.dts"
"$FDTOVERLAY" -i "$DTB_RAW" -o "$WORK/sm8475-xiaomi-liuqin-steamos.dtb" "$TMP/bootargs-overlay.dtbo"
DTB_TO_BUILD="$WORK/sm8475-xiaomi-liuqin-steamos.dtb"

# 5) 调用上游 build-bootimg.sh（MIT，来自 xiaomipad-6pro-mainline）
BOOT_OUT="$WORK/out/boot"
mkdir -p "$BOOT_OUT"
IMAGE="$IMAGE" DTB="$DTB_TO_BUILD" RAMDISK="$RAMDISK" \
DTC="$DTC" FDTOVERLAY="$FDTOVERLAY" \
MKBOOTIMG_DIR="$MKBOOTIMG_DIR" \
CMDLINE="$CMDLINE" HEADER_CMDLINE="$HEADER_CMDLINE" \
ABL_OVERLAY_SINK=1 \
STOCK_OVERLAY_DIR="$STOCK_OVERLAY_DIR" STOCK_BASE_DIR="$STOCK_BASE_DIR" \
KERNEL_OUT="$KERNEL_OUT" OUT_DIR="$BOOT_OUT" \
sh "$XIAOMI/tools/lib/build-bootimg.sh"

# 6) 改名输出
mkdir -p "$OUT_DIR"
cp -f "$BOOT_OUT/boot-liuqin-firstboot.img" "$OUT_DIR/boot-liuqin-steamos.img"
log "完成: $OUT_DIR/boot-liuqin-steamos.img"
ls -lh "$OUT_DIR/boot-liuqin-steamos.img"
