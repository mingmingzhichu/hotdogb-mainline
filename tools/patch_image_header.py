#!/usr/bin/env python3
"""Patch an arm64 Image header from the EFI layout to the OnePlus stock
non-EFI layout: code0 = branch to primary_entry, code1 = 0, text_offset = 0.

text_offset defaults to 0 because that is what the stock OnePlus Image
advertises.  Whatever ABL does with the field (ignore it, add it to the load
address, or subtract it), a value of 0 can only make ABL behave the same way
it does for the stock kernel.  The kernel itself never reads the field.

Only the 64-bit header words at offsets 0, 4 and 8 are changed.  The rest of
the Image (including the EFI PE header at 0x40) is untouched.
"""
import argparse
import struct
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--text-offset", type=lambda x: int(x, 0), default=0)
    args = ap.parse_args()

    data = bytearray(open(args.image, "rb").read())
    if len(data) < 64:
        sys.exit("image too small")
    magic = struct.unpack_from("<I", data, 56)[0]
    if magic != 0x644D5241:
        sys.exit(f"bad arm64 Image magic: {magic:#x}")

    code0, code1 = struct.unpack_from("<II", data, 0)
    text_offset = struct.unpack_from("<Q", data, 8)[0]
    print(f"before: code0={code0:#010x} code1={code1:#010x} text_offset={text_offset:#x}")

    # The EFI layout has efi_signature_nop at code0 and a B at code1.
    # Decode the B at code1 and move it to code0, adjusting imm26 by +1.
    if (code1 & 0xFC000000) != 0x14000000:
        sys.exit(f"code1 is not an unconditional B: {code1:#010x}")
    imm26 = code1 & 0x03FFFFFF
    # B at offset 4 -> target = 4 + imm26*4.  B at offset 0 -> imm26' = imm26 + 1.
    new_code0 = 0x14000000 | ((imm26 + 1) & 0x03FFFFFF)
    new_code1 = 0
    struct.pack_into("<II", data, 0, new_code0, new_code1)
    struct.pack_into("<Q", data, 8, args.text_offset)

    open(args.output, "wb").write(data)
    print(f"after : code0={new_code0:#010x} code1={new_code1:#010x} text_offset={args.text_offset:#x}")
    print(f"wrote {args.output}: {len(data)} bytes")


if __name__ == "__main__":
    main()
