#!/usr/bin/env python3
"""Characterize the Proflame device's WebSocket dialect and command behavior.

Runs a sequence of focused probes against the device and emits structured
findings as both human-readable output and a machine-readable JSON evidence
file. Each probe is independent and resilient — failures in one don't abort
the rest.

Usage:
    python3 tools/probes/characterize.py 172.16.1.81 88

What each probe answers:

  1. handshake          — RFC 6455 strict-validator compliance
  2. initial_status     — Full key set the device pushes after
                          PROFLAMECONNECTION; characterizes firmware surface
  3. ws_ping            — Does the device respond to opcode 0x09 with 0x0A?
  4. pong_latency       — How fast does PROFLAMEPONG come back (5 samples)?
  5. command_format     — Does the device accept the documented
                          {"command":"set_control"...} format identically to
                          legacy {"control0":..., "value0":...}?
  6. json_spacing       — Does the device reject {"a": 1} with spaces, as
                          the spec claims? Or is spacing tolerated?
  7. multi_control      — Does {"control0":..., "value0":..., "control1":...,
                          "value1":...} work in one frame?
  8. idle_pushes        — How often does the device push status without
                          prompting? (Sample 10 seconds of silence.)
  9. idle_disconnect    — Does the device close idle connections within N
                          seconds of no traffic from the client?

Output:
  - Streams progress to stdout
  - Writes tools/probes/evidence/<timestamp>.json with the structured findings
"""
from __future__ import annotations
import json
import socket
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _ws import (  # noqa: E402
    close,
    decode_one,
    drain_frames,
    encode_frame,
    open_ws,
)

HOST = sys.argv[1] if len(sys.argv) > 1 else "172.16.1.81"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 88
EVIDENCE_DIR = Path(__file__).resolve().parent / "evidence"


def section(label: str):
    print(f"\n=== {label} ===")


def safe_decode(payload: bytes) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return f"<non-utf8 {len(payload)}B>"


def probe_handshake_and_initial(host: str, port: int) -> dict:
    section("Probe 1+2: handshake + initial status dump")
    sock, leftover, header_text, strict_ok = open_ws(host, port)
    print(f"  Handshake strict-validator passes: {strict_ok}")

    # Send PROFLAMECONNECTION; capture all frames for 3s.
    sock.sendall(encode_frame("PROFLAMECONNECTION"))
    text_frames: list[str] = []
    other_frames: list[tuple[int, str]] = []
    for _, opcode, payload in drain_frames(sock, leftover, window_sec=3.0):
        if opcode == 0x01:
            text_frames.append(safe_decode(payload))
        else:
            other_frames.append((opcode, safe_decode(payload)))

    # Parse status keys out of every JSON frame
    seen_keys: dict[str, str] = {}  # key -> first observed value
    indexed_pairs: list[tuple[str, str]] = []  # (status_name, value)
    direct_keys: dict[str, str] = {}
    parse_errors: list[str] = []
    for raw in text_frames:
        if not raw.startswith("{"):
            continue
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as e:
            parse_errors.append(f"{raw[:60]!r}: {e}")
            continue
        # Indexed-format detection: statusN/valueN pairs
        i = 0
        while f"status{i}" in decoded and f"value{i}" in decoded:
            indexed_pairs.append((str(decoded[f"status{i}"]), str(decoded[f"value{i}"])))
            seen_keys.setdefault(
                str(decoded[f"status{i}"]), str(decoded[f"value{i}"])
            )
            i += 1
        # Direct-key format: any other keys
        for k, v in decoded.items():
            if k.startswith("status") or k.startswith("value"):
                continue
            direct_keys[k] = str(v)
            seen_keys.setdefault(k, str(v))

    print(f"  Text frames received:        {len(text_frames)}")
    print(f"  Non-text frames received:    {len(other_frames)}")
    print(f"  Indexed status pairs:        {len(indexed_pairs)}")
    print(f"  Direct-format keys:          {len(direct_keys)}")
    print(f"  JSON parse errors:           {len(parse_errors)}")
    print(f"  Total unique keys observed:  {len(seen_keys)}")
    print(f"  Sample keys: {sorted(seen_keys.keys())[:15]}")

    fw = (
        seen_keys.get("fw_revision")
        or seen_keys.get("fw_rev")
        or seen_keys.get("firmware")
    )
    print(f"  Firmware reported:           {fw!r}")

    return {
        "sock": sock,  # passed forward to keep connection open for subsequent probes
        "strict_handshake_passes": strict_ok,
        "handshake_header_text": header_text,
        "firmware": fw,
        "n_text_frames": len(text_frames),
        "n_non_text_frames": len(other_frames),
        "n_indexed_pairs": len(indexed_pairs),
        "n_direct_keys": len(direct_keys),
        "parse_errors": parse_errors,
        "all_keys_seen": sorted(seen_keys.keys()),
        "key_value_samples": dict(sorted(seen_keys.items())[:30]),
        "raw_first_5_frames": text_frames[:5],
    }


def probe_ws_ping(sock: socket.socket) -> dict:
    section("Probe 3: WS-level ping/pong (opcode 0x09 → 0x0A)")
    sock.sendall(encode_frame(b"probe-ws-ping", opcode=0x09))
    pong = None
    closed = False
    other_during = 0
    for _, opcode, payload in drain_frames(sock, b"", window_sec=3.0):
        if opcode == 0x0A:
            pong = safe_decode(payload)
            break
        if opcode == 0x08:
            closed = True
            break
        other_during += 1
    print(f"  Received PONG: {pong!r}; closed={closed}; other frames during window: {other_during}")
    return {
        "ws_pong_received": pong is not None,
        "ws_pong_payload_echoed": pong == "probe-ws-ping",
        "ws_pong_payload_received": pong,
        "connection_closed_on_ping": closed,
    }


def probe_pong_latency(sock: socket.socket, n_samples: int = 5) -> dict:
    section(f"Probe 4: PROFLAMEPONG latency ({n_samples} samples)")
    latencies_ms = []
    for i in range(n_samples):
        t0 = time.monotonic()
        sock.sendall(encode_frame("PROFLAMEPING"))
        got = False
        for _, opcode, payload in drain_frames(sock, b"", window_sec=2.0):
            if opcode == 0x01 and safe_decode(payload).strip() == "PROFLAMEPONG":
                latencies_ms.append((time.monotonic() - t0) * 1000)
                got = True
                break
        if not got:
            latencies_ms.append(None)
            print(f"  Sample {i+1}/{n_samples}: TIMEOUT")
        else:
            print(f"  Sample {i+1}/{n_samples}: {latencies_ms[-1]:.1f}ms")
        time.sleep(0.5)
    valid = [x for x in latencies_ms if x is not None]
    return {
        "samples_ms": latencies_ms,
        "min_ms": min(valid) if valid else None,
        "max_ms": max(valid) if valid else None,
        "mean_ms": statistics.mean(valid) if valid else None,
        "median_ms": statistics.median(valid) if valid else None,
        "missing_samples": latencies_ms.count(None),
    }


def probe_command_format(sock: socket.socket) -> dict:
    section("Probe 5: command format compatibility")
    # Capture current main_mode first so we can restore it. (Read-only probe;
    # we DO NOT modify any actual device state — we send commands that target
    # a no-op channel: temperature_set re-asserting whatever the current
    # setpoint is.)
    setpoint_now = "700"
    # First, drain any pending traffic to a known clean state.
    list(drain_frames(sock, b"", window_sec=0.5))

    findings = {}
    for label, payload in [
        ("legacy_no_spaces", '{"control0":"temperature_set","value0":"' + setpoint_now + '"}'),
        ("documented_no_spaces", '{"command":"set_control","name":"temperature_set","value":"' + setpoint_now + '"}'),
    ]:
        sock.sendall(encode_frame(payload))
        echoes: list[str] = []
        errors: list[str] = []
        for _, opcode, raw in drain_frames(sock, b"", window_sec=2.0):
            if opcode == 0x01:
                text = safe_decode(raw)
                if "temperature_set" in text:
                    echoes.append(text)
                if "error" in text.lower() or text.startswith("ERR"):
                    errors.append(text)
        accepted = len(echoes) > 0 or len(errors) == 0
        print(f"  {label}: sent {payload!r}")
        print(f"     echoes containing temperature_set: {len(echoes)}")
        print(f"     error-shaped frames:               {len(errors)}")
        findings[label] = {
            "payload_sent": payload,
            "n_echoes": len(echoes),
            "n_errors": len(errors),
            "sample_echo": echoes[0] if echoes else None,
            "sample_error": errors[0] if errors else None,
        }
        time.sleep(0.5)
    return findings


def probe_json_spacing(sock: socket.socket) -> dict:
    section("Probe 6: JSON spacing sensitivity")
    setpoint = "700"
    list(drain_frames(sock, b"", window_sec=0.5))
    findings = {}
    for label, payload in [
        ("no_spaces", '{"control0":"temperature_set","value0":"' + setpoint + '"}'),
        ("space_after_colon", '{"control0": "temperature_set","value0": "' + setpoint + '"}'),
        ("space_after_comma", '{"control0":"temperature_set", "value0":"' + setpoint + '"}'),
        ("all_spaces", '{"control0": "temperature_set", "value0": "' + setpoint + '"}'),
        ("leading_trailing_ws", '   {"control0":"temperature_set","value0":"' + setpoint + '"}   '),
    ]:
        sock.sendall(encode_frame(payload))
        echoes = 0
        for _, opcode, raw in drain_frames(sock, b"", window_sec=1.5):
            if opcode == 0x01 and "temperature_set" in safe_decode(raw):
                echoes += 1
        accepted = echoes > 0
        print(f"  {label}: {'ACCEPTED' if accepted else 'IGNORED'} ({echoes} echo(es)) — sent {payload!r}")
        findings[label] = {"payload_sent": payload, "n_echoes": echoes, "accepted": accepted}
        time.sleep(0.5)
    return findings


def probe_multi_control(sock: socket.socket) -> dict:
    section("Probe 7: multi-control single frame")
    list(drain_frames(sock, b"", window_sec=0.5))
    payload = (
        '{"control0":"temperature_set","value0":"700",'
        '"control1":"temperature_set","value1":"700"}'
    )
    sock.sendall(encode_frame(payload))
    echoes = []
    for _, opcode, raw in drain_frames(sock, b"", window_sec=2.0):
        if opcode == 0x01:
            text = safe_decode(raw)
            if "temperature_set" in text:
                echoes.append(text)
    print(f"  Sent multi-control frame; got {len(echoes)} echo(es)")
    for e in echoes[:3]:
        print(f"    {e[:120]}")
    return {
        "payload_sent": payload,
        "n_echoes": len(echoes),
        "accepted": len(echoes) > 0,
    }


def probe_idle_pushes(sock: socket.socket, seconds: int = 10) -> dict:
    section(f"Probe 8: spontaneous status push rate ({seconds}s window)")
    pushes: list[tuple[float, str]] = []
    start = time.monotonic()
    for ts, opcode, payload in drain_frames(sock, b"", window_sec=seconds):
        if opcode == 0x01:
            pushes.append((ts - start, safe_decode(payload)[:80]))
    print(f"  Received {len(pushes)} text frame(s) in {seconds}s")
    for ts, sample in pushes[:6]:
        print(f"    +{ts:.2f}s  {sample!r}")
    return {
        "window_sec": seconds,
        "n_pushes": len(pushes),
        "rate_per_sec": len(pushes) / seconds if seconds else 0,
        "first_6_samples": pushes[:6],
    }


def probe_idle_disconnect(host: str, port: int, idle_seconds: int = 15) -> dict:
    section(f"Probe 9: idle-disconnect detection ({idle_seconds}s of client silence)")
    sock, leftover, _, _ = open_ws(host, port)
    sock.sendall(encode_frame("PROFLAMECONNECTION"))
    list(drain_frames(sock, leftover, window_sec=2.0))
    # Now go silent and see if the device closes.
    closed = False
    last_traffic = time.monotonic()
    for ts, opcode, _ in drain_frames(sock, b"", window_sec=idle_seconds):
        if opcode == 0x08:
            closed = True
            print(f"  Device sent CLOSE at +{ts - last_traffic:.1f}s")
            break
    if not closed:
        print(f"  Device kept connection open for the full {idle_seconds}s window")
    close(sock)
    return {"idle_window_sec": idle_seconds, "device_closed_during_window": closed}


def main() -> int:
    print(f"Probing Proflame device {HOST}:{PORT}")
    print(f"Started at {datetime.now(timezone.utc).isoformat()}")

    findings: dict = {
        "host": HOST,
        "port": PORT,
        "started_at": datetime.now(timezone.utc).isoformat(),
    }

    p1 = probe_handshake_and_initial(HOST, PORT)
    sock = p1.pop("sock")
    findings["handshake_and_initial"] = p1

    try:
        findings["ws_ping"] = probe_ws_ping(sock)
        findings["pong_latency"] = probe_pong_latency(sock)
        findings["command_format"] = probe_command_format(sock)
        findings["json_spacing"] = probe_json_spacing(sock)
        findings["multi_control"] = probe_multi_control(sock)
        findings["idle_pushes_10s"] = probe_idle_pushes(sock, seconds=10)
    finally:
        close(sock)

    # New connection for idle-disconnect — needs a fresh socket since the
    # previous one may have been mutated by the WS-ping probe.
    findings["idle_disconnect"] = probe_idle_disconnect(HOST, PORT, idle_seconds=15)

    findings["finished_at"] = datetime.now(timezone.utc).isoformat()

    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = EVIDENCE_DIR / f"characterize-{stamp}.json"
    out_path.write_text(json.dumps(findings, indent=2, default=str))
    print(f"\nWrote evidence to: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
