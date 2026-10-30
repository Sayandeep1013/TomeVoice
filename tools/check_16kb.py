#!/usr/bin/env python3
"""Check that an APK's 64-bit native libraries are aligned for 16 KB pages.

Android 15 and later run on phones with 16 KB memory pages, and Google Play
requires apps that target them to have every 64-bit library's loadable
segments aligned to 16 KB (docs/07, docs/09 C-28). A library that is not
fails to load on such a phone, at run time, never at build time: hence this
check on the built APK. 32-bit libraries are listed but not checked: those
phones have 4 KB pages only.

Usage: check_16kb.py APK [--require NAME ...]

Every 64-bit library is listed with its size and alignment. Without
--require, any that is not aligned fails the check; with it, only the named
ones do, and the rest are warned about (as GitHub annotations).
"""

from __future__ import annotations

import argparse
import struct
import sys
import zipfile

PT_LOAD = 1
PAGE = 16 * 1024
SIXTY_FOUR = {"arm64-v8a", "x86_64"}


def load_alignments(data: bytes) -> list[tuple[int, int, int]]:
    """(offset, virtual address, alignment) of each PT_LOAD segment."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    is64 = data[4] == 2
    end = "<" if data[5] == 1 else ">"
    if is64:
        (phoff,) = struct.unpack_from(end + "Q", data, 0x20)
        phentsize, phnum = struct.unpack_from(end + "HH", data, 0x36)
    else:
        (phoff,) = struct.unpack_from(end + "I", data, 0x1C)
        phentsize, phnum = struct.unpack_from(end + "HH", data, 0x2A)
    out = []
    for i in range(phnum):
        at = phoff + i * phentsize
        if is64:
            p_type, _, offset, vaddr, _, _, _, align = struct.unpack_from(end + "IIQQQQQQ", data, at)
        else:
            p_type, offset, vaddr, _, _, _, _, align = struct.unpack_from(end + "IIIIIIII", data, at)
        if p_type == PT_LOAD:
            out.append((offset, vaddr, align))
    return out


def aligned(loads: list[tuple[int, int, int]]) -> bool:
    return bool(loads) and all(a >= PAGE and o % PAGE == v % PAGE for o, v, a in loads)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("apk")
    parser.add_argument("--require", nargs="*", default=None, help="library names that must be aligned")
    args = parser.parse_args()
    required = None if args.require is None else set(args.require)

    failed = []
    with zipfile.ZipFile(args.apk) as apk:
        for info in sorted(apk.infolist(), key=lambda i: i.filename):
            parts = info.filename.split("/")
            if len(parts) != 3 or parts[0] != "lib" or not parts[2].endswith(".so"):
                continue
            abi, name = parts[1], parts[2]
            data = apk.read(info)
            try:
                loads = load_alignments(data)
            except (ValueError, struct.error) as e:
                print(f"{abi}/{name}: cannot read ({e})")
                failed.append(f"{abi}/{name}")
                continue
            aligns = "/".join(sorted({str(a) for _, _, a in loads}))
            size = f"{info.file_size} bytes, {info.compress_size} in the APK"
            if abi not in SIXTY_FOUR:
                print(f"{abi}/{name}: {size}, segments aligned {aligns} (32-bit: 4 KB pages)")
                continue
            ok = aligned(loads)
            print(f"{abi}/{name}: {size}, segments aligned {aligns}: {'16 KB ok' if ok else 'NOT 16 KB'}")
            if ok:
                continue
            if required is None or name in required:
                failed.append(f"{abi}/{name}")
            else:
                print(f"::warning::{abi}/{name} is not aligned for 16 KB pages")
    if failed:
        print(f"::error::Not aligned for 16 KB pages: {', '.join(failed)}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
