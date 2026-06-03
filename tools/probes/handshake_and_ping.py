#!/usr/bin/env python3
"""Direct WebSocket probe against the Proflame device.

Tests two of the three T1 blockers I cited for the Snap One websocket.lua
vendoring deferral:

  1. Strict handshake — does the device return a fully-RFC-6455-compliant
     101 response with SEC-WEBSOCKET-ACCEPT validating to the correct
     SHA-1(key + GUID) base64 digest?

  2. WS-level ping/pong (opcode 0x09 / 0x0A) — does the device respond to
     a standard WebSocket-level ping frame? If not, the vendored module's
     30s ping + pong-watchdog will false-positive-disconnect every cycle.

The third blocker (binding model: dynamic 6100-6199 vs static 6001) is a
Control4 SDK concern, not testable against the device.

Usage: python3 /tmp/proflame_probe.py 172.16.1.81 88
"""
import base64
import hashlib
import os
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "172.16.1.81"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 88
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def encode_frame(payload: bytes | str, opcode: int = 0x01, masked: bool = True) -> bytes:
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    # First byte: FIN=1 + opcode
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


def decode_frame(data: bytes) -> tuple[int, bytes, int] | None:
    """Returns (opcode, payload, bytes_consumed) or None if incomplete."""
    if len(data) < 2:
        return None
    first = data[0]
    fin = (first >> 7) & 1
    rsv = (first >> 4) & 0x07
    opcode = first & 0x0F
    second = data[1]
    masked = (second >> 7) & 1
    payload_len = second & 0x7F
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


def main() -> int:
    print(f"=== Connecting to {HOST}:{PORT} ===")
    sock = socket.create_connection((HOST, PORT), timeout=5)
    sock.settimeout(5)

    # ----- BLOCKER 2: strict handshake -----
    key_bytes = os.urandom(16)
    key_b64 = base64.b64encode(key_bytes).decode("ascii")
    expected_accept = base64.b64encode(
        hashlib.sha1((key_b64 + GUID).encode("ascii")).digest()
    ).decode("ascii")

    handshake = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key_b64}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"Origin: http://{HOST}\r\n"
        f"\r\n"
    )
    sock.sendall(handshake.encode("ascii"))

    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            print("Device closed connection before completing handshake.")
            return 1
        response += chunk

    header_blob, _, post_header = response.partition(b"\r\n\r\n")
    header_text = header_blob.decode("iso-8859-1", errors="replace")
    print("\n=== HANDSHAKE RESPONSE ===")
    print(header_text)

    status_line = header_text.split("\r\n", 1)[0]
    headers_lc = {
        k.strip().lower(): v.strip()
        for k, v in (
            line.split(":", 1) for line in header_text.split("\r\n")[1:] if ":" in line
        )
    }
    actual_accept = headers_lc.get("sec-websocket-accept")
    upgrade_hdr = headers_lc.get("upgrade", "")
    connection_hdr = headers_lc.get("connection", "")

    print("=== BLOCKER 2 EVIDENCE: strict handshake ===")
    print(f"  Status line:                       {status_line!r}")
    print(f"  Upgrade header (want 'websocket'): {upgrade_hdr!r}")
    print(f"  Connection header (want 'upgrade'): {connection_hdr!r}")
    print(f"  Sec-WebSocket-Accept present:      {actual_accept is not None}")
    if actual_accept:
        match = actual_accept == expected_accept
        print(f"  Sec-WebSocket-Accept matches:      {match}")
        print(f"    expected: {expected_accept}")
        print(f"    actual:   {actual_accept}")
    strict_ok = (
        "101" in status_line
        and "websocket" in upgrade_hdr.lower()
        and "upgrade" in connection_hdr.lower()
        and actual_accept == expected_accept
    )
    print(f"  --> Would pass vendored strict validator: {strict_ok}")

    buf = post_header

    # ----- Read any initial frames after handshake (often a status dump) -----
    sock.settimeout(2)
    try:
        chunk = sock.recv(8192)
        buf += chunk
    except socket.timeout:
        pass

    # ----- Sanity-check: PROFLAMECONNECTION → PROFLAMECONNECTIONOPEN -----
    print("\n=== Sanity: sending PROFLAMECONNECTION (text frame, opcode 0x01) ===")
    sock.sendall(encode_frame("PROFLAMECONNECTION", opcode=0x01, masked=True))

    sock.settimeout(3)
    text_responses: list[str] = []
    deadline = time.time() + 3
    while time.time() < deadline:
        try:
            chunk = sock.recv(8192)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            break
        # Drain all complete frames from buf
        while True:
            decoded = decode_frame(buf)
            if decoded is None:
                break
            opcode, payload, consumed = decoded
            buf = buf[consumed:]
            if opcode == 0x01:
                try:
                    text_responses.append(payload.decode("utf-8"))
                except UnicodeDecodeError:
                    text_responses.append(f"<non-utf8 {len(payload)}B>")
            else:
                text_responses.append(f"<opcode 0x{opcode:02x} {len(payload)}B>")
        # Stop early if we got PROFLAMECONNECTIONOPEN
        if any("PROFLAMECONNECTIONOPEN" in t for t in text_responses):
            break

    print(f"  Received {len(text_responses)} frame(s) after PROFLAMECONNECTION:")
    for t in text_responses[:8]:
        print(f"    {t[:120]!r}")

    # ----- BLOCKER 3: WS-level ping (opcode 0x09) -----
    print("\n=== BLOCKER 3 EVIDENCE: WS-level PING (opcode 0x09) ===")
    print("  Sending a standard WebSocket ping frame (FIN=1, opcode=0x09)...")
    sock.sendall(encode_frame(b"hi", opcode=0x09, masked=True))

    ws_pong_received = False
    ws_text_after_ping: list[str] = []
    saw_close = False

    deadline = time.time() + 4
    sock.settimeout(2)
    while time.time() < deadline:
        try:
            chunk = sock.recv(8192)
            if not chunk:
                print("  Device closed connection.")
                saw_close = True
                break
            buf += chunk
        except socket.timeout:
            break
        while True:
            decoded = decode_frame(buf)
            if decoded is None:
                break
            opcode, payload, consumed = decoded
            buf = buf[consumed:]
            if opcode == 0x0A:
                ws_pong_received = True
                print(f"    <- PONG (opcode 0x0A, payload={payload!r})")
            elif opcode == 0x08:
                saw_close = True
                print(f"    <- CLOSE (opcode 0x08, payload={payload!r})")
            elif opcode == 0x01:
                try:
                    ws_text_after_ping.append(payload.decode("utf-8"))
                except UnicodeDecodeError:
                    ws_text_after_ping.append("<non-utf8>")
            else:
                print(f"    <- opcode 0x{opcode:02x} payload={payload[:40]!r}")
        if ws_pong_received or saw_close:
            break

    print(f"  WS-level PONG received within 4s? {ws_pong_received}")
    print(f"  Connection closed by device?      {saw_close}")
    if ws_text_after_ping:
        print(f"  Other text traffic during window: {len(ws_text_after_ping)} frame(s)")
        for t in ws_text_after_ping[:4]:
            print(f"    {t[:100]!r}")
    if not ws_pong_received and not saw_close and not ws_text_after_ping:
        print("  --> Device silently ignored the WS-level ping.")
    elif ws_pong_received:
        print("  --> Device DID respond with a proper WS-level pong.")
    elif saw_close:
        print("  --> Device CLOSED the connection in response to the ping.")

    # ----- Sanity-check: PROFLAMEPING (text) still works after WS ping -----
    print("\n=== Sanity: PROFLAMEPING (text) after the WS-level ping ===")
    sock.sendall(encode_frame("PROFLAMEPING", opcode=0x01, masked=True))
    got_pong = False
    deadline = time.time() + 3
    while time.time() < deadline:
        try:
            chunk = sock.recv(8192)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            break
        while True:
            decoded = decode_frame(buf)
            if decoded is None:
                break
            opcode, payload, consumed = decoded
            buf = buf[consumed:]
            if opcode == 0x01:
                try:
                    text = payload.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if "PROFLAMEPONG" in text:
                    got_pong = True
                    print(f"    <- {text!r}")
                    break
        if got_pong:
            break
    print(f"  PROFLAMEPONG received? {got_pong}")

    # Polite close
    try:
        sock.sendall(encode_frame(b"\x03\xe8", opcode=0x08, masked=True))
    except Exception:
        pass
    sock.close()

    print("\n=== SUMMARY ===")
    print(f"  Strict handshake passes vendored validator: {strict_ok}")
    print(f"  Device responds to WS-level ping (0x09):    {ws_pong_received}")
    print(f"  Device closes on WS-level ping:             {saw_close}")
    print(f"  PROFLAMEPING text keepalive still works:    {got_pong}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
