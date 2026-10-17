#!/usr/bin/env bash
# 10-graft-liuqin.sh —— 在（已铺好 Frame userspace 的）SteamOS 镜像 chroot 内注入 liuqin 设备层
# 由 workflow 通过 chroot 调用：chroot <mount> /root/graft/10-graft-liuqin.sh
#
# 本脚本改编自 code002-2/Steamos-xiaomi-sheng 的 scripts/in-chroot/10-graft.sh
# （在小米平板 6S Pro 上实机跑通的完整移植流水线），逐条保留其已验证的 Frame 底包修复，
# 设备相关部分全部换成 liuqin（小米平板 6 Pro / SM8475）：
#   · 分区：root=PARTLABEL=<userdata|linux_root>（由环境变量 PARTLABEL 传入）
#   · 设备包：liuqin-*（power-keyd / charger-mode / uinput-automation / mark-slot-successful /
#     wlan-mac / bt / backlight / mipps-auth / firmware / audio）
#   · 触屏：liuqin 是内核驱动（Novatek NT36532 SPI），不需要 sheng 的 THP 用户态 daemon
#   · 内核：liuqin-6.17（模块从 /tmp/kernel-modules.tar.gz 解入，boot.img 已内含内核）
#
# 环境变量：
#   PARTLABEL            userdata（单系统，默认）或 linux_root（双系统布局）
#   WIFI_SSID / WIFI_PSK NM keyfile 预配（可选）
#   ROOT_PW / SSH_PUBKEY root 密码 / SSH 公钥（可选）
#   KERNEL_MODULES_TAR   内核模块 tar.gz（默认 /tmp/kernel-modules.tar.gz）
#   BUILD_KDE_MONITOR    1（默认）/0 —— 是否在镜像内自编系统监视器等 KDE 组件
#   DOWNLOAD_STEAM_CLIENT 1（默认）/0 —— 是否预下载 Valve ARM Steam 客户端
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

PARTLABEL="${PARTLABEL:-userdata}"
case "$PARTLABEL" in
  userdata|linux_root) ;;
  *) die "PARTLABEL 必须是 userdata 或 linux_root（当前 '$PARTLABEL'）" ;;
esac
log "=== 开始注入 liuqin 设备层（root=PARTLABEL=$PARTLABEL）==="

# 0) /sbin/init 必须在（内核会 exec 它；缺了会 panic: No working init found）
c="$(command -v init 2>/dev/null || true)"
[[ -n "$c" && -x "$c" ]] || die "/sbin/init 不存在（底包没铺对？）"
log "init: $c"

# 1) 撤掉 Frame 的内核生成钩子 + preset，必须在任何 pacman 事务之前：
#    移除 Frame 自带内核时 60-mkinitcpio-remove.hook 会触发，装包时 90-mkinitcpio-install.hook
#    会尝试为已被换掉的 linux-618-deckard 生成 initramfs（报 ERROR: kernel image does not exist）。
#    我们这套镜像**不用 initramfs**（内核 EXT4_FS=y / UFS_QCOM=y / DEVTMPFS_MOUNT=y 直接挂根）。
rm -f /usr/share/libalpm/hooks/*mkinitcpio* 2>/dev/null || true
rm -f /etc/mkinitcpio.d/*.preset 2>/dev/null || true
log "已撤掉 mkinitcpio 钩子与 preset（无 initramfs 启动）"

# 2) 卸掉 Frame 的内核（我们用自己的 liuqin 内核），再装我们的设备包
#    Frame 内核包名随版本变化，按 /boot 下实际存在的 vmlinuz 反查
mapfile -t FRAME_KERNELS < <(pacman -Qq 2>/dev/null | grep -E '^linux(-[0-9a-z-]+)?$' || true)
if [[ ${#FRAME_KERNELS[@]} -gt 0 ]]; then
  pacman -Rdd --noconfirm "${FRAME_KERNELS[@]}" >/dev/null 2>&1 \
    && log "已移除 Frame 内核: ${FRAME_KERNELS[*]}" \
    || warn "移除 Frame 内核失败（继续，后面模块目录可能残留）"
fi
# Frame 固件包也换掉（我们提供 liuqin 固定固件闭包）
pacman -Rdd --noconfirm linux-firmware steamos-firmware 2>/dev/null \
  && log "已移除 Frame 固件包（由 liuqin-firmware 接管）" || true

# 2.5) 我们的包是 ALARM makepkg 产物（未签名），Frame 的 pacman.conf 若强制校验
#      Signature = Required 会导致 pacman -U 报 signature is unknown trust —— 放开本地包签名
if ! grep -q '^LocalFileSigLevel' /etc/pacman.conf; then
  printf '\n[options]\nLocalFileSigLevel = Optional\n' >> /etc/pacman.conf
else
  sed -i 's/^LocalFileSigLevel.*/LocalFileSigLevel = Optional/' /etc/pacman.conf
fi
log "pacman 本地包签名已放开（Optional）"

# 3) 安装 liuqin 设备包
PKGDIR="${PKGDIR:-/tmp/pkgs}"
mapfile -t pkgs < <(find "$PKGDIR" -maxdepth 1 -name '*.pkg.tar.*' | sort)
if [[ ${#pkgs[@]} -eq 0 ]]; then
  warn "没有发现任何 .pkg.tar.* —— workflow 把 packages 产物拷丢了？"
else
  log "安装 liuqin 设备包（${#pkgs[@]} 个）："
  printf '%s\n' "${pkgs[@]##*/}" | sed 's/^/    /'
  # -dd：跳过依赖检查（跨发行版底包必然缺我们声明之外的元数据）
  # --overwrite '*': Frame 底包已带同名文件（如 NetworkManager drop-in）时强制覆盖
  if pacman -U --noconfirm -dd --overwrite '*' "${pkgs[@]}" >/tmp/liuqin-pac.log 2>&1; then
    log "设备包安装完成"
  else
    warn "pacman -U 有报错，尾部日志："
    tail -30 /tmp/liuqin-pac.log | sed 's/^/    /'
    warn "继续执行（depmod 与后续修复仍会跑）"
  fi
  # 电源菜单（liuqin-power-menu）依赖 zenity，KDE 底包通常没有；尽力补装，失败只告警
  pacman -S --noconfirm --needed zenity >/dev/null 2>&1 \
    && log "已补装 zenity（电源菜单）" \
    || warn "zenity 装不上，电源菜单可能不可用（电源键长短按仍由 daemon 处理）"
fi

# 3.5) 内核模块：把 boot.img 同批构建的模块树解进 /
KMT="${KERNEL_MODULES_TAR:-/tmp/kernel-modules.tar.gz}"
if [[ -s "$KMT" ]]; then
  tar -xzf "$KMT" -C / 2>/dev/null || warn "内核模块解包失败"
  # depmod -a 处理所有版本目录（Frame 残留目录一并重建索引，避免选错版本）
  if depmod -a >/tmp/liuqin-depmod.log 2>&1; then
    KVER="$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
    log "depmod -a 完成；最高版本目录: ${KVER:-无}"
  else
    warn "depmod -a 失败（不阻塞构建；日志尾部见下，若提示工具缺失请确认 workflow 已跑工具链自检/重装）"
    tail -10 /tmp/liuqin-depmod.log 2>/dev/null | sed 's/^/    /' 2>/dev/null || true
  fi
else
  warn "缺少 $KMT —— 模块没装，depmod 跳过"
fi

# 4) fstab：根分区用 PARTLABEL（与 boot.img 的 cmdline root=PARTLABEL=<label> 一致）
#    ⚠️ 不要照抄 sheng 写死的 /dev/sda30：liuqin 的 UFS 盘号/分区号不保证一致。
#    独立的 home 分区（PARTLABEL=home）可选：有就挂、没有 nofail 照常启动（/home 留在 root 里）。
cat > /etc/fstab <<EOF
# 由 10-graft-liuqin.sh 生成（SteamOS for liuqin）
# root=PARTLABEL=$PARTLABEL 由 boot.img 的 cmdline 指定，这里保持同步；
# x-systemd.growfs 让 rootfs 首启自动扩到分区实际大小。
PARTLABEL=$PARTLABEL  /  ext4  defaults,x-systemd.growfs  0  1
PARTLABEL=home        /home ext4  nofail,noatime        0  2
EOF
log "已写 /etc/fstab（root=PARTLABEL=$PARTLABEL，home 可选）"

# 5) 基本系统配置
if [[ -e /usr/share/zoneinfo/Asia/Shanghai ]]; then
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
fi
if ! grep -q '^en_US.UTF-8' /etc/locale.gen 2>/dev/null; then
  printf 'en_US.UTF-8 UTF-8\n' >> /etc/locale.gen
fi
locale-gen >/dev/null 2>&1 || true
log "时区/locale 已配置"

# 5.5) /var 骨架：Frame 的 /var 可能在独立子卷（var-A）里，若没并进来就是空的。
#      systemd 首启会用 tmpfiles 补一部分，但 pacman 数据库、DBus、日志目录得先在。
install -d /var/lib/pacman /var/lib/dbus /var/log/journal /var/lib/systemd
log "/var 骨架已补齐（pacman/dbus/systemd/log 目录）"

# 5.9) 停掉「按 Frame 分区表挂载」的单元 + GPT 自动挂载生成器
#      症状（实机）：屏幕亮了但一直卡在等待 home 分区 —— systemd 在等
#      dev-disk-by-partlabel-home.device，而设备上只有 userdata/linux_root。
#      做法：① 把设备型 .mount/.automount 屏蔽（按 What= 指向设备 的通用规则）
#            ② 兜底屏蔽名字含 home/var/boot/esp/efi 的单元
#            ③ 停用 systemd-gpt-auto-generator
log "所有 mount/automount 单元文件："
find /usr/lib/systemd/system /etc/systemd/system -maxdepth 1 \
  \( -name '*.mount' -o -name '*.automount' \) 2>/dev/null | sort | sed 's/^/    /' || true

masked=0
while IFS= read -r u; do
  [[ -n "$u" ]] || continue
  base="$(basename "$u")"
  # 读真实文件内容（软链要跟到真文件）
  real="$(readlink -f "$u")"
  [[ -f "$real" ]] || continue
  if grep -qE '^\s*What=\s*(/dev/|PARTLABEL=|LABEL=|UUID=|/dev/disk/)' "$real" 2>/dev/null; then
    ln -sf /dev/null "/etc/systemd/system/$base"
    rm -f "/etc/systemd/system/multi-user.target.wants/$base" 2>/dev/null || true
    masked=$((masked + 1))
  fi
done < <(find /usr/lib/systemd/system /etc/systemd/system -maxdepth 1 \( -name '*.mount' -o -name '*.automount' \) 2>/dev/null)
for base in home.mount var.mount boot.mount esp.mount efi.mount \
            'home\x2d.mount' 'var\x2d.mount' 'boot\x2d.mount' 'esp\x2d.mount'; do
  ln -sf /dev/null "/etc/systemd/system/$base" 2>/dev/null || true
done
masked=$((masked + 6))
log "已屏蔽 $masked 个设备型/Frame 挂载单元"

# Valve partset + adbd gadget：SteamOS 用 /dev/disk/by-partset/<组>/<名> 指代分区，
# liuqin 的分区表里没有 shared/home、shared/offload → 设备永远不出现；
# adbd（Android USB gadget）在平板上无人应答，会以 no limit 卡住启动。
for u in $(find /usr/lib/systemd/system /etc/systemd/system -maxdepth 1 \
  \( -iname '*partset*' -o -iname '*adbd*' -o -iname '*adb*' -o -iname '*gadget*' -o -iname '*ffs*' \) 2>/dev/null | sort); do
  base="$(basename "$u")"
  ln -sf /dev/null "/etc/systemd/system/$base"
  log "已屏蔽 $base（Valve partset / adbd gadget）"
done

# 5.97) Deckard(Steam Frame) 专有硬件服务 + repart + v4l2loopback
#   repart **必须**屏蔽：systemd-repart 会按 Valve 分区表改磁盘，在 Android 分区表上风险很高。
systemctl mask systemd-repart.service 2>/dev/null || true
rm -rf /etc/repart.d /usr/lib/repart.d /usr/lib/systemd/repart.d 2>/dev/null || true
for u in $(find /usr/lib/systemd/system /etc/systemd/system -maxdepth 1 \
  \( -iname '*deckard*' -o -iname '*fpga*' -o -iname '*v4l2loopback*' -o -iname '*steamvr*' \) 2>/dev/null | sort); do
  base="$(basename "$u")"
  ln -sf /dev/null "/etc/systemd/system/$base" 2>/dev/null || true
  log "已屏蔽 $base（Frame 专有硬件/v4l2loopback/SteamVR）"
done
log "已屏蔽 systemd-repart + repart.d（防改分区表）"

# 5.98) D-Bus 的 messagebus 用户/组 —— 实测 dbus-broker-launch 缺它时 5ms 退出 → 无系统总线 → 黑屏
if ! getent passwd messagebus >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/dbus --no-create-home --shell /usr/sbin/nologin messagebus 2>/dev/null || true
fi
if ! getent group messagebus >/dev/null 2>&1; then
  groupadd --system messagebus 2>/dev/null || true
fi
log "messagebus: $(getent passwd messagebus || echo '仍不存在 ✗')"

# 6) 服务：桌面会话（Frame 底包默认会话走 gamescope openvr 后端 → 平板黑帧，
#    必须 SDDM 直连 Plasma；与 Ubuntu 镜像同一条已验证路径）
if [[ -x /usr/bin/startplasma-wayland ]]; then
  install -d /usr/share/wayland-sessions
  cat > /usr/share/wayland-sessions/plasma-liuqin.desktop <<'EOF'
[Desktop Entry]
Name=Plasma (Wayland, liuqin)
Comment=Start Plasma Wayland directly (no gamescope; the Frame gamescope session targets a VR headset)
Exec=/usr/lib/steamos/liuqin-startplasma
TryExec=/usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF
  install -d /etc/sddm.conf.d
  cat > /etc/sddm.conf.d/zz-liuqin.conf <<'EOF'
[Autologin]
Session=plasma-liuqin.desktop
User=steamos
EOF
  log "已创建 Plasma 直连会话并让 SDDM 自动登录（出桌面的关键）"
else
  warn "没有 startplasma-wayland，保持底包默认会话（很可能是 gamescope/VR，平板上会黑）"
fi

# 登录用户家目录：底包 /home 在 Valve shared/home 分区上（已屏蔽挂载），
# /home 落在根分区；底包 /home 是空的 → 家目录不存在 → SDDM/PAM 登录失败。
# steamos-create-homedir.service 首启会建，这里先建好双保险。
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1":"$3":"$4":"$6}' /etc/passwd 2>/dev/null); do
  un="${u%%:*}"; rest="${u#*:}"; uid_="${rest%%:*}"; rest="${rest#*:}"
  gid_="${rest%%:*}"; home_="${rest#*:}"
  [[ -n "$home_" && "$home_" != "/" ]] || continue
  if [[ ! -d "$home_" ]]; then
    install -d -o "$uid_" -g "$gid_" "$home_" 2>/dev/null \
      && log "已建家目录 $home_（$un）" || true
  fi
done
log "用户列表：$(awk -F: '$3>=1000 && $3<65534 {printf "%s ", $1}' /etc/passwd)"

systemctl enable steamos-manager.service 2>/dev/null \
  && log "已启用 steamos-manager.service（系统侧）" || warn "启用 steamos-manager.service 失败"
install -d /etc/systemd/system/sddm.service.d
cat > /etc/systemd/system/sddm.service.d/after-steamos-manager.conf <<'EOF'
[Unit]
Wants=steamos-manager.service
After=steamos-manager.service
EOF
if [[ -f /usr/lib/steamos/gamescope-session ]]; then
  sed -i 's/--backend openvr/--backend drm/' /usr/lib/steamos/gamescope-session \
    && log "gamescope 后端已从 openvr 改为 drm（平板屏）"
fi
install -d /etc/systemd/user
ln -sf /dev/null /etc/systemd/user/steamvr-logs.service 2>/dev/null || true

# 7) 无人值守配置：WiFi keyfile / root 密码 / sshd
#    无线只交给 NetworkManager 一套管（两套管理器抢接口的教训见 sheng 原脚本注释）
WIFI_SSID="${WIFI_SSID:-}"; WIFI_PSK="${WIFI_PSK:-}"; ROOT_PW="${ROOT_PW:-}"
if [[ -n "$WIFI_SSID" && -n "$WIFI_PSK" ]]; then
  install -d -m 755 /etc/NetworkManager/system-connections
  NM_FILE="/etc/NetworkManager/system-connections/liuqin-wifi.nmconnection"
  NM_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo liuqin-wifi-uuid)"
  cat > "$NM_FILE" <<EOF
[connection]
id=$WIFI_SSID
uuid=$NM_UUID
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  chmod 600 "$NM_FILE"; chown 0:0 "$NM_FILE"
  log "已写入 NM 连接（SSID=$WIFI_SSID）"
else
  log "未提供 WiFi 凭据，跳过预配（开机用 nmcli 连）"
fi
systemctl enable NetworkManager.service 2>/dev/null && log "已启用 NetworkManager.service" || warn "启用 NetworkManager 失败"
for u in wpa_supplicant@.service dhcpcd@.service; do
  [[ -e "/usr/lib/systemd/system/$u" ]] || continue
  systemctl disable "$u" >/dev/null 2>&1 || true
  ln -sf /dev/null "/etc/systemd/system/$u" && log "已屏蔽 $u（网络统一交给 NetworkManager）"
done
if systemctl is-enabled systemd-networkd.service >/dev/null 2>&1; then
  systemctl disable systemd-networkd.service >/dev/null 2>&1 \
    && log "已停用 systemd-networkd" || true
fi
if [[ -L /etc/resolv.conf ]]; then
  log "/etc/resolv.conf 是软链（systemd-resolved），DNS 交给 NetworkManager"
else
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
if command -v sshd >/dev/null 2>&1; then
  mkdir -p /run/sshd
  ssh-keygen -A 2>/dev/null || true
  sed -i -E 's/^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication)/# \1/I' /etc/ssh/sshd_config 2>/dev/null || true
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' >> /etc/ssh/sshd_config
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-liuqin.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
  sshd -t 2>/dev/null && log "sshd 配置语法检查通过 ✓" || warn "sshd -t 报错"
  systemctl enable sshd.service 2>/dev/null && log "已启用 sshd" || warn "启用 sshd 失败"
else
  warn "底包没有 sshd，SSH 不可用"
fi
if [[ -e /usr/bin/dbus-broker-launch ]]; then
  mkdir -p /etc/systemd/system/dbus-broker.service.d
  cat > /etc/systemd/system/dbus-broker.service.d/no-audit.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dbus-broker-launch --scope system
EOF
  log "已给 dbus-broker 加 drop-in：去掉 --audit"
fi

# 8) 关键系统修复（每条都是设备上实测出来的）
#  ① D-Bus：dbus-broker 在这套底包上起不来，换 dbus-daemon（logind 必须在总线之后
#    启动才能占住 org.freedesktop.login1；占不到 → pam_systemd 建会话失败 → 黑屏/登录被拒）
if [[ -e /usr/bin/dbus-daemon ]]; then
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/dbus.service <<'EOF'
[Unit]
Description=System Message Bus (liuqin: dbus-daemon)
Documentation=man:dbus-daemon(1)
DefaultDependencies=no
After=local-fs.target
Before=basic.target systemd-logind.service
Sockets=dbus.socket
[Service]
Type=notify
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile --systemd-activation
ExecReload=/bin/kill -HUP $MAINPID
[Install]
WantedBy=sysinit.target
EOF
  systemctl mask dbus-broker.service 2>/dev/null || true
  systemctl enable dbus.socket 2>/dev/null && log "已启用 dbus.socket" || warn "启用 dbus.socket 失败"
  systemctl enable dbus.service 2>/dev/null && log "dbus.service 已挂到 sysinit.target（早于 logind）" || warn "启用 dbus.service 失败"
fi
#  ② machine-id：空文件让 journald 不落盘（故障时看不到日志）
if [[ ! -s /etc/machine-id ]]; then
  systemd-machine-id-setup >/dev/null 2>&1 || true
  if [[ ! -s /etc/machine-id ]]; then
    tr -dc 'a-f0-9' < /dev/urandom | head -c 32 > /etc/machine-id
  fi
  log "已生成 machine-id"
fi
#  ③ hostname：不能用构建机的（chroot 里 hostname 是 runner 名字）
echo "xiaomi-liuqin" > /etc/hostname
grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null || echo "127.0.1.1 xiaomi-liuqin" >> /etc/hosts
log "hostname 已固定为 xiaomi-liuqin"
#  ④ root 密码：sha512 哈希直接落盘（chpasswd 在设备上实测没生效）
if [[ -n "$ROOT_PW" ]] && command -v openssl >/dev/null 2>&1; then
  H="$(openssl passwd -6 "$ROOT_PW" 2>/dev/null || true)"
  if [[ -n "$H" ]]; then
    sed -i "s|^root:[^:]*:|root:$H:|" /etc/shadow && log "root 密码已写入 /etc/shadow（sha512）"
  fi
fi
#  ⑤ SSH 公钥：最稳的登录入口
if [[ -n "${SSH_PUBKEY:-}" ]]; then
  mkdir -p /root/.ssh
  printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys
  chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; chown -R 0:0 /root/.ssh
  log "SSH 公钥已写入 /root/.ssh/authorized_keys"
fi
#  ⑥ PAM：关掉 pam_systemd_home（homed 不用；它失败会让所有认证方式被拒）
if [[ -d /etc/pam.d ]]; then
  pamn=0
  for f in /etc/pam.d/*; do
    [[ -f "$f" ]] || continue
    if grep -q 'pam_systemd_home' "$f" 2>/dev/null; then
      sed -i 's/^\([^#].*pam_systemd_home.*\)/#\1/' "$f" && pamn=$((pamn + 1))
    fi
  done
  log "已注释 $pamn 个 pam 文件里的 pam_systemd_home"
fi

# 9) liuqin 设备服务（enable 项 / 条件项分开；对照 xiaomipad 项目的单元定义逐条核对）
#    ① 固定 UFS 根的关键：uinput 在 liuqin 内核里是 =y（无需 modules-load.d），
#      但写一份无害兜底（万一以后换回 =m）
install -d /etc/modules-load.d
echo uinput > /etc/modules-load.d/uinput.conf

enable_unit() {
  local u="$1" why="$2"
  if [[ -f "/usr/lib/systemd/system/$u" ]]; then
    systemctl enable "$u" >/dev/null 2>&1 && log "已启用 $u（$why）" || warn "启用 $u 失败（$why）"
  else
    warn "缺 $u（$why）—— 对应的设备包没装上？"
  fi
}

# 显式 enable 的（有 [Install] 且无人代拉）：
enable_unit liuqin-power-keyd.service       "电源键（短按菜单/长按动作）"
enable_unit liuqin-backlight-default.service "背光默认值（进桌面前置位）"
enable_unit liuqin-hide-gunyah-node.service "屏蔽 hypervisor 节点（有该节点时才生效）"

# 靠其它单元/udev 拉起、不该 enable 的（写在这防止以后乱加）：
#   liuqin-wlan-mac.service      ← NetworkManager.service.d Requires（网络前置）
#   liuqin-bt-preconfigure.service ← bluetooth.service.d Requires
#   liuqin-mipps-auth.service    ← 90-liuqin-mipps-auth.rules 的 SYSTEMD_WANTS
#   liuqin-charger-mode           ← 上游是 initramfs stage-1 状态机，本镜像无 initramfs 不启用
#   liuqin-mark-slot-successful  ← 双系统槽位标记，布局未全量验证，不启用
#   liuqin-uinput-automation     ← 开发/自动化工具，不启用
#   liuqin-gnome-*               ← GNOME 专用（storage-guard/usb-rescue/snap-root），不需要

# WLAN MAC / BT 地址依赖<b>本机 persist</b>提取的私有状态（出厂数据，不可跨机分发）。
# 未预配时服务会因状态缺失失败；用 ConditionPathExists 让它们跳过（systemd 对条件失败
# 的单元不视为失败，Requires 方照常启动），设备主人补好状态后重启即生效。
install -d /etc/systemd/system/liuqin-wlan-mac.service.d
cat > /etc/systemd/system/liuqin-wlan-mac.service.d/30-liuqin-wlan-mac-cond.conf <<'EOF'
[Unit]
ConditionPathExists=/var/lib/liuqin-private/wlan-mac
EOF
install -d /etc/systemd/system/liuqin-bt-preconfigure.service.d
cat > /etc/systemd/system/liuqin-bt-preconfigure.service.d/30-liuqin-bt-cond.conf <<'EOF'
[Unit]
ConditionPathExists=/var/lib/liuqin-private/bluetooth-address
EOF
log "wlan-mac / bt-preconfigure 已加条件（有私有状态才跑）"

# ② 安装结果自检：关键文件少一个就告警
missing=0
for f in /usr/local/libexec/liuqin-power-keyd \
         /usr/lib/systemd/system/liuqin-power-keyd.service \
         /usr/local/sbin/liuqin-wlan-mac \
         /usr/local/sbin/liuqin-bt-public-addr \
         /usr/local/libexec/liuqin-backlight-default \
         /usr/local/libexec/liuqin-mipps-auth \
         /usr/lib/firmware/qcom/sm8475/liuqin/adsp.b08 \
         /usr/lib/firmware/ath11k/WCN6855/hw2.0/board-2.bin.zst \
         /usr/lib/firmware/qcom/sm8475/Xiaomi-Pad-6-Pro-tplg.bin \
         /usr/share/alsa/ucm2/conf.d/sm8450/Xiaomi-Pad-6-Pro.conf; do
  if [[ -e "$f" ]]; then
    log "  ✓ $f"
  else
    warn "  ✗ 缺 $f"
    missing=$((missing + 1))
  fi
done
[[ "$missing" -eq 0 ]] || warn "有 $missing 个关键文件缺失 —— 设备包里少装了东西"

# 依赖体检（不致命，只报告）
log "依赖体检（pacman -Dk）："
pacman -Dk 2>&1 | grep -v '^checking' | sed 's/^/    /' | head -30 || true

# 10) SteamOS-on-SM8550 通用修复（Frame 底包给 VR 头显写的，平板必须改）
#     全部移植自 MaSieS4Fun/SteamOS-ARM-SM8550 + Steamos-xiaomi-sheng 的实机验证。

# 10.1 VARIANT_ID=vr → steamdeck（否则 Gamepad UI throws）
_vfix=0
for _osr in /etc/os-release /usr/lib/os-release /var/lib/overlays/etc/upper/os-release; do
  [[ -f "$_osr" ]] || continue
  grep -q '^VARIANT_ID=' "$_osr" || continue
  sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr" && _vfix=$((_vfix + 1))
done
log "VARIANT_ID 已改成 steamdeck（$_vfix 个副本）"

# 10.2 无线后端钉死在 wpa_supplicant + 关省电（Steam/steamos-manager 会改写成 iwd → 掉线）
install -d /etc/NetworkManager/conf.d /usr/lib/NetworkManager/conf.d /usr/lib/steamos
cat > /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf <<'EOF'
[connection]
wifi.powersave=2
[device]
wifi.backend=wpa_supplicant
EOF
cp -f /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf \
      /usr/lib/NetworkManager/conf.d/40-liuqin-wifi.conf
cat > /usr/lib/steamos/liuqin-wifi-backend <<'EOF'
#!/bin/bash
# 把 NetworkManager 的无线后端钉回 wpa_supplicant。Steam / steamos-manager 会把这个
# fragment 改写成 iwd（平板上用不了/会抖），所以需要一直被改回来。
# ⚠️ 不要 nmcli connect/reconnect：会让 wlan0 反复抖动，Steam 卡在载入圈。
set -u
BODY='[connection]
wifi.powersave=2
[device]
wifi.backend=wpa_supplicant
'
write_one() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s <(printf '%s' "$BODY") "$dest"; then
    chown root:root "$dest" 2>/dev/null || true
    chmod 0644 "$dest" 2>/dev/null || true
    return 0
  fi
  printf '%s' "$BODY" >"$dest"
  chown root:root "$dest" 2>/dev/null || true
  chmod 0644 "$dest"
}
write_one /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf
[[ -d /var/lib/overlays/etc/upper ]] && \
  write_one /var/lib/overlays/etc/upper/NetworkManager/conf.d/99-valve-wifi-backend.conf
[[ -d /usr/lib/NetworkManager/conf.d ]] && \
  write_one /usr/lib/NetworkManager/conf.d/40-liuqin-wifi.conf
ln -sfn /dev/null /etc/systemd/system/iwd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/iwd.service 2>/dev/null || true
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/NetworkManager.service.wants
if [[ -f /usr/lib/systemd/system/wpa_supplicant.service ]]; then
  ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
    /etc/systemd/system/multi-user.target.wants/wpa_supplicant.service
  ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
    /etc/systemd/system/NetworkManager.service.wants/wpa_supplicant.service
fi
rfkill unblock wifi bluetooth 2>/dev/null || true
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-wifi-backend
cat > /usr/lib/systemd/system/liuqin-wifi-backend.service <<'EOF'
[Unit]
Description=liuqin: 把 NetworkManager 无线后端钉回 wpa_supplicant
DefaultDependencies=no
After=local-fs.target
Before=NetworkManager.service iwd.service
Wants=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/lib/steamos/liuqin-wifi-backend
[Install]
WantedBy=NetworkManager.service
WantedBy=multi-user.target
EOF
cat > /usr/lib/systemd/system/liuqin-wifi-backend.timer <<'EOF'
[Unit]
Description=liuqin: 周期性把无线后端钉回 wpa_supplicant
After=local-fs.target
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=liuqin-wifi-backend.service
[Install]
WantedBy=timers.target
EOF
systemctl enable liuqin-wifi-backend.service liuqin-wifi-backend.timer 2>/dev/null \
  && log "已启用 liuqin-wifi-backend（service + 60s timer 兜底）" || warn "启用 wifi-backend 失败"

# 10.3 无线接口名固定成 wlan0（Frame/Steam 找 wlan0）
install -d /usr/lib/systemd/network
cat > /usr/lib/systemd/network/99-liuqin-wlan0.link <<'EOF'
[Match]
Type=wlan
[Link]
Name=wlan0
EOF
log "已固定无线接口名为 wlan0（.link）"

# 10.4 SteamVR / iwd / set-wifi-mac-address 一律屏蔽
install -d /etc/systemd/user /etc/systemd/system
for u in steamvr.service steamvr-logs.service steamvr-proxmicmute.service \
         steamvr-v4l2cam.service steamvr-nested-desktop.service; do
  ln -sfn /dev/null "/etc/systemd/user/$u" 2>/dev/null || true
done
for u in steamvr-program-ble.service steamvr-v4l2loopback.service \
         steamvr-set-kernel-thread-priorities.service \
         set-wifi-mac-address.service iwd.service; do
  ln -sfn /dev/null "/etc/systemd/system/$u" 2>/dev/null || true
done
log "已屏蔽 SteamVR 全家桶 / iwd / set-wifi-mac-address"

# 10.5 Plasma Wayland 环境清理（gamescope 残留的 Qt/X11 环境会把 Plasma 带沟里）
cat > /usr/lib/steamos/liuqin-prepare-plasma <<'EOF'
#!/bin/bash
set -u
[[ -d /tmp/.X11-unix ]] || mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
unset QT_QPA_PLATFORM GAMESCOPE_WAYLAND_DISPLAY GAMESCOPE_SESSION_TARGET
export QT_QPA_PLATFORM=wayland
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
export DESKTOP_SESSION=plasma
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user unset-environment \
    QT_QPA_PLATFORM GAMESCOPE_WAYLAND_DISPLAY GAMESCOPE_SESSION_TARGET \
    XDG_DESKTOP_PORTAL_DIR || true
  systemctl --user set-environment \
    QT_QPA_PLATFORM=wayland XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE DESKTOP_SESSION=plasma || true
fi
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  dbus-update-activation-environment --systemd \
    QT_QPA_PLATFORM XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
    XDG_SESSION_DESKTOP DESKTOP_SESSION >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-prepare-plasma
cat > /usr/lib/steamos/liuqin-startplasma <<'EOF'
#!/bin/bash
/usr/lib/steamos/liuqin-prepare-plasma
exec /usr/bin/startplasma-wayland "$@"
EOF
chmod 0755 /usr/lib/steamos/liuqin-startplasma
cat > /usr/lib/systemd/user/liuqin-plasma-env.service <<'EOF'
[Unit]
Description=liuqin: Plasma Wayland 环境清理
DefaultDependencies=no
Before=plasma-core.target plasma-workspace.target plasma-workspace-wayland.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos/liuqin-prepare-plasma
EOF
cat > /usr/lib/steamos/liuqin-plasma-wayland.conf <<'EOF'
[Service]
Environment=QT_QPA_PLATFORM=wayland
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_CURRENT_DESKTOP=KDE
Environment=XDG_SESSION_DESKTOP=KDE
UnsetEnvironment=GAMESCOPE_WAYLAND_DISPLAY
EOF
plasma_n=0
for svc in plasma-plasmashell plasma-ksplash plasma-ksmserver plasma-kcminit plasma-kcminit-phase1 \
           plasma-kded6 plasma-kwin_wayland plasma-gmenudbusmenuproxy plasma-xembedsniproxy \
           plasma-kaccess plasma-powerdevil plasma-polkit-agent plasma-kglobalaccel plasma-kscreen \
           plasma-xdg-desktop-portal-kde plasma-krunner plasma-kactivitymanagerd plasma-dolphin \
           plasma-ksystemstats plasma-restoresession plasma-baloorunner; do
  install -d "/usr/lib/systemd/user/${svc}.service.d"
  cp -f /usr/lib/steamos/liuqin-plasma-wayland.conf \
        "/usr/lib/systemd/user/${svc}.service.d/99-liuqin-wayland.conf"
  plasma_n=$((plasma_n + 1))
done
log "已给 $plasma_n 个 plasma-* user 单元装上 Wayland 环境 drop-in"

# 10.6 gamescope 会话（游戏模式）：摘掉 SteamVR 耦合 + 强制内屏
install -d /usr/lib/systemd/user/gamescope-session.service.d \
           /usr/lib/systemd/user/gamescope-session.target.d
_icd=""
for _c in /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
          /usr/share/vulkan/icd.d/freedreno_icd.json; do
  [[ -f "$_c" ]] && { _icd="$_c"; break; }
done
{
  echo '[Unit]'
  echo 'Description=Gamescope liuqin session'
  echo 'PartOf='
  echo 'PartOf=graphical-session.target'
  echo ''
  echo '[Service]'
  echo 'TimeoutStartSec=45'
  echo 'Environment=GAMESCOPE_FORCE_INTERNAL=1'
  if [[ -n "$_icd" ]]; then
    echo "Environment=VK_ICD_FILENAMES=$_icd"
    echo "Environment=VK_DRIVER_FILES=$_icd"
  fi
} > /usr/lib/systemd/user/gamescope-session.service.d/99-liuqin.conf
cat > /usr/lib/systemd/user/gamescope-session.target.d/99-liuqin.conf <<'EOF'
[Unit]
Description=Gamescope liuqin session
Wants=
Wants=steam.service
Wants=steam-notif-daemon.service
Wants=ibus-gamescope.service
EOF
log "gamescope 会话已解耦 SteamVR（Vulkan ICD: ${_icd:-未探测到，跳过}）"

# 10.7 jupiter-dock-updater 桩（平板没有 Valve Dock；缺失会让 Steam 报更新错误）
if [[ ! -e /usr/bin/jupiter-dock-updater ]]; then
  cat > /usr/bin/jupiter-dock-updater <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FW_VER="0.13.15.124"
for arg in "$@"; do
  case "$arg" in
    --check) echo "FW Current: ${FW_VER}"; echo "FW Available: ${FW_VER}"; echo "FW up to date"; exit 7 ;;
  esac
done
exit 0
EOF
  chmod 0755 /usr/bin/jupiter-dock-updater
  install -d /usr/bin/steamos-polkit-helpers
  ln -sfn /usr/bin/jupiter-dock-updater /usr/bin/steamos-polkit-helpers/jupiter-dock-updater
  log "已放入 jupiter-dock-updater 桩"
fi

# 10.8 独立 home 分区：首启格式化 → 扩分区 → 扩文件系统 → 重建家目录
#     liuqin 版：不写死 /dev/sdaXX，只按 PARTLABEL=home 找（sheng 的 /dev/sda30 教训）。
cat > /usr/lib/steamos/liuqin-expand-home <<'EOF'
#!/bin/bash
set -u
STAMP=/var/lib/liuqin/home-ready
LOG=/var/log/liuqin-expand-home.log
mkdir -p "$(dirname "$STAMP")" /var/log
exec >>"$LOG" 2>&1
ts() { date -Iseconds; }
log() { printf '%s %s\n' "$(ts)" "$*"; }
log "=== expand-home start ==="
[[ -f "$STAMP" ]] && { log "已有标记，跳过"; exit 0; }
HOME_SRC=""
for _i in $(seq 1 30); do
  for c in /dev/disk/by-partlabel/home /dev/disk/by-label/home; do
    [[ -b "$c" ]] && { HOME_SRC="$(readlink -f "$c")"; break 2; }
  done
  sleep 0.5
done
[[ -n "$HOME_SRC" ]] || { log "没有 home 分区，下次再看"; exit 0; }
log "home 分区: $HOME_SRC"
FSTYPE="$(blkid -o value -s TYPE "$HOME_SRC" 2>/dev/null || true)"
if [[ -z "$FSTYPE" ]]; then
  log "分区空白 → mkfs.ext4 -L home"
  mkfs.ext4 -F -L home -m 1 "$HOME_SRC" || { log "mkfs 失败，下次重试"; exit 0; }
  FSTYPE=ext4
fi
case "$FSTYPE" in
  ext2|ext3|ext4) ;;
  *) log "home 文件系统是 $FSTYPE，不动它"; exit 0 ;;
esac
if ! mountpoint -q /home; then
  systemctl restart home.mount 2>/dev/null || true
  sleep 0.5
fi
mountpoint -q /home || { mount "$HOME_SRC" /home 2>/dev/null || mount /home 2>/dev/null || true; }
if mountpoint -q /home; then
  log "/home 已挂载（$(findmnt -no SOURCE /home 2>/dev/null)）"
else
  log "警告：/home 仍未挂载 —— 本次不打完成标记，下次启动重试"
fi
PART_BASE="$(basename "$HOME_SRC")"
PART_NUM="$(cat "/sys/class/block/${PART_BASE}/partition" 2>/dev/null || true)"
DISK_NAME="$(lsblk -no PKNAME "$HOME_SRC" 2>/dev/null | head -1 || true)"
if [[ -n "$DISK_NAME" && -n "$PART_NUM" ]]; then
  if command -v growpart >/dev/null 2>&1; then
    growpart "/dev/${DISK_NAME}" "$PART_NUM" 2>&1 || log "growpart 非 0（多半已经是最大）"
  else
    echo ", +" | sfdisk --no-reread -N "$PART_NUM" "/dev/${DISK_NAME}" 2>&1 || true
  fi
  udevadm settle 2>/dev/null || true
  partx -u "/dev/${DISK_NAME}" 2>/dev/null || true
  sleep 0.2
fi
resize2fs "$HOME_SRC" 2>&1 || log "resize2fs 非 0（Nothing to do 属正常）"
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1":"$3":"$4":"$6}' /etc/passwd 2>/dev/null); do
  un="${u%%:*}"; rest="${u#*:}"; uid_="${rest%%:*}"; rest="${rest#*:}"
  gid_="${rest%%:*}"; home_="${rest#*:}"
  [[ -n "$home_" && "$home_" != "/" ]] || continue
  if [[ ! -d "$home_" ]]; then
    mkdir -p "$home_" && chown "$uid_:$gid_" "$home_" && chmod 0755 "$home_" \
      && log "已建家目录 $home_（$un）"
  fi
done
PART_START="$(cat "/sys/class/block/${PART_BASE}/start" 2>/dev/null || echo '')"
PART_SECTORS="$(cat "/sys/class/block/${PART_BASE}/size" 2>/dev/null || echo '')"
DISK_SECTORS="$(cat "/sys/class/block/${DISK_NAME}/size" 2>/dev/null || echo '')"
if [[ -n "$PART_START" && -n "$PART_SECTORS" && -n "$DISK_SECTORS" ]] \
   && (( PART_START + PART_SECTORS + 2048 < DISK_SECTORS )); then
  log "分区尚未铺满磁盘 —— 不打完成标记，下次启动继续。"
  exit 0
fi
if ! mountpoint -q /home; then
  log "/home 没挂上，不打完成标记，下次启动重试"
  exit 0
fi
touch "$STAMP"
log "=== expand-home done ==="
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-expand-home
cat > /usr/lib/systemd/system/liuqin-expand-home.service <<'EOF'
[Unit]
Description=liuqin: 独立 home 分区首启准备与扩容
DefaultDependencies=no
Conflicts=shutdown.target
After=systemd-remount-fs.service
After=home.mount
Before=display-manager.service graphical.target
ConditionPathExists=!/var/lib/liuqin/home-ready
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos/liuqin-expand-home
TimeoutStartSec=180
[Install]
WantedBy=local-fs.target
WantedBy=multi-user.target
EOF
systemctl enable liuqin-expand-home.service 2>/dev/null \
  && log "已启用 liuqin-expand-home（有 home 分区就自动格式化+扩容）" \
  || warn "启用 liuqin-expand-home 失败"

# 11) Steam / 会话集成（同一份 Frame 底包的修复）

# 11.1 权限修复：pkexec/sudo/dbus-daemon-launch-helper 的 setuid 位（镜像拷贝会丢位）
cat > /usr/lib/steamos/liuqin-restore-privs <<'EOF'
#!/bin/bash
set -uo pipefail
log() { printf 'liuqin-restore-privs: %s\n' "$*"; }
fix_suid() {
  local path="$1" mode="${2:-4755}" owner="${3:-root:root}"
  [[ -e "$path" ]] || return 0
  chown "$owner" "$path" 2>/dev/null || return 0
  chmod "$mode" "$path" 2>/dev/null || return 0
  log "fixed $path ($mode $owner)"
}
fix_suid /usr/bin/pkexec 4755 root:root
fix_suid /usr/bin/sudo 4755 root:root
fix_suid /usr/lib/polkit-1/polkit-agent-helper-1 4755 root:root
fix_suid /usr/bin/su 4755 root:root
fix_suid /usr/bin/passwd 4755 root:root
fix_suid /usr/bin/newgrp 4755 root:root
fix_suid /usr/bin/chsh 4755 root:root
fix_suid /usr/bin/chfn 4755 root:root
fix_suid /usr/bin/gpasswd 4755 root:root
fix_suid /usr/bin/unix_chkpwd 4755 root:root
fix_suid /usr/bin/mount 4755 root:root
fix_suid /usr/bin/umount 4755 root:root
if getent group dbus >/dev/null 2>&1; then
  fix_suid /usr/lib/dbus-1.0/dbus-daemon-launch-helper 4750 root:dbus
else
  fix_suid /usr/lib/dbus-1.0/dbus-daemon-launch-helper 4750 root:root
fi
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-restore-privs
cat > /usr/lib/systemd/system/liuqin-restore-privs.service <<'EOF'
[Unit]
Description=liuqin: 恢复 pkexec/sudo 等程序的 setuid 位
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service polkit.service sudo.service multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/lib/steamos/liuqin-restore-privs
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
bash /usr/lib/steamos/liuqin-restore-privs 2>&1 | sed 's/^/    /' || true
systemctl enable liuqin-restore-privs.service 2>/dev/null \
  && log "已启用 liuqin-restore-privs（并已在构建期执行一次）" || warn "启用 restore-privs 失败"

# 11.2 steamvr 桩：RUNSTEAM / steam-health-check 会调用 `steamvr`，平板上不该真连 OpenVR
install -d /usr/lib/steamos/liuqin-bin
cat > /usr/lib/steamos/liuqin-bin/steamvr <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-bin/steamvr

# 11.3 steam-health-check 替换：官方那个会在几次短会话后重新解 steam.tar.zst 并抹掉客户端
if [[ -e /usr/share/deckard/steam-health-check ]]; then
  cp -f /usr/share/deckard/steam-health-check /usr/share/deckard/steam-health-check.stock 2>/dev/null || true
  cat > /usr/share/deckard/steam-health-check <<'EOF'
#!/bin/bash
set +e
TRIPLEFROG_FILE="${XDG_RUNTIME_DIR:-/tmp}/steam-short-session-tracker"
STEAMROOT="${HOME}/.local/share/Steam"
mkdir -p "${STEAMROOT}" 2>/dev/null || true
case "${1:-}" in
  --track-started)
    touch "${TRIPLEFROG_FILE}"; touch "${STEAMROOT}/.install-complete"; rm -f "${STEAMROOT}/.crash" ;;
  --track-stopped|--repair-now)
    : >"${TRIPLEFROG_FILE}" 2>/dev/null || true
    touch "${STEAMROOT}/.install-complete"; rm -f "${STEAMROOT}/.crash" ;;
  *) echo "Usage: $0 --track-started | --track-stopped | --repair-now" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod 0755 /usr/share/deckard/steam-health-check
  log "已替换 steam-health-check（官方那个会抹掉 Steam 客户端）"
fi

# 11.4 RUNSTEAM.sh 替换：不传 -deckard/-vrgamepadui（切 Frame 内部构建并等 SteamVR）
if [[ -e /usr/share/deckard/RUNSTEAM.sh ]]; then
  cp -f /usr/share/deckard/RUNSTEAM.sh /usr/share/deckard/RUNSTEAM.sh.stock 2>/dev/null || true
  cat > /usr/share/deckard/RUNSTEAM.sh <<'EOF'
#!/bin/bash
set -euo pipefail
STEAMROOT="$( cd -- "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SEED=/usr/lib/steam/arm-client
if [[ -d "$SEED" && ! -e "${STEAMROOT}/.liuqin-arm-client" ]]; then
  echo "RUNSTEAM: seeding Steam client from $SEED"
  mkdir -p "$STEAMROOT"
  cp -a "$SEED/." "$STEAMROOT/" 2>/dev/null || true
  touch "${STEAMROOT}/.liuqin-arm-client" 2>/dev/null || true
fi
STEAM_RT_ARM64=steamrtarm64
STEAM_SDK_ARM64=linuxarm64
[[ -d "${STEAMROOT}/${STEAM_RT_ARM64}" ]] || { [[ -d "${STEAMROOT}/linuxarm64" ]] && STEAM_RT_ARM64="linuxarm64"; }
[[ -d "${STEAMROOT}/${STEAM_SDK_ARM64}" ]] || { [[ -d "${STEAMROOT}/steamrtarm64" ]] && STEAM_SDK_ARM64="steamrtarm64"; }
export LD_LIBRARY_PATH="${STEAMROOT}/${STEAM_RT_ARM64}"
export SteamDeck="${SteamDeck:-1}"
export QT_QPA_PLATFORM=xcb
export _STEAM_SETENV_MANAGER=1
export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]]; then
  [[ -S "${XDG_RUNTIME_DIR:-/run/user/1000}/gamescope-0" ]] && export GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
fi
export GAMESCOPE_WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
unset WAYLAND_DISPLAY XDG_SESSION_TYPE || true
for _i in $(seq 1 50); do [[ -S /tmp/.X11-unix/X0 ]] && break; sleep 0.1; done
rm -f "${STEAMROOT}/.crash" "${STEAMROOT}/steam.pid" 2>/dev/null || true
printf '%s\n' \
  'BootStrapperInhibitAll=enable' \
  'BootStrapperForceSelfUpdate=disable' \
  'BootStrapperInhibitClientChecksum=enable' \
  'BootStrapperInhibitBootstrapperChecksum=enable' \
  'BootStrapperInhibitUpdateOnLaunch=enable' \
  >"${STEAMROOT}/steam.cfg" 2>/dev/null || true
if [[ ! -s "${STEAMROOT}/steam.inf" ]]; then
  printf 'ClientVersion=%s\n' "1788652215" >"${STEAMROOT}/steam.inf"
  cp -f "${STEAMROOT}/steam.inf" "${STEAMROOT}/${STEAM_RT_ARM64}/steam.inf" 2>/dev/null || true
fi
htmlcache="${STEAMROOT}/config/htmlcache"
if [[ -L "${htmlcache}/SingletonLock" || -e "${htmlcache}/SingletonLock" ]]; then
  rm -f "${htmlcache}/SingletonLock" "${htmlcache}/SingletonCookie" "${htmlcache}/SingletonSocket" 2>/dev/null || true
fi
steam_tar=/usr/lib/steam/steam.tar.zst
if [[ -f "$steam_tar" && ! -s "${STEAMROOT}/steamui/index.html" ]]; then
  rm -rf "${STEAMROOT}/steamui"
  tar --zstd -xf "$steam_tar" -C "${STEAMROOT}" ./steamui 2>/dev/null || true
fi
[[ -x /usr/lib/steamos/liuqin-patch-steamui ]] && \
  /usr/lib/steamos/liuqin-patch-steamui "${STEAMROOT}/steamui" >/dev/null 2>&1 || true
if [[ -d "${STEAMROOT}/linuxarm64" && -d "${STEAMROOT}/steamrtarm64" ]]; then
  for _lib in steamclient.so crashhandler.so steam-launch-wrapper; do
    _src="${STEAMROOT}/steamrtarm64/${_lib}"; _dst="${STEAMROOT}/linuxarm64/${_lib}"
    [[ -s "$_src" && ! -s "$_dst" ]] && cp -f "$_src" "$_dst" 2>/dev/null || true
  done
fi
ln_for_real() { [[ -d "${2}" ]] && rm -rf "${2}"; ln -sTfn "${1}" "${2}"; }
mkdir -p ~/.steam
ln_for_real "${STEAMROOT}" ~/.steam/steam
ln_for_real "${STEAMROOT}" ~/.steam/root
ln_for_real "${STEAMROOT}/linux32" ~/.steam/sdk32
ln_for_real "${STEAMROOT}/linux64" ~/.steam/sdk64
ln_for_real "${STEAMROOT}/${STEAM_SDK_ARM64}" ~/.steam/sdkarm64
ln_for_real "${STEAMROOT}/${STEAM_RT_ARM64}" ~/.steam/binarm64
ln_for_real "${STEAMROOT}/ubuntu12_32" ~/.steam/bin32
ln_for_real "${STEAMROOT}/ubuntu12_64" ~/.steam/bin64
export STEAM_RUNTIME="$STEAMROOT/ubuntu12_32/steam-runtime"
export STEAM_RUNTIME_LIBRARY_PATH="$STEAM_RUNTIME/pinned_libs_32:$STEAM_RUNTIME/pinned_libs_64:/usr/local/lib/i386-linux-gnu:/lib/i386-linux-gnu:/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:/lib:$STEAM_RUNTIME/lib/i386-linux-gnu:$STEAM_RUNTIME/usr/lib/i386-linux-gnu:$STEAM_RUNTIME/lib/x86_64-linux-gnu:$STEAM_RUNTIME/usr/lib/x86_64-linux-gnu:$STEAM_RUNTIME/lib:$STEAM_RUNTIME/usr/lib"
STEAM_ARGS=(
  -cef-enable-debugging
  -gamepadui
  -steamos3
  -steampal
  -steamdeck
  -noverifyfiles
  -noshaders
  -inhibitbootstrap
  -nobootstrapperupdate
  ${STEAM_EXTRA_ARGS:-}
)
cd "${STEAMROOT}"
mkdir -p "${HOME}/.local/share/Steam/logs"
unset LD_PRELOAD || true
exec "${STEAMROOT}/${STEAM_RT_ARM64}/steam" "${STEAM_ARGS[@]}" \
  >"${HOME}/.local/share/Steam/logs/steam_output.log" 2>&1
EOF
  chmod 0755 /usr/share/deckard/RUNSTEAM.sh
  if [[ -d /home/steamos/.local/share/Steam ]]; then
    cp -f /usr/share/deckard/RUNSTEAM.sh /home/steamos/.local/share/Steam/RUNSTEAM.sh 2>/dev/null || true
    chmod 0755 /home/steamos/.local/share/Steam/RUNSTEAM.sh 2>/dev/null || true
  fi
  log "已替换 RUNSTEAM.sh（不再走 -deckard/-vrgamepadui 路径）"
fi

# 11.5 steamui 补丁：修 Steam 库一直转圈（AppStore 等 update_complete() 永远等不到）
cat > /usr/lib/steamos/liuqin-patch-steamui <<'EOF'
#!/bin/bash
set +e
root="${1:-/home/steamos/.local/share/Steam/steamui}"
python3 - "$root" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
if not root.is_dir():
    sys.exit(0)
_END = r"\)" r"\}" r"\)" r"\}" r"\)"
APP_WAIT = re.compile(
    r"await new Promise\(\((\w+),(\w+)\)=>\{let (\w+)=\1;"
    r"SteamClient\.Apps\.RegisterForAppOverviewChanges\((\w+)=>\{"
    r"this\.UpdateAppOverview\(\4\)&&\(this\.m_bIsInitialized=!0,"
    r"\3&&\3\(\),\3=null" + _END
)
APP_WAIT_NEW = (
    r"await new Promise((\1,\2)=>{let \3=\1;"
    r"const done=()=>{this.m_bIsInitialized=!0;\3&&\3();\3=null};"
    r"setTimeout(done,1500);"
    r"SteamClient.Apps.RegisterForAppOverviewChanges(\4=>{"
    r"this.UpdateAppOverview(\4);done()})})"
)
OLD_CHECK = (
    "GetMostSpecificCheckResult(){const e=this.m_updateState.update_check_results??"
    "[{eresult:s.R}];let t=!1;for(const r of e)if(r.eresult!=s.R){if(r.eresult!=s.zi)"
    "return r.eresult;t=!0}return t?s.zi:s.R}"
)
NEW_CHECK = (
    "GetMostSpecificCheckResult(){const e=this.m_updateState.update_check_results??"
    "[{eresult:s.R}];let t=!1;for(const r of e){if(40===r.eresult&&!r.available)continue;"
    "if(r.eresult!=s.R){if(r.eresult!=s.zi)return r.eresult;t=!0}}return t?s.zi:s.R}"
)
changed = 0
for p in list(root.glob("chunk*.js")) + list(root.glob("library.js")):
    txt = p.read_text(errors="replace")
    orig = txt
    if "setTimeout(done,1500)" not in txt and "RegisterForAppOverviewChanges" in txt:
        txt, n = APP_WAIT.subn(APP_WAIT_NEW, txt, count=1)
    if "40===r.eresult&&!r.available" not in txt and OLD_CHECK in txt:
        txt = txt.replace(OLD_CHECK, NEW_CHECK, 1)
    complete = "return l&&s.oy.ScopeRunningApps(),w.md.OnAppOverviewChange(a,n),t.update_complete()}"
    complete_new = "return l&&s.oy.ScopeRunningApps(),w.md.OnAppOverviewChange(a,n),(this.m_bIsInitialized=!0,!0)}"
    if complete in txt:
        txt = txt.replace(complete, complete_new)
    if txt != orig:
        p.write_text(txt); changed += 1
print(f"steamui files patched: {changed}", file=sys.stderr)
PY
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-patch-steamui

# 11.6 steamos-update / 桩：本镜像无 RAUC/atomupd 载荷，给出「已是最新」语义
if [[ -e /usr/bin/steamos-update ]]; then
  cp -f /usr/bin/steamos-update /usr/bin/steamos-update.stock 2>/dev/null || true
  cat > /usr/bin/steamos-update <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
STEAM_HOME="${STEAM_HOME:-/home/steamos}"
LOGINUSERS="${STEAM_HOME}/.local/share/Steam/config/loginusers.vdf"
MARKER=/var/lib/liuqin/oobe-os-update-acked
USER_MARKER="${STEAM_HOME}/.local/share/Steam/.oobe-os-update-acked"
REG_STEAM="${STEAM_HOME}/.steam/registry.vdf"
REG_LOCAL="${STEAM_HOME}/.local/share/Steam/registry.vdf"
mark_oobe_complete() {
  python3 - "$@" <<'PY' 2>/dev/null || true
import pathlib, re, sys
WANT = (("CompletedOOBE", "1"), ("CompletedOOBEStage1", "1"))
DROP = ("ForceOOBE", "ForceOOBEStage2")
def upsert(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    if '"Steam"' not in text:
        lines = "\n".join(f'\t\t\t\t\t"{k}"\t\t"{v}"' for k, v in WANT)
        text = ('"Registry"\n{\n\t"HKCU"\n\t{\n\t\t"Software"\n\t\t{\n'
                '\t\t\t"Valve"\n\t\t\t{\n\t\t\t\t"Steam"\n\t\t\t\t{\n'
                f"{lines}\n\t\t\t\t}}\n\t\t\t}}\n\t\t}}\n\t}}\n}}\n")
        path.write_text(text, encoding="utf-8"); return
    for k in DROP:
        text = re.sub(r'^[ \t]*"' + re.escape(k) + r'"[ \t]*"[^"]*"[ \t]*\n', "", text, flags=re.M)
    m = re.search(r'("HKCU"\s*\{.*?^[ \t]*"Steam"\s*\n[ \t]*\{)', text, flags=re.M | re.S)
    if not m:
        m = re.search(r'(^[ \t]*"Steam"\s*\n[ \t]*\{)', text, flags=re.M)
    if not m:
        path.write_text(text, encoding="utf-8"); return
    head_end = m.end(); i = head_end; depth = 1
    while i < len(text) and depth:
        if text[i] == "{": depth += 1
        elif text[i] == "}": depth -= 1
        i += 1
    block = text[head_end:i - 1]
    indent = "\t\t\t\t\t"
    child = re.search(r'\n([ \t]+)"', "\n" + block)
    if child: indent = child.group(1)
    for k, v in WANT:
        pat = r'^[ \t]*"' + re.escape(k) + r'"[ \t]*"[^"]*"'
        if re.search(pat, block, flags=re.M):
            block = re.sub(pat, f'"{k}"\t\t"{v}"', block, count=1, flags=re.M)
        else:
            block = f'\n{indent}"{k}"\t\t"{v}"' + (block if block.startswith("\n") else "\n" + block)
    path.write_text(text[:head_end] + block + text[i - 1:], encoding="utf-8")
for p in sys.argv[1:]:
    upsert(pathlib.Path(p))
PY
}
for arg in "$@"; do
  case "$arg" in
    --supports-duplicate-detection) exit 0 ;;
    --mark-oobe-only) mark_oobe_complete "$REG_STEAM" "$REG_LOCAL"; exit 0 ;;
  esac
done
check=0
for arg in "$@"; do [[ "$arg" == "check" ]] && check=1; done
[[ "$check" -eq 1 ]] && exit 7
oobe=0
if [[ ! -f "$LOGINUSERS" ]] || ! grep -qs '"AccountName"' "$LOGINUSERS"; then oobe=1; fi
[[ "$oobe" -eq 0 ]] && exit 7
mkdir -p /var/lib/liuqin "${STEAM_HOME}/.local/share/Steam" 2>/dev/null || true
mark_oobe_complete "$REG_STEAM" "$REG_LOCAL"
[[ -f "$MARKER" || -f "$USER_MARKER" ]] && exit 7
touch "$MARKER" "$USER_MARKER" 2>/dev/null || true
if [[ -x /usr/lib/steamos/liuqin-oobe-restart-steam ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    systemctl start --no-block liuqin-oobe-restart-steam.service 2>/dev/null || true
  else
    systemd-run --user --collect --on-active=2s --unit=liuqin-oobe-restart-steam-run \
      /usr/lib/steamos/liuqin-oobe-restart-steam >/dev/null 2>&1 \
      || nohup bash -c "sleep 2; exec /usr/lib/steamos/liuqin-oobe-restart-steam" >/dev/null 2>&1 &
  fi
fi
exit 0
EOF
  chmod 0755 /usr/bin/steamos-update
  install -d /usr/bin/steamos-polkit-helpers
  cat > /usr/bin/steamos-polkit-helpers/steamos-update <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
exec /usr/bin/steamos-update "$@"
EOF
  chmod 0755 /usr/bin/steamos-polkit-helpers/steamos-update
  log "已替换 steamos-update"
fi
cat > /usr/lib/steamos/liuqin-oobe-restart-steam <<'EOF'
#!/bin/bash
set -u
sleep 2
if [[ -x /usr/bin/steamos-update ]]; then
  STEAM_HOME="${STEAM_HOME:-/home/steamos}" /usr/bin/steamos-update --mark-oobe-only >/dev/null 2>&1 || true
fi
if [[ "$(id -u)" -eq 0 ]]; then
  systemctl --user -M steamos@ restart steam.service 2>/dev/null && exit 0
  if [[ -d /run/user/1000 ]]; then
    XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart steam.service 2>/dev/null && exit 0
  fi
else
  systemctl --user restart steam.service 2>/dev/null && exit 0
fi
pkill -KILL -u steamos -f 'steamrtarm64/steam' 2>/dev/null || true
pkill -KILL -u steamos -f 'linuxarm64/steam' 2>/dev/null || true
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-oobe-restart-steam
cat > /usr/lib/systemd/system/liuqin-oobe-restart-steam.service <<'EOF'
[Unit]
Description=OOBE 更新步骤之后重启 Steam
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/lib/steamos/liuqin-oobe-restart-steam
Nice=0
EOF

# 11.7 start-gamescope-session 替换：会话类型保持不设置（xcb 只留在本进程与 steam.service）
if [[ -e /usr/bin/start-gamescope-session ]]; then
  cp -f /usr/bin/start-gamescope-session /usr/bin/start-gamescope-session.stock 2>/dev/null || true
  cat > /usr/bin/start-gamescope-session <<'EOF'
#!/bin/sh
TARGET="${1:-gamescope-session.target}"
systemctl --user stop graphical-session.target
systemctl --user reset-failed
unset XDG_SESSION_TYPE
export XDG_CURRENT_DESKTOP=gamescope
export XDG_SESSION_DESKTOP=gamescope
export DESKTOP_SESSION=gamescope
export QT_QPA_PLATFORM=xcb
systemctl --user unset-environment XDG_SESSION_TYPE WAYLAND_DISPLAY QT_QPA_PLATFORM || true
systemctl --user set-environment XDG_CURRENT_DESKTOP=gamescope || true
systemctl --user set-environment XDG_SESSION_DESKTOP=gamescope || true
systemctl --user set-environment DESKTOP_SESSION=gamescope || true
dbus-update-activation-environment --systemd DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP >/dev/null 2>&1 || true
systemctl --user set-environment XDG_DESKTOP_PORTAL_DIR="/usr/share/xdg-desktop-portal/gamescope-portals"
systemctl --user set-environment "GAMESCOPE_SESSION_TARGET=${TARGET}"
systemctl --user unset-environment DISPLAY XAUTHORITY WAYLAND_DISPLAY || true
trap "systemctl --user stop ${TARGET}" HUP INT TERM
systemctl --user --wait start "${TARGET}" &
wait
logger Gamescope Session Ended - Performing Final Cleanup
systemctl --user unset-environment QT_QPA_PLATFORM GAMESCOPE_WAYLAND_DISPLAY GAMESCOPE_SESSION_TARGET || true
systemctl --user stop graphical-session-pre.target
logger Gamescope Session Ended - Cleanup Complete
EOF
  chmod 0755 /usr/bin/start-gamescope-session
  log "已替换 start-gamescope-session"
fi

# 11.8 steam.service drop-in（bootstrap + gamescope 绑定）
install -d /usr/lib/systemd/user/steam.service.d
cat > /usr/lib/systemd/user/steam.service.d/99-liuqin-bootstrap.conf <<'EOF'
[Service]
Environment=STEAM_EXTRA_ARGS=-inhibitbootstrap -nobootstrapperupdate -noverifyfiles
EOF
cat > /usr/lib/systemd/user/steam.service.d/99-liuqin.conf <<'EOF'
[Unit]
Wants=
After=
After=gamescope-session.service
# ⚠️ 不能用 BindsTo=gamescope-session.service（Plasma 桌面下 gamescope 没运行 → Steam 起不来）；
# PartOf 即可：切桌面停掉 gamescope 时 Steam 跟着停，但不要求 gamescope 必须先跑。
PartOf=gamescope-session.service
[Service]
Restart=on-failure
RestartSec=2
TimeoutStartSec=180
Environment=PATH=/usr/lib/steamos/liuqin-bin:/usr/bin:/bin
Environment=QT_QPA_PLATFORM=xcb
Environment=DISPLAY=:0
Environment=GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
Environment=XDG_CURRENT_DESKTOP=gamescope
Environment=XDG_SESSION_DESKTOP=gamescope
Environment=_STEAM_SETENV_MANAGER=1
Environment=SteamDeck=1
UnsetEnvironment=WAYLAND_DISPLAY
UnsetEnvironment=XDG_SESSION_TYPE
ExecStopPost=
EOF
log "已写入 steam.service 的两个 drop-in"

# 11.9 Steam 窗口焦点补丁（gamescope --steam 只聚焦带 STEAM_GAME atom 的窗口）
cat > /usr/lib/steamos/liuqin-steam-focus <<'EOF'
#!/bin/bash
set +e
export DISPLAY="${DISPLAY:-:0}"
command -v xprop >/dev/null 2>&1 || exit 0
command -v xwininfo >/dev/null 2>&1 || exit 0
tag() {
  local ids id
  ids="$(xwininfo -root -tree 2>/dev/null | awk '/[Ss]team/{ if (match($0, /0x[0-9a-fA-F]+/)) print substr($0, RSTART, RLENGTH) }' | sort -u)"
  for id in $ids; do
    [[ -n "$id" ]] || continue
    if ! xprop -id "$id" STEAM_GAME 2>/dev/null | grep -q 'STEAM_GAME(CARDINAL)'; then
      xprop -id "$id" -f STEAM_GAME 32c -set STEAM_GAME 769 2>/dev/null || true
      xprop -id "$id" -f STEAM_OVERLAY 32c -set STEAM_OVERLAY 0 2>/dev/null || true
      xprop -id "$id" -f STEAM_BIGPICTURE 32c -set STEAM_BIGPICTURE 1 2>/dev/null || true
    fi
  done
}
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 2; tag; done
exit 0
EOF
chmod 0755 /usr/lib/steamos/liuqin-steam-focus
cat > /usr/lib/systemd/user/liuqin-steam-focus.service <<'EOF'
[Unit]
Description=liuqin: 给 Steam 窗口补 STEAM_GAME atom
After=steam.service gamescope-session.service
[Service]
Type=oneshot
ExecStart=/usr/lib/steamos/liuqin-steam-focus
EOF

# 12) 在 Frame rootfs 内自编 KDE 组件（KF6 NetworkManagerQt + libksysguard + plasma-systemmonitor）
#     Frame extra 是 6.0 快照，与底包 Plasma/KF6 6.2.5 不匹配；ALARM chroot 的链也不兼容
#     （glibc 版本差）。所以必须在底包环境内装依赖 + 源码编译。失败只告警。
if [[ "${BUILD_KDE_MONITOR:-1}" == "1" ]]; then
  (
    set +e
    set +u
    log "自编 KDE 组件（系统监视器 / KF6 NetworkManagerQt）"
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    KDE_DEPS="base-devel cmake ninja extra-cmake-modules pkgconf \
              qt6-base qt6-declarative qt6-tools qt6-wayland \
              kconfig kcoreaddons ki18n kio kitemmodels kirigami kquickcharts kpackage kdeclarative \
              networkmanager-qt modemmanager-qt polkit-qt6 libnl libpcap"
    pacman -Sy --noconfirm >/dev/null 2>&1
    KDE_DEPS_OK=""
    for _p in $KDE_DEPS; do
      if pacman -Si "$_p" >/dev/null 2>&1; then KDE_DEPS_OK="$KDE_DEPS_OK $_p"; else warn "    跳过仓库里不存在的包名: $_p"; fi
    done
    pacman -S --noconfirm --needed --color never $KDE_DEPS_OK >/dev/null 2>&1 || warn "    KDE 构建依赖安装有报错"
    mkdir -p /tmp/kde-build && cd /tmp/kde-build || exit 0
    kde_build() {
      local _name="$1" _url="$2" _dir="$3"
      local _logf="/tmp/kde-build/${_name}.log"
      log "    ├─ ${_name}"
      curl -fsSL --retry 2 --max-time 300 -o "${_name}.tar.xz" "$_url" \
        || { warn "    └─ 下载失败: $_url"; return 1; }
      tar -xf "${_name}.tar.xz" || { warn "    └─ 解压失败"; return 1; }
      if ! cmake -S "$_dir" -B "${_dir}.build" -G Ninja \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTING=OFF -DBUILD_QCH=OFF -DBUILD_EXAMPLES=OFF >"$_logf" 2>&1; then
        warn "    └─ cmake 配置失败，日志尾部："; tail -25 "$_logf" | sed 's/^/        /'; return 1
      fi
      if ! cmake --build "${_dir}.build" -j"$(nproc)" >>"$_logf" 2>&1; then
        warn "    └─ 编译失败，日志尾部："; tail -25 "$_logf" | sed 's/^/        /'; return 1
      fi
      if ! cmake --install "${_dir}.build" >>"$_logf" 2>&1; then
        warn "    └─ 安装失败，日志尾部："; tail -15 "$_logf" | sed 's/^/        /'; return 1
      fi
      log "    └─ 完成"; return 0
    }
    NMQ_VER="$(pacman -Q networkmanager-qt 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$NMQ_VER" ]] && \
       [[ "$(printf '%s\n6.5\n' "${NMQ_VER%%-*}" | sort -V | head -n1)" == "6.5" ]]; then
      log "    NetworkManagerQt 已 >= 6.5（$NMQ_VER），跳过"
    else
      log "    NetworkManagerQt 版本不足 → 自编 6.14"
      kde_build networkmanager-qt \
        "https://download.kde.org/stable/frameworks/6.14/networkmanager-qt-6.14.0.tar.xz" \
        "networkmanager-qt-6.14.0"
    fi
    kde_build libksysguard \
      "https://download.kde.org/stable/plasma/6.2.5/libksysguard-6.2.5.tar.xz" \
      "libksysguard-6.2.5"
    kde_build plasma-systemmonitor \
      "https://download.kde.org/stable/plasma/6.2.5/plasma-systemmonitor-6.2.5.tar.xz" \
      "plasma-systemmonitor-6.2.5"
    ldconfig 2>/dev/null || true
    pacman -Rdd --noconfirm --color never cmake ninja extra-cmake-modules >/dev/null 2>&1 || true
    rm -rf /tmp/kde-build
    if [[ -x /usr/bin/plasma-systemmonitor ]]; then log "    ✓ plasma-systemmonitor 已就位"; else warn "    ✗ 缺 plasma-systemmonitor"; fi
    if ls /usr/lib/libKF6NetworkManagerQt.so* >/dev/null 2>&1; then log "    ✓ libKF6NetworkManagerQt 已就位"; else warn "    ✗ 缺 libKF6NetworkManagerQt"; fi
    exit 0
  ) 2>&1 | sed 's/^/[kde] /' || warn "自编 KDE 组件失败（不影响出图）"
fi

# 13) Valve 官方 ARM Steam 客户端（Frame 那份是头显版，不能用于平板）
if [[ "${DOWNLOAD_STEAM_CLIENT:-1}" == "1" ]]; then
  (
    set +e
    set +u
    STEAM_CHANNEL="${STEAM_CHANNEL:-steamdeck_stable}"
    SEED=/usr/lib/steam/arm-client
    MANIFEST="steam_client_${STEAM_CHANNEL}_linuxarm64"
    BASE="https://client-update.steamstatic.com"
    log "下载 Steam ARM 客户端（channel=$STEAM_CHANNEL）→ $SEED"
    command -v python3 >/dev/null 2>&1 || warn "    没有 python3，跳过"
    mkdir -p "$SEED" /tmp/steamdl && cd /tmp/steamdl || exit 0
    if ! curl -fsSL --retry 2 --max-time 120 -o "$MANIFEST" "$BASE/$MANIFEST"; then
      warn "    清单下载失败"; exit 0
    fi
    BINS="$(grep -aoE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' "$MANIFEST" | head -1)"
    UI="$(grep -aoE 'steamui_websrc_all\.zip\.[0-9a-f]+' "$MANIFEST" | head -1)"
    CLIENTVER="$(grep -aoE '"version"[^0-9]*[0-9]{9,}' "$MANIFEST" | grep -aoE '[0-9]{9,}' | head -1)"
    [[ -n "$BINS" ]] || { warn "    清单里没解析出 bins zip"; exit 0; }
    log "    bins: $BINS  ui: ${UI:-跳过}  版本: ${CLIENTVER:-未知}"
    extract_zip() {
      python3 - "$1" "$SEED" <<'PY'
import sys, zipfile, pathlib
src, dest = sys.argv[1], pathlib.Path(sys.argv[2])
n = 0
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        if name.endswith("/") or name.startswith("/") or ".." in name.split("/"):
            continue
        out = dest / name
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(z.read(info))
        if name.endswith(("/steam", "/steamwebhelper", "/steamwebhelper.sh", "/.sh")):
            try: out.chmod(0o755)
            except Exception: pass
        n += 1
print(f"extracted {n} entries")
PY
    }
    ok=0
    for z in "$BINS" "$UI"; do
      [[ -n "$z" ]] || continue
      log "    下载 $z …"
      curl -fsSL --retry 2 --max-time 1200 -o "$z" "$BASE/$z" || { warn "    $z 下载失败"; continue; }
      extract_zip "$z" 2>&1 | sed 's/^/        /'
      rm -f "$z"; ok=1
    done
    mkdir -p "$SEED/package"
    echo "$STEAM_CHANNEL" > "$SEED/package/beta"
    cp -f "$MANIFEST" "$SEED/package/${MANIFEST}.manifest" 2>/dev/null || true
    printf 'ClientVersion=%s\n' "${CLIENTVER:-1788652215}" > "$SEED/steam.inf"
    cp -f "$SEED/steam.inf" "$SEED/steamrtarm64/steam.inf" 2>/dev/null || true
    printf '%s\n' "$STEAM_CHANNEL" > "$SEED/.liuqin-arm-client"
    touch "$SEED/.install-complete"
    find "$SEED" -maxdepth 2 -type f \( -name steam -o -name steamwebhelper \) -exec chmod 0755 {} + 2>/dev/null
    for f in steamrtarm64/steam steamrtarm64/steamui.so steamui/index.html; do
      if [[ -s "$SEED/$f" ]]; then log "    ✓ $f"; else warn "    ✗ 缺 $f"; fi
    done
    log "    客户端体积: $(du -sh "$SEED" 2>/dev/null | cut -f1)"
    cd / && rm -rf /tmp/steamdl
    exit 0
  ) 2>&1 | sed 's/^/[steam] /' || warn "Steam 客户端下载段失败（不影响出图）"
fi

log "liuqin 设备层注入完成（内核 ${KVER:-未知}，root=PARTLABEL=$PARTLABEL）"
exit 0
