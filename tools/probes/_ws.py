"""Tiny shared WebSocket client for Proflame device probes.

Not a general-purpose WS lib — covers only what the probes need:
  - RFC-6455 client handshake with SHA-1(key + GUID) base64 accept verify
  - Single-frame TEXT send (FIN=1, opcode=0x01, masked)
  - Frame-stream decoder yielding (opcode, payload) tuples
  - Polite close (opcode 0x08)
"""
from __future__ import annotations
import base64
import hashlib
import os
import re
import socket
import struct
import time

# Matches the Lua driver's strict status-line check (src/driver.lua
# ValidateHandshakeResponse) so probe evidence aligned with the live
# validator. A line like "HTTP/1.1 1010 Weird" would be rejected here even
# though it contains the substring "101".
#
# re.ASCII is load-bearing: without it, Python's \d and \s would match
# Unicode digits and Unicode whitespace (e.g. NBSP, U+00A0) that Lua's
# %d and %s do NOT match. Without the flag, a status line like
# "HTTP/1.1\xa0101\xa0Switching" passes here but fails the live driver,
# producing a misleading "strict-compatible" probe verdict.
_STATUS_LINE_101_RE = re.compile(r"^HTTP/\d+\.\d+\s+101\s", re.ASCII)

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def open_ws(host: str, port: int, timeout: float = 5.0):
    """Open a WS connection. Returns (sock, leftover_bytes, header_text, strict_ok)."""
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    key_bytes = os.urandom(16)
    key_b64 = base64.b64encode(key_bytes).decode("ascii")
    expected = base64.b64encode(
        hashlib.sha1((key_b64 + GUID).encode("ascii")).digest()
    ).decode("ascii")
    request = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key_b64}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"Origin: http://{host}\r\n\r\n"
    ).encode("ascii")
    sock.sendall(request)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("device closed before completing handshake")
        buf += chunk
    header_blob, _, leftover = buf.partition(b"\r\n\r\n")
    header_text = header_blob.decode("iso-8859-1", errors="replace")
    status_line = header_text.split("\r\n", 1)[0]
    headers_lc = {
        k.strip().lower(): v.strip()
        for k, v in (
            line.split(":", 1) for line in header_text.split("\r\n")[1:] if ":" in line
        )
    }
    strict_ok = (
        bool(_STATUS_LINE_101_RE.match(status_line))
        and headers_lc.get("upgrade", "").lower() == "websocket"
        and "upgrade" in headers_lc.get("connection", "").lower()
        and headers_lc.get("sec-websocket-accept") == expected
    )
    return sock, leftover, header_text, strict_ok


def encode_frame(payload, opcode=0x01, masked=True):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    out = bytearray([0x80 | opcode])
    length = len(payload)
    mask_bit = 0x80 if masked else 0
    if length <= 125:
        out.append(mask_bit | length)
    elif length <= 65535:
        out.append(mask_bit | 126)
        out.extend(struct.pack(">H", length))
    else:
        out.append(mask_bit | 127)
        out.extend(struct.pack(">Q", length))
    if masked:
        mask_key = os.urandom(4)
        out.extend(mask_key)
        masked_payload = bytearray(length)
        for i, b in enumerate(payload):
            masked_payload[i] = b ^ mask_key[i % 4]
        out.extend(masked_payload)
    else:
        out.extend(payload)
    return bytes(out)


def decode_one(data):
    if len(data) < 2:
        return None
    opcode = data[0] & 0x0F
    masked = (data[1] >> 7) & 1
    payload_len = data[1] & 0x7F
    offset = 2
    if payload_len == 126:
        if len(data) < 4:
            return None
        payload_len = struct.unpack(">H", data[2:4])[0]
        offset = 4
    elif payload_len == 127:
        if len(data) < 10:
            return None
        payload_len = struct.unpack(">Q", data[2:10])[0]
        offset = 10
    if masked:
        if len(data) < offset + 4:
            return None
        mask_key = data[offset : offset + 4]
        offset += 4
    if len(data) < offset + payload_len:
        return None
    payload = data[offset : offset + payload_len]
    if masked:
        unmasked = bytearray(payload_len)
        for i, b in enumerate(payload):
            unmasked[i] = b ^ mask_key[i % 4]
        payload = bytes(unmasked)
    return opcode, payload, offset + payload_len


def drain_frames(sock, buf, window_sec):
    """Yield (timestamp, opcode, payload) tuples for `window_sec` seconds."""
    deadline = time.monotonic() + window_sec
    while time.monotonic() < deadline:
        try:
            sock.settimeout(max(0.1, deadline - time.monotonic()))
            chunk = sock.recv(8192)
        except socket.timeout:
            chunk = b""
        if not chunk and not buf:
            break
        if chunk:
            buf += chunk
        while True:
            decoded = decode_one(buf)
            if decoded is None:
                break
            opcode, payload, consumed = decoded
            buf = buf[consumed:]
            yield (time.monotonic(), opcode, payload)


def close(sock):
    try:
        sock.sendall(encode_frame(b"\x03\xe8", opcode=0x08, masked=True))
    except Exception:
        pass
    try:
        sock.close()
    except Exception:
        pass
