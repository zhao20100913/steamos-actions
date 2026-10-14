#!/usr/bin/env python3
# 29-unpack-stock-images.py —— 从小米官方 Fastboot ROM 的 dtbo.img / vendor_boot.img
# 拆出构建 boot.img 所需的「analysis」产物：
#   analysis/dtbo/entry.N              （DTBO 表条目，每项一个完整 DTB）
#   analysis/vendor_boot/dtbs/dtb-XX.dtb （vendor boot 内的基础 DTB）
#
# 产物命名与 AOSP unpack_bootimg.py 一致，可被 30-prepare-stock-inputs.sh 直接校验打包。
# 用法:
#   python3 scripts/host/29-unpack-stock-images.py <dtbo.img> <vendor_boot.img> <analysis目录>
# 输出: 在 <analysis目录> 下写入 dtbo/ 与 vendor_boot/dtbs/，并打印各条目 FDT 校验结果。
import struct
import sys
from pathlib import Path

FDT_MAGIC = 0xD00DFEED          # flattened device tree magic (big-endian)
DTBO_MAGIC = 0xD7B7AB1E         # dt_table_header magic (little-endian)
VNDR_MAGIC = b"VNDRBOOT"
PAGE = 4096


def align_up(n: int, a: int) -> int:
    return (n + a - 1) // a * a


def parse_dtbo(data: bytes, out_dir: Path) -> list[bytes]:
    """解析 dtbo 镜像，支持两种容器变体：

    1. 标准 AOSP dt_table_header（小端，版本 1）：
       magic/total_size/header_size/dt_entry_size/dt_entry_count/
       dt_entries_offset/page_size/version，条目为 LE {dt_size, dt_offset}。
    2. 小米定制变体（本机 OS2.0.6.0 实测）：
       全部字段大端；字段布局 magic/[未知]/header_size(32)/dt_entry_size(32)/
       dt_entry_count(44)/dt_entries_offset(32)/page_size(4096)/version(0)；
       条目每条 32 字节，前两个 u32 为 BE {dt_size, dt_offset}，DTB 数据
       在条目表后连续紧排（首条偏移 = 32 + 44*32 = 0x5a0）。
    """
    if len(data) < 28:
        raise ValueError("dtbo 文件过小，不是合法 DTBO 镜像")
    if struct.unpack_from("<I", data, 0)[0] == DTBO_MAGIC:
        endian, variant = "<", "标准 AOSP 小端 dt_table_header"
        entry_size = struct.unpack_from("<I", data, 12)[0]
        entry_count = struct.unpack_from("<I", data, 16)[0]
        entries_off = struct.unpack_from("<I", data, 20)[0]
    elif data[:4] == struct.pack(">I", DTBO_MAGIC):
        endian, variant = ">", "小米定制大端 dt_table_header"
        entry_size = struct.unpack_from(">I", data, 12)[0]
        entry_count = struct.unpack_from(">I", data, 16)[0]
        entries_off = struct.unpack_from(">I", data, 20)[0]
    else:
        raise ValueError("dtbo magic 不对（应为 0xd7b7ab1e）")
    if entry_size < 8:
        raise ValueError(f"dt_entry_size 异常: {entry_size}")
    print(f"[dtbo] 变体: {variant}（{entry_count} 条条目, 条目表 @{entries_off:#x}, 每条 {entry_size}B）")
    pieces = []  # (dtoff, size, blob)
    for i in range(entry_count):
        off = entries_off + i * entry_size
        size, dtoff = struct.unpack_from(endian + "II", data, off)
        blob = data[dtoff:dtoff + size]
        if struct.unpack_from(">I", blob, 0)[0] != FDT_MAGIC:
            raise ValueError(f"dtbo entry.{i} 不是合法 DTB（FDT magic 不对）")
        pieces.append((dtoff, size, blob))
    # 连续紧排一致性（软警告）：dt_offset_i + dt_size_i 应等于 dt_offset_{i+1}
    for i in range(1, len(pieces)):
        prev_end = pieces[i - 1][0] + pieces[i - 1][1]
        if prev_end != pieces[i][0]:
            print(f"[dtbo] 提示: entry.{i - 1} 结束于 {prev_end:#x}，entry.{i} 起始于 {pieces[i][0]:#x}"
                  f"（{pieces[i][0] - prev_end:#x} 字节间隔/填充）")
    total = sum(s for _, s, _ in pieces)
    print(f"[dtbo] 数据合计 {total:#x} 字节, 文件 {len(data):#x} 字节")
    out = out_dir / "dtbo"
    out.mkdir(parents=True, exist_ok=True)
    for i, (_, _, blob) in enumerate(pieces):
        (out / f"entry.{i}").write_bytes(blob)
    print(f"[dtbo] {len(pieces)} 个条目 -> {out}")
    return [b for _, _, b in pieces]


def parse_vendor_boot(data: bytes, out_dir: Path) -> list[bytes]:
    """vendor_boot 的 DTB 段提取。

    兼容策略：不同厂商（小米等）会在 AOSP v3/v4 基础上改头字段长度/偏移，因此
    **不依赖头字段定位 DTB 段**，改为全文件扫描：
      1. 找所有 FDT magic 出现位置；
      2. 取"从最后一个 FDT 命中位置往前回溯的连续段"（用 totalsize 步进）作为 DTB 段；
      3. 按 totalsize 切分，逐块校验 FDT magic。
    本机 OS2.0.6.0 实测：14 个基础 DTB，段首 0x1682000（页对齐），合计字节数与
    vendor_boot 头 0x834 处的 dtb_size 字段一致；dtb-02 的 sha256 与上游项目锁定值
    完全一致（527344cd...54e467）。
    """
    if data[:8] != VNDR_MAGIC:
        raise ValueError("不是合法 vendor_boot 镜像（magic != VNDRBOOT）")
    version = struct.unpack_from("<I", data, 8)[0]
    if version not in (3, 4):
        print(f"[vendor_boot] 提示 header_version={version}（非 3/4，继续按 FDT 扫描）")
    # 1) 所有 FDT magic 位置
    hits, pos = [], 0
    while True:
        i = data.find(b"\xd0\x0d\xfe\xed", pos)
        if i < 0:
            break
        hits.append(i)
        pos = i + 1
    if not hits:
        raise ValueError("全文件未找到任何 FDT magic（不是可识别的 vendor_boot）")
    # 2) DTB 段 = 连续紧排的 DTB 串：从某个命中起点按 totalsize 步进，
    #    每一步都必须落在下一个命中上。依次尝试每个命中为起点，取覆盖块数最多的一段。
    best = []
    best_start = None
    for start in hits:
        chunks, p = [], start
        while struct.unpack_from(">I", data, p)[0] == FDT_MAGIC:
            totalsize = struct.unpack_from(">I", data, p + 4)[0]
            if totalsize < 8 or p + totalsize > len(data):
                raise ValueError(f"totalsize 异常: {totalsize} @ {p:#x}")
            chunks.append(data[p:p + totalsize])
            p += totalsize
            if p not in hits:
                break  # 连续段到此为止
        if len(chunks) > len(best):
            best, best_start = chunks, start
    dtbs = best
    if not dtbs:
        raise ValueError("未找到连续的 DTB 段")
    if len(dtbs) != len(hits):
        print(f"[vendor_boot] 提示: 连续段 {len(dtbs)} 块，全文件命中 {len(hits)} 处"
              f"（其余为孤立 magic，非 DTB 段）")
    total = sum(len(b) for b in dtbs)
    print(f"[vendor_boot] v{version}，DTB 段 @{best_start:#x}，{len(dtbs)} 个基础 DTB，合计 {total:#x} 字节")
    out = out_dir / "vendor_boot" / "dtbs"
    out.mkdir(parents=True, exist_ok=True)
    for i, dtb in enumerate(dtbs):
        (out / f"dtb-{i:02d}.dtb").write_bytes(dtb)
    print(f"[vendor_boot] 基础 DTB -> {out}")
    return dtbs


def main() -> None:
    if len(sys.argv) != 4:
        print("用法: 29-unpack-stock-images.py <dtbo.img> <vendor_boot.img> <analysis目录>")
        sys.exit(2)
    dtbo_path, vndr_path, out_dir = (Path(a) for a in sys.argv[1:4])
    for p in (dtbo_path, vndr_path):
        if not p.is_file():
            print(f"错误: 找不到 {p}")
            sys.exit(1)
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        d = parse_dtbo(dtbo_path.read_bytes(), out_dir)
        v = parse_vendor_boot(vndr_path.read_bytes(), out_dir)
    except (ValueError, struct.error) as e:
        print(f"解析失败: {e}")
        sys.exit(1)
    print(f"完成: dtbo {len(d)} 条目 / vendor_boot {len(v)} 个 DTB")
    print(f"下一步: bash scripts/host/30-prepare-stock-inputs.sh {out_dir}")


if __name__ == "__main__":
    main()
