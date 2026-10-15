#!/usr/bin/env bash
# 31-vendor-device-sources.sh —— 把 xiaomipad-6pro-mainline 的设备源码/单元文件
# 拷进本仓库 packages/*/src/，供 PKGBUILD 构建（PKGBUILD 的 source= 指向 src/ 下文件）。
#
# 用法: bash scripts/host/31-vendor-device-sources.sh <xiaomipad-6pro-mainline 检出目录>
set -euo pipefail
log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

DEV="${1:?用法: 31-vendor-device-sources.sh <xiaomipad 检出>}"
[[ -d "$DEV/device" ]] || die "不是 xiaomipad-6pro-mainline 检出"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$HERE/../../packages"

vendor() { # vendor <pkg> <src 文件...>
  local pkg="$1"; shift
  mkdir -p "$PKG/$pkg/src"
  local f ok=1
  for f in "$@"; do
    if [[ -e "$f" ]]; then
      cp -f "$f" "$PKG/$pkg/src/"
    else
      log "警告: 缺少 $f"
      ok=0
    fi
  done
  [[ "$ok" -eq 1 ]] || die "vendor $pkg 不完整，先补齐再构建"
}

vendor liuqin-power-keyd \
  "$DEV/device/power-key/liuqin-power-keyd.c" \
  "$DEV/device/gnome-overlay/etc/systemd/system/liuqin-power-keyd.service" \
  "$DEV/device/gnome-overlay/usr/local/libexec/liuqin-power-key-action" \
  "$DEV/device/gnome-overlay/usr/local/libexec/liuqin-power-menu" \
  "$DEV/device/gnome-overlay/usr/share/liuqin/power/io.github.liuqin.power.gschema.xml"

vendor liuqin-charger-mode \
  "$DEV/device/charger-mode/liuqin-charger-mode" \
  "$DEV/device/charger-mode/liuqin-charger-mode-exit.c" \
  "$DEV/device/charger-mode/liuqin-charger-mode-power-key.c"

vendor liuqin-uinput-automation \
  "$DEV/device/input/liuqin-uinput-automation.c"

vendor liuqin-mark-slot-successful \
  "$DEV/device/boot/liuqin-mark-slot-successful.c"

vendor liuqin-wlan-mac \
  "$DEV/device/gnome-overlay/usr/local/sbin/liuqin-wlan-mac" \
  "$DEV/device/gnome-overlay/etc/systemd/system/liuqin-wlan-mac.service" \
  "$DEV/device/gnome-overlay/etc/systemd/system/NetworkManager.service.d/20-liuqin-wlan-mac.conf"

vendor liuqin-bt \
  "$DEV/device/gnome-overlay/usr/local/sbin/liuqin-bt-public-addr" \
  "$DEV/device/gnome-overlay/etc/systemd/system/liuqin-bt-preconfigure.service" \
  "$DEV/device/gnome-overlay/etc/systemd/system/bluetooth.service.d/20-liuqin-public-address.conf"

vendor liuqin-backlight \
  "$DEV/device/gnome-overlay/usr/local/libexec/liuqin-backlight-default" \
  "$DEV/device/gnome-overlay/etc/systemd/system/liuqin-backlight-default.service"

vendor liuqin-mipps-auth \
  "$DEV/device/gnome-overlay/usr/local/libexec/liuqin-mipps-auth" \
  "$DEV/device/gnome-overlay/etc/systemd/system/liuqin-mipps-auth.service" \
  "$DEV/device/gnome-overlay/etc/systemd/system/liuqin-mipps-auth.service.d/10-allow-unverified-adapter.conf" \
  "$DEV/device/gnome-overlay/etc/udev/rules.d/90-liuqin-mipps-auth.rules"

# 完整固定固件闭包（197 个文件：WCN6855 WLAN、QCA6490 BT、触屏、GPU、ADSP/CS35L41、
# 音频拓扑、VPU、regdb）——来自 xiaomipad 项目的 device/firmware，按 firmware.manifest
# 锁定 OS2.0.6.0 基线。包含 per-device 数据之外的一切；per-device（WLAN MAC/BT 地址/
# 扬声器校准/传感器 registry）在设备本机从 persist 提取，见仓库 README。
mkdir -p "$PKG/liuqin-firmware/src/firmware"
cp -a "$DEV/device/firmware/usr/lib/firmware/." "$PKG/liuqin-firmware/src/firmware/"
cp -f "$DEV/device/firmware/firmware.manifest" "$PKG/liuqin-firmware/src/"

# 音频 UCM2 配置（tplg 已在固件闭包内 qcom/sm8475/Xiaomi-Pad-6-Pro-tplg.bin）
mkdir -p "$PKG/liuqin-audio/src/ucm2"
cp -a "$DEV/device/gnome-overlay/usr/share/alsa/ucm2/." "$PKG/liuqin-audio/src/ucm2/"

log "设备源码已拷入 packages/*/src/。未覆盖的（传感器栈、指纹栈、摄像头）见 packages/README.md"
