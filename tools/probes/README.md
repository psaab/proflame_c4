# Proflame device probes

Direct WebSocket probes against the live Proflame fireplace device. These are
**investigation tools**, not part of the driver build or the c4z package.
They live here so future contributors can re-run them when adopting new
features (e.g., vendoring the Snap One websocket module) or characterizing
firmware revisions.

## Usage

```sh
python3 tools/probes/characterize.py 172.16.1.81 88
```

Writes a timestamped JSON evidence file to `tools/probes/evidence/`.

## Probes

- `handshake_and_ping.py` — minimal probe; just verifies RFC-6455 handshake
  + WS-level ping/pong. The first probe I wrote, kept as a quick smoke test.
- `characterize.py` — full characterization: handshake, initial status
  dump key set, WS ping/pong, PROFLAMEPONG latency, command format
  compatibility, JSON spacing, multi-control framing, idle push rate,
  idle disconnect detection.
- `_ws.py` — shared WebSocket framing helpers used by the probes above.

## Evidence

Each `characterize.py` run writes a JSON file under `tools/probes/evidence/`.
The directory is checked in so historical firmware-revision behavior can be
diffed across time. Files are small (~10-30KB).

## Caveat: state-change deduplication

The device appears to deduplicate identical control writes — sending
`temperature_set=700` twice when the current value is already `700` only
echoes the first one. The JSON-spacing and multi-control probes in
`characterize.py` are therefore inconclusive on this firmware: they all
send the same value-as-current and rely on echo detection. Don't read the
"IGNORED" labels in those sections as evidence the device rejected the
frame — it may have accepted it and just had nothing to change.

A future probe iteration could roll a value back and forth (700 → 701 →
700) to get conclusive data on parsing tolerance.
