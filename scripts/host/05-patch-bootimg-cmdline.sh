#!/usr/bin/env bash
# 05-patch-bootimg-cmdline.sh —— 修改 liuqin boot.img 的 /chosen/bootargs（调试用）
#
# ⚠️ 与 sheng 不同：小米 ABL 把内核 cmdline 放在 DTB 的 /chosen/bootargs 里，
#    boot header 里的 cmdline 字段内核并不读。所以「改 cmdline」= 改 DTB 里的
#    bootargs（header 可顺手保持一致），原地补 9 字节那一套在 liuqin 上无效。
#
# 用法: 05-patch-bootimg-cmdline.sh <boot.img> <新 bootargs 参数...>
#   例: 05-patch-bootimg-cmdline.sh boot.img loglevel=7 systemd.show_status=1
# 环境变量：
#   DTC / FDTOVERLAY   来自内核构建树 out/kernel/scripts/dtc/
#   MKBOOTIMG_DIR      aosp-mkbootimg 目录（内含 mkbootimg.py / unpack_bootimg.py）
#   OUT_DIR            输出目录（默认 boot.img 同目录，文件名加 .patched）
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

IMG="${1:?用法: 05-patch-bootimg-cmdline.sh <boot.img> <参数...>}"
shift
[[ $# -gt 0 ]] || die "没有要设置的参数"
[[ -f "$IMG" ]] || die "找不到 $IMG"
[[ "$(head -c 8 "$IMG")" == "ANDROID!" ]] || die "$IMG 不是 Android boot image"

DTC="${DTC:?需要 DTC（内核 out/kernel/scripts/dtc/dtc）}"
FDTOVERLAY="${FDTOVERLAY:?需要 FDTOVERLAY（内核 out/kernel/scripts/dtc/fdtoverlay）}"
MKBOOTIMG_DIR="${MKBOOTIMG_DIR:?需要 MKBOOTIMG_DIR（aosp-mkbootimg）}"
OUT_DIR="${OUT_DIR:-$(dirname "$IMG")}"
NEW_BOOTARGS="$*"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT_DIR"

# 1) 解包
python3 "$MKBOOTIMG_DIR/unpack_bootimg.py" --boot_img "$IMG" --out "$TMP/unpack" --format info > "$TMP/info"
[[ -f "$TMP/unpack/kernel" && -f "$TMP/unpack/dtb" && -f "$TMP/unpack/ramdisk" ]] || die "解包失败"

# 2) 生成覆盖 /chosen/bootargs 的 overlay 并打上去
cat > "$TMP/cmdline-overlay.dts" <<EOF
/dts-v1/;
/plugin/;
/ { fragment@0 { target-path = "/chosen"; __overlay__ { bootargs = "$NEW_BOOTARGS"; }; }; };
EOF
"$DTC" -@ -q -I dts -O dtb -o "$TMP/cmdline-overlay.dtbo" "$TMP/cmdline-overlay.dts"
"$FDTOVERLAY" -i "$TMP/unpack/dtb" -o "$TMP/new.dtb" "$TMP/cmdline-overlay.dtbo"

# 3) 按 liuqin ABL 契约重打包（与 tools/lib/build-bootimg.sh 的布局一致）
#    header v2 / pagesize 4096 / base 0 / kernel_offset 0x8000 / ramdisk_offset 0x1000000
#    tags_offset 0x100 / dtb_offset 0x1f00000；kernel 保持原样（已是 Image.gz）
python3 "$MKBOOTIMG_DIR/mkbootimg.py" \
  --header_version 2 --pagesize 4096 --base 0 \
  --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --tags_offset 0x00000100 --dtb_offset 0x01f00000 \
  --kernel "$TMP/unpack/kernel" --ramdisk "$TMP/unpack/ramdisk" --dtb "$TMP/new.dtb" \
  --cmdline "$NEW_BOOTARGS" \
  --output "$TMP/patched.img"

# 4) 回读校验
python3 "$MKBOOTIMG_DIR/unpack_bootimg.py" --boot_img "$TMP/patched.img" --out "$TMP/check" --format info > "$TMP/check.info" || die "回读失败"
cmp "$TMP/unpack/kernel" "$TMP/check/kernel" || die "kernel 段不一致"
cmp "$TMP/new.dtb" "$TMP/check/dtb" || die "dtb 段不一致"

OUT="$OUT_DIR/$(basename "$IMG" .img).patched.img"
mv -f "$TMP/patched.img" "$OUT"
log "已写回并校验通过: $OUT"
log "新 /chosen/bootargs: $NEW_BOOTARGS"
