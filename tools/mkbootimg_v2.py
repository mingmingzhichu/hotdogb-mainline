#!/usr/bin/env python3
"""Android boot image v2 builder with separate DTB section (mkbootimg layout)."""
import argparse
import hashlib
import struct

MAGIC = b"ANDROID!"
HEADER_SIZE_V2 = 1660


def pad(data, page):
    rem = len(data) % page
    return data if rem == 0 else data + b"\0" * (page - rem)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", default=None)
    ap.add_argument("--second", default=None)
    ap.add_argument("--dtb", required=True)
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0)
    ap.add_argument("--kernel_offset", type=lambda x: int(x, 0), default=0x8000)
    ap.add_argument("--ramdisk_offset", type=lambda x: int(x, 0), default=0x01000000)
    ap.add_argument("--second_offset", type=lambda x: int(x, 0), default=0x00f00000)
    ap.add_argument("--tags_offset", type=lambda x: int(x, 0), default=0x100)
    ap.add_argument("--dtb_offset", type=lambda x: int(x, 0), default=0x01f00000)
    ap.add_argument("--pagesize", type=int, default=4096)
    ap.add_argument("--name", default="")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    kernel = open(args.kernel, "rb").read()
    ramdisk = open(args.ramdisk, "rb").read() if args.ramdisk else b""
    second = open(args.second, "rb").read() if args.second else b""
    dtb = open(args.dtb, "rb").read()

    cmdline = args.cmdline.encode()
    if len(cmdline) > 1535:
        raise SystemExit("cmdline too long for v2 header")

    digest = hashlib.sha1()
    digest.update(kernel)
    digest.update(ramdisk)
    digest.update(second)
    digest.update(dtb)

    header = struct.pack(
        "<8s10I16s512s32s1024sIQIIQ",
        MAGIC,
        len(kernel), args.base + args.kernel_offset,
        len(ramdisk), args.base + args.ramdisk_offset,
        len(second), args.base + args.second_offset,
        args.base + args.tags_offset,
        args.pagesize,
        2,            # header_version
        0,            # os_version
        args.name.encode()[:16],
        cmdline,
        digest.digest(),
        b"",          # extra_cmdline
        0,            # recovery_dtbo_size
        0,            # recovery_dtbo_offset
        HEADER_SIZE_V2,
        len(dtb),
        args.base + args.dtb_offset,
    )
    assert len(header) == HEADER_SIZE_V2, len(header)

    out = pad(header, args.pagesize)
    out += pad(kernel, args.pagesize)
    out += pad(ramdisk, args.pagesize)
    out += pad(second, args.pagesize)
    out += pad(dtb, args.pagesize)

    with open(args.output, "wb") as f:
        f.write(out)

    print(f"wrote {args.output}: {len(out)} bytes")
    print(f"  kernel  {len(kernel)} @ {args.base + args.kernel_offset:#x}")
    print(f"  ramdisk {len(ramdisk)} @ {args.base + args.ramdisk_offset:#x}")
    print(f"  second  {len(second)} @ {args.base + args.second_offset:#x}")
    print(f"  dtb     {len(dtb)} @ {args.base + args.dtb_offset:#x}")
    print(f"  tags    @ {args.base + args.tags_offset:#x}")
    print(f"  pagesize {args.pagesize}, header_version 2")


if __name__ == "__main__":
    main()
