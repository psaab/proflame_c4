# Proflame device characterization & driver cleanup roadmap

Findings from direct WebSocket probes against the live fireplace at
`172.16.1.81:88` on 2026-06-02. Device firmware `FW: 625.04.673`.

Evidence file: `tools/probes/evidence/characterize-20260603T024355Z.json`.

## TL;DR — what the data tells us

The device speaks **standards-compliant RFC 6455 WebSocket**. Three "blockers"
that drove the T1 vendoring deferral were speculative; direct measurement
disproves two of them. The bigger story is that the device sends **79 status
keys, of which our driver explicitly handles 12** — there's a substantial
ergonomic and reliability surface we're leaving on the table.

## Probe-by-probe findings

### 1. Handshake — strict RFC 6455 compliance ✓

Device returns:
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: <SHA-1(key + GUID), base64-encoded, validates>
```

→ The `Strict WebSocket Handshake = Off` Composer property and the lenient
"any response containing '101' is OK" fallback path in
`ValidateHandshakeResponse` are dead code on this firmware. **Cleanup
opportunity #1.**

### 2. Initial status dump — 79 keys, 5 frames

After `PROFLAMECONNECTION`, device pushes 5 text frames containing 85 indexed
`statusN`/`valueN` pairs across 79 unique keys.

**Our driver handles 12 of these 79 keys** (15%). The other 67 are
silently logged via `dbg_all("Ignoring unsupported JSON status key: ...")`
on every single reconnect.

Categorized inventory of unhandled keys (full list in the JSON evidence):

| Category | Count | Examples |
|---|---|---|
| Capability flags (`en_*`) | 17 | `en_fan`, `en_flame`, `en_lamp`, `en_pilot`, `en_th`, `en_weekly` |
| Firmware versions (`fw_*`) | 4 | `fw_ble`, `fw_ifc_c`, `fw_ifc_s`, `fw_rc` |
| LED/RGB controls | 13 | `led_main`, `rgb_0_intensity`, `rgbw_0_code` |
| Weekly schedule (`p_day_*`) | 7 | `p_day_1` through `p_day_7` |
| OTA/system | 6 | `ota_dongle`, `ota_touch`, `free_heap`, `min_free_heap`, `modbus_ifc` |
| Device identity | 4 | `dongle_name`, `dongle_type`, `scenario_name`, `label_aux` |
| Other (potentially user-relevant) | 16 | **`child_lock`**, **`pilot_mode`**, **`remote_control`**, **`auxiliary_out`**, **`split_flow`**, **`temperature_unit`**, `idx_room`, `index_aux`, `pilot_mode`, etc. |

The bold ones are user-relevant semantics the driver currently throws away.
**`temperature_unit` is the most important** — the device tells us F vs C,
and we hard-code "Fahrenheit × 10" everywhere. If the user has set their
fireplace to display Celsius, our temperature display is wrong.

→ **Cleanup opportunities #4 (temperature_unit), #5 (firmware versions for
diagnostics), #6 (silence the 67-line noise spam).**

### 3. WS-level ping/pong (opcode 0x09 → 0x0A) ✓

Sent `0x89 ... b"probe-ws-ping"`; device responded with `0x8A ... b"probe-ws-ping"`
(payload echoed verbatim) AND continued pushing normal status frames in
parallel. No connection close.

→ The vendored Snap One `websocket.lua` module's 30-second WS-level ping +
pong-watchdog cycle will work without override. **T1 blocker #3 disproven.**

### 4. PROFLAMEPONG latency — 5 samples

```
4.3ms, 104.6ms, 155.0ms, 74.2ms, 190.8ms
min 4.3ms · median 104.6ms · max 190.8ms
```

Highly variable but always responds within 200ms. Zero timeouts across 5
samples.

→ Our default ping interval of 5 seconds gives **4.8+ seconds of headroom**
between ping cycles. No tuning required.

### 5. Command format — legacy works, documented untested-but-suspected-broken

`{"control0":"temperature_set","value0":"700"}` — **accepted** (echoed back
in a status frame within 2 seconds).

`{"command":"set_control","name":"temperature_set","value":"700"}` — **no
echo within 2 seconds**.

**Caveat:** the second test is inconclusive because the device deduplicates
identical control writes. After the first command set temperature_set=700,
subsequent setpoint=700 writes produce no echo regardless of format.

The conservative conclusion: legacy works (confirmed); documented format
**probably still rejected** on this firmware, consistent with the audit
trail from PRs #18 → #37. Don't change `Command Format` default.

### 6. JSON spacing sensitivity — inconclusive

All 5 variants (no-spaces, space-after-colon, space-after-comma, all-spaces,
leading-trailing-whitespace) produced 0 echoes. Same deduplication caveat.

→ The spec's claim "no spaces" survives unrebuked, but unverified. The
no-spaces invariant the QW2 review confirmed via JSON.lua's alphabetical-key
output should hold regardless.

### 7. Multi-control in one frame — inconclusive (same dedup issue)

### 8. Spontaneous status push rate

**0 frames in a 10-second silence window after the initial dump.** The device
does NOT push spontaneously during idle. Status updates arrive only:
- In response to `PROFLAMECONNECTION` (initial dump)
- In response to a command (echo)
- Probably: when state actually changes (e.g., temperature crosses
  setpoint, timer ticks) — not measured here

→ **Reliability implication:** if someone physically presses a button on the
fireplace's local control panel while the driver is idle, we may not see the
change until the next user-initiated command or reconnect. Worth documenting
as a known limitation. May want a periodic `PROFLAMECONNECTION` refresh
on a long timer (e.g., every 5 minutes) to catch local state changes.

### 9. Idle disconnect window — at least 15 seconds, probably much longer

Device kept the connection open for the entire 15-second silent window. Our
driver's 5-second ping cycle dominates anyway, but worth knowing the device
isn't aggressive about idle eviction.

## Prioritized cleanup roadmap

Ordered by **(value per line) / risk**.

### Tier A — pure cleanup, low risk, evidence-backed

| # | Change | Estimated size | Risk |
|---|---|---|---|
| **A1** | Drop `Strict WebSocket Handshake = Off` property + lenient 101 fallback. Probe proves the device returns RFC-compliant handshake; the property and the `AllowLenientHandshakeFallback` path are dead code. | ~30 lines deleted, 1 property removed from driver.xml (static-surface change) | Low — fallback was a safety net we don't need |
| **A2** | Suppress the "Ignoring unsupported JSON status key" log spam by adding an explicit allowlist of "known but unused" keys (the 55 non-user-relevant unhandled keys identified above). Skip at DEBUG level entirely. | ~60 lines (1 set literal + 1 guard) | Negligible |
| **A3** | Expose `temperature_unit` as a read-only Composer property and use it to gate the °F vs °C display in `DecodeTemperature`'s call sites. | ~30 lines + 1 property | Low if guarded — wrong display if user has device in °C is a real-world bug |

### Tier B — feature additions, data-supported

| # | Change | Estimated size | Risk |
|---|---|---|---|
| **B1** | Concatenate the five firmware fields (`fw_revision`, `fw_ble`, `fw_ifc_c`, `fw_ifc_s`, `fw_rc`) into a single read-only `Firmware Versions` Composer property. Useful for support diagnostics. | ~20 lines + 1 property | Negligible — read-only |
| **B2** | Handle `child_lock`, `pilot_mode`, `remote_control`, `auxiliary_out`, `split_flow` as read-only Composer properties. They're already being sent; we just need to wire `gState` entries + property updates. | ~50 lines + 5 properties | Low — read-only surface |
| **B3** | Periodic `PROFLAMECONNECTION` refresh every 5 minutes to catch state changes the device hasn't pushed (local-panel inputs). | ~15 lines | Low |

### Tier C — structural changes

| # | Change | Estimated size | Risk |
|---|---|---|---|
| **C1** | Vendor Snap One's `drivers-common-public/module/websocket.lua` (T1). Probe disproves the two behavioral blockers (strict handshake, WS ping). Binding-model decision: **drop the static `<connection id="6001">` binding from `driver.xml` and let the vendored `websocket.lua` allocate dynamically via `C4:CreateNetworkConnection` (scanning 6100-6199)** — this is the vendored module's native idiom. **LANDED:** Phase 1 (vendor only, inert) shipped as driver `2026060301` (PR #67). Phase 2 (actual cutover) shipped as driver `2026060302`: deleted the 9 hand-rolled WS helpers + PROFLAMEPING infrastructure; removed `NETWORK_BINDING_ID` and the `<connection id="6001">` element; wired our top-level `OnConnectionStatusChanged` / `ReceivedFromNetwork` to delegate to `OCS[netBinding]` / `RFN[netBinding]`; added 4 callbacks (`OnWebSocketEstablished`/`Message`/`Offline`/`ClosedByRemote`). New `test/test_websocket_integration.lua` replays the captured probe transcript through the new path. | Net: −250 lines of hand-rolled WS code, +650 vendored | Moderate — substantial code swap; mitigated by the captured probe transcript as a replay test |

### Tier D — deferred

| # | Reason |
|---|---|
| **D1** | LED/RGB controls (13 keys). The device exposes them but we have no proxy/UI for them in Composer's thermostat surface. Document as out-of-scope. |
| **D2** | Weekly schedule (`p_day_*`, `index_weekly`, `en_weekly`). Not exposed by ThermostatV2 proxy. Out-of-scope for this driver. |
| **D3** | Definitive command-format and JSON-spacing tests would require deliberately toggling a value back and forth. Worth doing only if/when we have a reason to suspect the QW2-era contract has broken. |

## Recommended PR sequence

Land in this order, each as its own PR:

1. **Probes commit** (this PR) — `tools/probes/` + evidence + FINDINGS.md
2. **Tier A1** — drop strict-handshake fallback (low-risk, evidence-backed deletion)
3. **Tier A2** — silence unhandled-key log spam (zero risk)
4. **Tier B1** — firmware-versions property (read-only, no surface risk)
5. **Tier A3** — temperature_unit handling (real-world bug fix; needs care to not break F-default users)
6. **Tier B2** — additional read-only properties for child_lock/pilot_mode/etc. (single PR)
7. **Tier B3** — periodic refresh
8. **Tier C1** — T1 websocket vendoring, with replayed probe transcript as the test (when ready)

Each Tier-A/B PR is independently shippable and reverts cleanly. Tier C is
the only one that's a full structural swap.

## Probe re-run instructions

```sh
python3 tools/probes/characterize.py 172.16.1.81 88
```

Re-run after firmware upgrades to detect behavior changes; diff the JSON
evidence files in `tools/probes/evidence/` across runs to catch silent
drift.

## Related research

- `tools/research/capability_matrix.md` — full `driver.xml` `<capabilities>` field-by-field classification (RUNTIME_OK / RUNTIME_AVAILABLE / STATIC_REQUIRED / STATIC_RECOMMENDED) supporting issues #39 (restart investigation) and #41 (static capability reduction). Identifies which fields are safe candidates for runtime-only publishing pending hardware A/B verification.
