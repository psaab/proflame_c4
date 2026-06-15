# Plan-of-action — #81: vendored direct `log:*` calls bypass the print-shadow re-entrancy guard

- **Issue:** #81 (cosmetic double-log: vendored module log lines appear as `[DEBUG]: …[WARN ]: …`)
- **Revision:** r2 (addresses Codex plan-review PLAN-REVISE)
- **Branch:** `fix/81-log-guard-vendored`

## r2 changelog (from Codex hostile plan-review)
1. Coverage corrected: the **only** vendored direct `log:*` caller is `vendor/github_updater.lua` (lines 37, 59, 78, 134, 165, 185). `websocket.lua` and `metrics.lua` use bare `print(...)`, which already routes through the shadow → `dbg_debug` (gated, single — intended). Not offenders.
2. Recommendation flipped to **Option A (additive)** — keep `_guarded_log` (retains its nil/pcall safety + the #77/#79-tested `dbg_*` path); just add the log-method wrapper for the vendored case. Lower risk for a cosmetic fix.
3. Wrapper teardown uses **restore-previous-value** (not unconditional `false`) so nesting (dbg_* → `_guarded_log` sets guard → wrapped `log:level`) is correct and future-proof.
4. Wrap list completed to every emit method: `fatal, error, warn, info, debug, trace, ultra, log, print`.
5. R4 corrected: no confirmed load-time `log:*` offender (`Metrics:new` does not log); only a theoretical residual window remains.

## 1. Problem statement

After #69 (print shadow) + #77 (re-entrancy guard) + #79 (reload-safe capture), the driver routes vendored `print()` through the gated logger. The #77 guard (`_c4_in_logger`) is set **only** inside `_guarded_log`, the chokepoint the driver's own `dbg_*` helpers funnel through. Vendored modules (`github_updater.lua`, `drivers-common-public/module/websocket.lua`, `metrics.lua`, …) call `log:warn` / `log:info` / `log:debug` / `log:trace` **directly** on the shared `log` object, bypassing `_guarded_log`. Their console-mirror `print()` therefore reaches the shadow with the guard clear and is re-routed once through `dbg_debug`, producing a duplicate `[DEBUG]: [WARN ]: …` line for every direct vendored log call.

Severity: log-only (no functional impact), but it doubles vendored log volume and mislabels levels (a `WARN` shows a second time tagged `DEBUG`), which can bury real warnings during debugging — e.g. the updater’s `invalid tag version 'last-known-working'` warning appears twice.

## 2. Blast radius

- `src/driver.lua`: the logging chokepoint (`_guarded_log`, `dbg_*`), the print shadow, and the load-time logging setup (around lines 419–549 and 726–731). `log` is created by the bundled `vendor/logging.lua` (`log = Log:new()` at the bundle site).
- Confirmed facts (verified):
  - `vendor/logging.lua` ends with `return Log:new()`; the bundle emits `log = Log:new()`, so **`log` is a FRESH instance on every chunk load, including Control4 hot reload.** No persistent-object double-wrap hazard.
  - Vendored modules alias the **same** object (`local log = log`), so wrapping the object's methods is seen by all aliases (method lookup is dynamic through the instance).
  - `vendor/logging.lua:_log` mirrors to global `print()` in "Print and Log" mode (the path that hits the shadow).
- No driver.xml / capability / command / proxy / connection surface touched. No device-protocol code touched.

## 3. Root cause

The guard is attached to the **wrong layer**: `_guarded_log` only wraps the driver's `dbg_*` calls. The correct layer is the shared `log` object's level methods, which **every** caller (driver `dbg_*` AND vendored direct calls) funnels through.

## 4. Design — path options

### Option A (additive — RECOMMENDED)
Keep `_guarded_log` and `dbg_*` exactly as-is (preserving their nil/pcall safety and the #77/#79-tested path). Additionally wrap the `log` object's emit methods so each ALSO sets `_c4_in_logger` (restore-previous-value). This extends guard coverage to the vendored `github_updater.lua` direct `log:*` calls.
- Pros: does not touch the tested `dbg_*`/`_guarded_log` path; retains nil/pcall safety; smallest behavioral risk.
- Cons: for `dbg_*` calls both `_guarded_log` and the wrapper set the flag — but with restore-previous-value this is a harmless no-op (prev already true). Documented as intentional defense-in-depth, not a bug.

### Option B (single mechanism — REJECTED for this fix)
Remove `_guarded_log`, revert `dbg_*` to direct `log:level(...)`, make the wrapper the sole guard.
- Cleaner end state, BUT Codex flagged it trades away `_guarded_log`'s nil/pcall crash-safety (`src/driver.lua:466-472`) for early-init `dbg_*` calls. For a **cosmetic** fix that risk isn't worth it. Deferred as possible future cleanup, not part of #81.

**Recommendation: Option A.** Lowest-risk path that fully closes #81; keeps the proven #77/#79 logging path intact.

### Wrapper sketch (Option A), placed right after the load-time `log:setLogLevel(...)`:
```lua
-- #81: also set the print-shadow re-entrancy guard at the log OBJECT so any
-- caller that bypasses dbg_*/_guarded_log — notably vendored modules that call
-- log:warn/info/etc. DIRECTLY (vendor/github_updater.lua) — still marks
-- _c4_in_logger. Then the logger's console-mirror print() lands in the shadow's
-- pass-through branch instead of being re-routed through dbg_debug (which
-- double-prefixed vendored lines "[DEBUG]: [WARN]..."). `log` is a fresh
-- Log:new() on every chunk load (incl. Control4 hot reload), so each load wraps
-- a clean instance; the rawset marker guards against re-wrapping within a load.
-- restore-previous-value (not a bare `= false`) keeps nesting correct, e.g.
-- dbg_info -> _guarded_log (sets guard) -> wrapped log:info (keeps it set).
if log and not rawget(log, "_c4_guard_wrapped") then
    rawset(log, "_c4_guard_wrapped", true)
    for _, _lvl in ipairs({ "fatal", "error", "warn", "info", "debug", "trace", "ultra", "log", "print" }) do
        local _orig = log[_lvl]
        if type(_orig) == "function" then
            log[_lvl] = function(self, ...)
                local _prev = _c4_in_logger
                _c4_in_logger = true
                local _ok, _err = pcall(_orig, self, ...)
                _c4_in_logger = _prev
                if not _ok and type(_c4_print) == "function" then
                    _c4_print("Proflame log error: " .. tostring(_err))
                end
            end
        end
    end
end
```
`_guarded_log` and `dbg_*` are UNCHANGED.

## 5. Ordering / reload safety

- Wrap must run **after** `log = Log:new()` (the logging bundle) and after `_c4_print` is captured (it's used in the error branch). Both exist by the load-time logging setup block — place the wrap immediately after `log:setLogLevel(...)`.
- Wrapping mutates the instance's method table; vendored `local log = log` aliases share the instance, so they see the wrapped methods at call time (runtime calls happen well after load).
- Reload: `log` is a fresh instance → `rawget(log,"_c4_guard_wrapped")` is nil → wrap fresh. The previous instance is GC'd. No tail-call/recapture hazard (unlike #79's global function capture; here we wrap a per-load object).

## 6. Risks & mitigations

- **R1: double-wrap within a load** → guarded by the `rawget` marker.
- **R2: regression of #77 (ordinary `dbg_info` logs once) / #79 (reload `_c4_print`)** → preserved: `dbg_info → log:info(wrapped, guard set) → mirror → shadow pass-through → one entry`. Re-asserted by `test_print_redirect.lua` §6/§7 (must stay green).
- **R3: a vendored module that captured a bare function ref (`local w = log.warn`) before wrap would bypass** → grep confirms NONE; the only vendored `local log = log` alias (`github_updater.lua:8`) calls via the object (`log:warn`), so method lookup is dynamic through the wrapped instance. Residual only if a future upstream sync adds a bare-ref capture.
- **R4: load-time vendored `log:*` before the wrap** → **no confirmed case** (Codex: `handlers.lua` calls `Metrics:new` at load but `Metrics:new` does not log; `github_updater`'s `log:*` calls are all inside methods invoked at runtime). Only a theoretical residual window remains; accepted.
- **R5: performance** → one pcall per log call; negligible.
- **R6: wrapper return value** → the wrapped emit methods (`warn/info/...`/`_log`) return nothing meaningful and no caller uses their return; the wrapper intentionally returns nothing. (Non-emit methods like `getLogLevel` are NOT wrapped.)

## 7. Test plan

- New `test_print_redirect.lua` section: a vendored-style **direct** `log:warn("VENDOR_DIRECT_81")` produces **exactly one** captured log line, and it is a `[WARN]` line (not a re-routed `[DEBUG]`). (Before fix: two entries.)
- Assert the wrap marker is set after load and re-wrapping is a no-op.
- Existing §6 (ordinary `dbg_info` single entry) and §7 (reload `_c4_print` invariant) MUST remain green.
- Full suite green.

## 8. Rollback

Single-file change in `src/driver.lua` (+ test + version/docs). Revert the commit; no data/migration concerns.

## 9. Out of scope

- The cosmetic load-time double-log from vendored top-level code (R4) — accepted.
- Any change to the vendored files (kept byte-identical to upstream).

## 10. Reviewers

- Plan: Codex (design) + hostile Claude SMR. AGY + Copilot review the **diff** at engineer time (they review code, not prose).
- Code: Codex + AGY adversarial + Claude SMR + Copilot (PR).

## 11. Recommendation

Ship **Option A** (additive log-object wrapper; keep `_guarded_log`). It fully closes #81 (the `github_updater.lua` direct `log:*` double-log), is reload-safe by construction (fresh per-load `Log:new()` instance + marker), uses restore-previous-value for correct nesting, and leaves the proven #77/#79 `dbg_*` path untouched — the lowest-risk path for a cosmetic fix. The single-mechanism Option B is deferred as optional future cleanup (it would trade away `_guarded_log`'s nil/pcall safety).
