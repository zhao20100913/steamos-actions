#!/usr/bin/env python3
"""parse-gpt.py —— 从 GPT 镜像头部解析指定分区的字节偏移与长度

用法: parse-gpt.py <head.bin> [分区名关键字]
输出: 一行 `<偏移字节> <长度字节> <分区名>`；找不到则以非 0 退出。

用途：Steam Frame 底包是 ~7.5GB 的 GPT 整盘镜像，先只取前 4MiB 解析分区表，
再流式 `curl | bunzip2 | dd` 精确切出 rootfs 分区，避免把整盘解压落盘。
"""
import struct
import sys

SECTOR = 512


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: parse-gpt.py <head.bin> [分区名关键字]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    keyword = sys.argv[2] if len(sys.argv) > 2 else "rootfs"

    with open(path, "rb") as fh:
        data = fh.read(4 * 1024 * 1024)

    if len(data) < 2 * SECTOR or data[SECTOR:SECTOR + 8] != b"EFI PART":
        print(f"不是 GPT：LBA1 处没有 'EFI PART' 签名（读了 {len(data)} 字节）", file=sys.stderr)
        return 1

    hdr = data[SECTOR:SECTOR + SECTOR]
    entries_lba = struct.unpack_from("<Q", hdr, 72)[0]
    num_entries = struct.unpack_from("<I", hdr, 80)[0]
    entry_size = struct.unpack_from("<I", hdr, 84)[0]
    if entry_size < 128 or num_entries == 0:
        print(f"GPT 头异常：num_entries={num_entries} entry_size={entry_size}", file=sys.stderr)
        return 1

    base = entries_lba * SECTOR
    found = []
    for i in range(num_entries):
        off = base + i * entry_size
        if off + entry_size > len(data):
            break  # 头部读得不够长，剩余条目不可见
        ent = data[off:off + entry_size]
        if ent[:16] == b"\x00" * 16:
            continue
        first_lba, last_lba = struct.unpack_from("<QQ", ent, 32)
        if last_lba < first_lba:
            continue
        name = ent[56:128].decode("utf-16-le", "replace").split("\x00")[0].strip()
        found.append((i, first_lba, last_lba, name))

    if not found:
        print("GPT 里没有任何有效分区条目", file=sys.stderr)
        return 1

    print("解析到分区（序号 起始LBA 结束LBA 名称）:", file=sys.stderr)
    for i, f, l, n in found:
        print(f"  [{i}] {f} {l} {n}", file=sys.stderr)

    for i, f, l, n in found:
        if keyword in n.lower():
            off = f * SECTOR
            length = (l - f + 1) * SECTOR
            print(f"{off} {length} {n}")
            return 0

    print(f"没找到名称含 '{keyword}' 的分区", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
