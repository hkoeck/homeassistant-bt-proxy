#!/usr/bin/env python3
"""
Bluetooth HCI-over-Serial Proxy

Forwards raw HCI packets between the host's Bluetooth adapter and a
virtio-serial channel connected to a VM, using H4 (UART Transport) framing.

The VM runs btattach against the virtio-serial device to create an hci0
interface that BlueZ can use normally.
"""

import argparse
import asyncio
import ctypes
import ctypes.util
import errno
import fcntl
import logging
import os
import signal
import socket
import struct
import sys

logger = logging.getLogger("hci-proxy")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Bluetooth socket (linux/bluetooth.h)
AF_BLUETOOTH = 31
BTPROTO_HCI = 1
HCI_CHANNEL_USER = 1

# ioctl codes (linux/hci_sock.h)
# _IOW('H', 201, int) and _IOW('H', 202, int)
HCIDEVUP = 0x400448C9
HCIDEVDOWN = 0x400448CA

# H4 packet type indicators
H4_CMD_PKT = 0x01
H4_ACL_PKT = 0x02
H4_SCO_PKT = 0x03
H4_EVT_PKT = 0x04
H4_ISO_PKT = 0x05

# (header_size_after_type_byte, length_field_offset, length_field_size)
H4_PACKET_INFO = {
    H4_CMD_PKT: (3, 2, 1),  # opcode(2) + plen(1)
    H4_ACL_PKT: (4, 2, 2),  # handle(2) + dlen(2)
    H4_SCO_PKT: (3, 2, 1),  # handle(2) + dlen(1)
    H4_EVT_PKT: (2, 1, 1),  # event(1) + plen(1)
    H4_ISO_PKT: (4, 2, 2),  # handle(2) + dlen(2, 14-bit)
}

MAX_PARSER_BUF = 65536  # 64 KiB sanity limit


# ---------------------------------------------------------------------------
# H4 stream parser
# ---------------------------------------------------------------------------

class ProtocolError(Exception):
    pass


class H4StreamParser:
    """Reassemble complete H4 packets from a byte stream."""

    def __init__(self):
        self._buf = bytearray()

    def reset(self):
        self._buf.clear()

    def feed(self, data: bytes) -> list[bytes]:
        """Feed raw bytes; return a list of complete H4 packets."""
        self._buf.extend(data)
        if len(self._buf) > MAX_PARSER_BUF:
            raise ProtocolError(
                f"Parser buffer exceeded {MAX_PARSER_BUF} bytes — likely desync"
            )
        packets: list[bytes] = []
        while True:
            pkt = self._try_parse()
            if pkt is None:
                break
            packets.append(pkt)
        return packets

    def _try_parse(self) -> bytes | None:
        if not self._buf:
            return None

        pkt_type = self._buf[0]
        info = H4_PACKET_INFO.get(pkt_type)
        if info is None:
            raise ProtocolError(
                f"Unknown H4 type 0x{pkt_type:02x}, "
                f"buf head: {self._buf[:32].hex()}"
            )

        hdr_size, len_offset, len_size = info
        needed_hdr = 1 + hdr_size
        if len(self._buf) < needed_hdr:
            return None

        if len_size == 1:
            payload_len = self._buf[1 + len_offset]
        else:
            payload_len = struct.unpack_from("<H", self._buf, 1 + len_offset)[0]
            if pkt_type == H4_ISO_PKT:
                payload_len &= 0x3FFF  # 14-bit length field

        total = needed_hdr + payload_len
        if len(self._buf) < total:
            return None

        pkt = bytes(self._buf[:total])
        del self._buf[:total]
        return pkt


# ---------------------------------------------------------------------------
# HCI socket helpers
# ---------------------------------------------------------------------------

def bring_hci_down(dev: int) -> None:
    """Bring HCI device down so HCI_CHANNEL_USER can bind."""
    sock = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW, BTPROTO_HCI)
    try:
        try:
            fcntl.ioctl(sock.fileno(), HCIDEVDOWN, dev)
            logger.info("Brought hci%d down", dev)
        except OSError as exc:
            # EALREADY / ENODEV are tolerable
            if exc.errno not in (errno.EALREADY, errno.ENODEV):
                raise
            logger.debug("hci%d already down or absent (errno %d)", dev, exc.errno)
    finally:
        sock.close()


def _libc_bind(sock: socket.socket, addr_bytes: bytes) -> None:
    """Call bind() via ctypes for sockaddr formats Python doesn't support."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    rc = libc.bind(
        ctypes.c_int(sock.fileno()),
        ctypes.c_char_p(addr_bytes),
        ctypes.c_int(len(addr_bytes)),
    )
    if rc != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def open_hci_user_channel(dev: int) -> socket.socket:
    """Open an exclusive HCI_CHANNEL_USER raw socket."""
    sock = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW, BTPROTO_HCI)
    sock.setblocking(False)
    # struct sockaddr_hci { uint16 family, uint16 dev, uint16 channel }
    addr = struct.pack("<HHH", AF_BLUETOOTH, dev, HCI_CHANNEL_USER)
    _libc_bind(sock, addr)
    logger.info("Opened HCI_CHANNEL_USER on hci%d", dev)
    return sock


# ---------------------------------------------------------------------------
# BlueZ management
# ---------------------------------------------------------------------------

async def stop_bluez() -> None:
    """Stop host bluetooth.service for exclusive adapter access."""
    logger.info("Stopping bluetooth.service …")
    proc = await asyncio.create_subprocess_exec(
        "systemctl", "stop", "bluetooth.service",
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode == 0:
        logger.info("bluetooth.service stopped")
    else:
        logger.warning(
            "Could not stop bluetooth.service (rc=%d): %s",
            proc.returncode,
            stderr.decode().strip(),
        )


# ---------------------------------------------------------------------------
# Forwarding coroutines
# ---------------------------------------------------------------------------

def _describe_pkt(data: bytes) -> str:
    """Return a human-readable description of an H4 packet."""
    if len(data) < 2:
        return f"type=0x{data[0]:02x} len={len(data)}"
    ptype = data[0]
    if ptype == H4_CMD_PKT and len(data) >= 4:
        opcode = struct.unpack_from("<H", data, 1)[0]
        ogf = opcode >> 10
        ocf = opcode & 0x3FF
        return f"CMD ogf=0x{ogf:02x} ocf=0x{ocf:04x} len={len(data)}"
    if ptype == H4_EVT_PKT and len(data) >= 3:
        evt = data[1]
        extra = ""
        # LE Meta Event
        if evt == 0x3E and len(data) >= 4:
            sub = data[3]
            extra = f" sub=0x{sub:02x}"
        return f"EVT code=0x{evt:02x}{extra} len={len(data)}"
    if ptype == H4_ACL_PKT:
        return f"ACL len={len(data)}"
    return f"type=0x{ptype:02x} len={len(data)}"


async def forward_hci_to_virtio(
    hci_sock: socket.socket,
    writer: asyncio.StreamWriter,
    stats: dict,
) -> None:
    """HCI socket → virtio-serial (already H4-framed, message-oriented)."""
    loop = asyncio.get_running_loop()
    while True:
        data = await loop.sock_recv(hci_sock, 4096)
        if not data:
            raise ConnectionError("HCI socket closed")
        stats["hci_to_virtio"] += 1
        if logger.isEnabledFor(logging.DEBUG):
            logger.debug("HCI→Virtio  %s", _describe_pkt(data))
        writer.write(data)
        await writer.drain()


async def forward_virtio_to_hci(
    reader: asyncio.StreamReader,
    hci_sock: socket.socket,
    stats: dict,
) -> None:
    """Virtio-serial → HCI socket (stream → H4 reassembly → message send)."""
    loop = asyncio.get_running_loop()
    parser = H4StreamParser()
    while True:
        data = await reader.read(4096)
        if not data:
            raise ConnectionError("Virtio-serial disconnected")
        try:
            packets = parser.feed(data)
        except ProtocolError as exc:
            logger.error("H4 protocol error: %s — resetting parser", exc)
            parser.reset()
            continue
        for pkt in packets:
            stats["virtio_to_hci"] += 1
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug("Virtio→HCI  %s", _describe_pkt(pkt))
            await loop.sock_sendall(hci_sock, pkt)


# ---------------------------------------------------------------------------
# Connection & main loop
# ---------------------------------------------------------------------------

async def connect_virtio(sock_path: str) -> tuple:
    """Connect to the virtio-serial UNIX socket, retrying until available."""
    while True:
        try:
            reader, writer = await asyncio.open_unix_connection(sock_path)
            logger.info("Connected to virtio-serial at %s", sock_path)
            return reader, writer
        except (ConnectionRefusedError, FileNotFoundError, OSError) as exc:
            logger.info("Waiting for virtio-serial socket (%s) …", exc)
            await asyncio.sleep(2)


async def hci_reset(hci_sock: socket.socket) -> None:
    """Send HCI Reset to put the controller in a clean state."""
    loop = asyncio.get_running_loop()
    # HCI Reset: type=0x01 (cmd), opcode=0x0c03, param_len=0
    reset_cmd = struct.pack("<BHB", H4_CMD_PKT, 0x0C03, 0)
    await loop.sock_sendall(hci_sock, reset_cmd)
    # Read the Command Complete event response
    resp = await asyncio.wait_for(loop.sock_recv(hci_sock, 64), timeout=5.0)
    if resp and len(resp) >= 4 and resp[0] == H4_EVT_PKT:
        logger.info("HCI Reset complete (response: %s)", resp.hex())
    else:
        logger.warning("HCI Reset unexpected response: %s", resp.hex() if resp else "empty")


async def run_proxy(hci_dev: int, sock_path: str) -> None:
    """Main proxy loop: open HCI, then forward with virtio reconnection."""
    await stop_bluez()
    bring_hci_down(hci_dev)
    hci_sock = open_hci_user_channel(hci_dev)

    # Reset the controller to a clean state — clears any stale scanning
    # or advertising state left from the host's BlueZ session.
    try:
        await hci_reset(hci_sock)
    except Exception as exc:
        logger.warning("HCI Reset failed: %s (continuing anyway)", exc)

    try:
        while True:
            reader, writer = await connect_virtio(sock_path)
            stats = {"hci_to_virtio": 0, "virtio_to_hci": 0}
            try:
                await asyncio.gather(
                    forward_hci_to_virtio(hci_sock, writer, stats),
                    forward_virtio_to_hci(reader, hci_sock, stats),
                )
            except (ConnectionError, OSError) as exc:
                logger.warning("Connection lost: %s  (stats: %s)", exc, stats)
                try:
                    writer.close()
                    await writer.wait_closed()
                except OSError:
                    pass
                await asyncio.sleep(1)
    finally:
        hci_sock.close()
        logger.info("HCI socket closed")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Bluetooth HCI-over-Serial proxy (host side)"
    )
    ap.add_argument(
        "-d", "--device", type=int, default=0,
        help="HCI device index (default: 0)",
    )
    ap.add_argument(
        "-s", "--socket", default="/run/bt-hci-proxy.sock",
        help="Virtio-serial UNIX socket path (default: /run/bt-hci-proxy.sock)",
    )
    ap.add_argument(
        "-v", "--verbose", action="store_true",
        help="Enable debug logging",
    )
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-5s %(name)s: %(message)s",
    )

    loop = asyncio.new_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: sys.exit(0))

    try:
        loop.run_until_complete(run_proxy(args.device, args.socket))
    except KeyboardInterrupt:
        pass
    finally:
        loop.close()


if __name__ == "__main__":
    main()
