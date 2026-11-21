#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Minimal NBD server for the OnePlus 7T netboot.

Serves one raw disk image over NBD using the fixed-newstyle handshake with
NBD_OPT_EXPORT_NAME, which is what BusyBox's nbd-client speaks.  It runs on
both Windows and Linux, so the PC does not need an NBD package:

    python tools/nbd_server.py --image rootfs.img --bind 172.16.42.2

The device side is initramfs/init with `hotdogb.netboot=1` on the cmdline.
"""

import argparse
import collections
import os
import socket
import struct
import sys
import time

NBDMAGIC = b"NBDMAGIC"
IHAVEOPT = b"IHAVEOPT"

NBD_OPT_EXPORT_NAME = 1
NBD_OPT_ABORT = 2

NBD_FLAG_HAS_FLAGS = 1 << 0
NBD_FLAG_READ_ONLY = 1 << 1
NBD_FLAG_SEND_FLUSH = 1 << 2

NBD_REQUEST_MAGIC = 0x25609513
NBD_REPLY_MAGIC = 0x67446698

NBD_CMD_READ = 0
NBD_CMD_WRITE = 1
NBD_CMD_DISC = 2
NBD_CMD_FLUSH = 3
NBD_CMD_TRIM = 4

EINVAL = 22
EIO = 5

# Chunk size for outgoing read replies, see send_reply().
SEND_CHUNK = 64 * 1024


def log(msg):
    print("nbd: " + msg, file=sys.stderr, flush=True)


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("peer closed the connection")
        data += chunk
    return data


def send_reply(sock, error, handle, payload=b""):
    sock.sendall(struct.pack(">IIQ", NBD_REPLY_MAGIC, error, handle))
    # Hand large reads to the kernel in smaller pieces: a single multi-hundred
    # KB sendall can stall long enough on a CDC-NCM link for the peer's USB
    # stack to reset the connection mid-boot.
    for start in range(0, len(payload), SEND_CHUNK):
        sock.sendall(payload[start:start + SEND_CHUNK])


def serve_client(conn, image, size, read_only, verbose=False, throttle_kbps=0):
    conn.sendall(NBDMAGIC + IHAVEOPT + struct.pack(">H", 1))
    recv_exact(conn, 4)  # client flags

    magic, option, length = struct.unpack(">QII", recv_exact(conn, 16))
    if magic != int.from_bytes(IHAVEOPT, "big"):
        log("bad option magic")
        return
    if option == NBD_OPT_ABORT:
        return
    if option != NBD_OPT_EXPORT_NAME:
        log("unsupported option %d" % option)
        return
    recv_exact(conn, length)  # export name, any name is accepted

    flags = NBD_FLAG_HAS_FLAGS | NBD_FLAG_SEND_FLUSH
    if read_only:
        flags |= NBD_FLAG_READ_ONLY
    conn.sendall(struct.pack(">QH", size, flags) + b"\x00" * 124)

    log("client attached%s" % (" (read-only)" if read_only else ""))

    count = 0
    throttle_bps = throttle_kbps * 1024
    sent = 0
    started = time.monotonic()
    recent = collections.deque(maxlen=20)
    try:
        while True:
            magic, req_flags, cmd, handle, offset, length = struct.unpack(
                ">IHHQQI", recv_exact(conn, 28)
            )
            recent.append((cmd, offset, length, req_flags))
            if verbose and (cmd != NBD_CMD_READ or count < 20):
                log("req cmd=%d off=%d len=%d flags=%d" %
                    (cmd, offset, length, req_flags))
            count += 1
            if magic != NBD_REQUEST_MAGIC:
                log("bad request magic 0x%08x" % magic)
                return

            if cmd == NBD_CMD_READ:
                if offset + length > size:
                    send_reply(conn, EINVAL, handle)
                    continue
                image.seek(offset)
                send_reply(conn, 0, handle, image.read(length))
                if throttle_bps:
                    sent += length
                    lag = sent / throttle_bps - (time.monotonic() - started)
                    if lag > 0:
                        time.sleep(lag)
            elif cmd == NBD_CMD_WRITE:
                data = recv_exact(conn, length)
                if read_only or offset + length > size:
                    send_reply(conn, EIO if read_only else EINVAL, handle)
                    continue
                image.seek(offset)
                image.write(data)
                send_reply(conn, 0, handle)
            elif cmd == NBD_CMD_FLUSH:
                image.flush()
                send_reply(conn, 0, handle)
            elif cmd == NBD_CMD_TRIM:
                send_reply(conn, 0, handle)
            elif cmd == NBD_CMD_DISC:
                return
            else:
                send_reply(conn, EINVAL, handle)
    except (ConnectionError, OSError) as err:
        log("client error after %d requests: %s" % (count, err))
        for c, o, ln, fl in recent:
            log("  last: cmd=%d off=%d len=%d flags=%d" % (c, o, ln, fl))
        raise


def main():
    parser = argparse.ArgumentParser(description="NBD server for hotdogb netboot")
    parser.add_argument("--image", required=True, help="raw disk image to export")
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    parser.add_argument("--port", type=int, default=9999, help="TCP port")
    parser.add_argument("--read-only", action="store_true", help="refuse writes")
    parser.add_argument(
        "--throttle-kbps",
        type=int,
        default=0,
        help="cap read throughput in KiB/s (0 = unlimited); a steady "
             "stream is gentler on the USB gadget than a burst",
    )
    parser.add_argument("--verbose", action="store_true", help="log NBD requests")
    args = parser.parse_args()

    size = os.path.getsize(args.image)
    mode = "rb" if args.read_only else "r+b"
    log("exporting %s (%d bytes) on %s:%d" % (args.image, size, args.bind, args.port))

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.bind, args.port))
    listener.listen(1)

    while True:
        conn, peer = listener.accept()
        log("connection from %s:%d" % peer)
        with open(args.image, mode) as image:
            try:
                serve_client(conn, image, size, args.read_only, args.verbose,
                             args.throttle_kbps)
            except (ConnectionError, OSError) as err:
                log("client error: %s" % err)
            finally:
                conn.close()


if __name__ == "__main__":
    main()
