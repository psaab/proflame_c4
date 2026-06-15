# Plan-of-action — #81: vendored direct `log:*` calls bypass the print-shadow re-entrancy guard

- **Issue:** #81 (cosmetic double-log: vendored module log lines appear as `[DEBUG]: …[WARN ]: …`)
- **Revision:** r1
- **Branch:** `fix/81-log-guard-vendored`

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

### Option A (additive, lowest diff)
Keep `_guarded_log` and `dbg_*` exactly as-is. Additionally wrap the `log` object's level methods to also set `_c4_in_logger`. Vendored direct calls are now covered.
- Pros: does not touch the #77/#79-tested `dbg_*` path; smallest diff.
- Cons: two mechanisms set the same flag (redundant); a reviewer will rightly flag the duplication; `dbg_*` calls set the flag twice (nested, harmless).

### Option B (single mechanism — RECOMMENDED)
Move the guard entirely to the `log` object. Wrap `log.error/warn/info/debug/trace/fatal/log` so each sets `_c4_in_logger` around the real method (pcall-protected). Revert `dbg_*` to direct `log:level(...)` calls and **remove `_guarded_log`**. The wrapper is the single guard point covering both driver and vendored callers.
- Pros: one mechanism, complete coverage, net-simpler end state, no redundancy.
- Cons: touches the `dbg_*` bodies (reverting #77's `_guarded_log` indirection) — but the #77/#79 behavioral invariants are preserved by the wrapper and re-asserted by the existing tests.

**Recommendation: Option B.** #77's `_guarded_log` was an incomplete fix (covered only our calls); the proper layer is the log object, which subsumes it. The end state is simpler and complete.

### Wrapper sketch (Option B), placed right after the logging bundle sets up `log`:
```lua
-- #81: set the print-shadow re-entrancy guard at the log object so EVERY log
-- call (driver dbg_* AND vendored modules' direct log:warn/info/etc.) marks
-- _c4_in_logger, ensuring the logger's console-mirror print() lands in the
-- shadow's pass-through branch instead of being re-routed through dbg_debug
-- (which double-prefixed vendored lines "[DEBUG]: [WARN]..."). `log` is a fresh
-- Log:new() on every chunk load (incl. reload), so each load wraps a clean
-- object; the rawset marker guards against re-wrapping within one load.
if log and not rawget(log, "_c4_guard_wrapped") then
    rawset(log, "_c4_guard_wrapped", true)
    for _, _lvl in ipairs({ "error", "warn", "info", "debug", "trace", "fatal", "log" }) do
        local _orig = log[_lvl]
        if type(_orig) == "function" then
            log[_lvl] = function(self, ...)
                _c4_in_logger = true
                local _ok, _err = pcall(_orig, self, ...)
                _c4_in_logger = false
                if not _ok then _c4_print("Proflame log error: " .. tostring(_err)) end
            end
        end
    end
end
```
`dbg_*` simplify back to e.g. `function dbg_warn(msg) log:warn("%s", tostring(msg)) end`.

## 5. Ordering / reload safety

- Wrap must run **after** `log = Log:new()` (the logging bundle) and after `_c4_print` is captured (it's used in the error branch). Both exist by the load-time logging setup block — place the wrap immediately after `log:setLogLevel(...)`.
- Wrapping mutates the instance's method table; vendored `local log = log` aliases share the instance, so they see the wrapped methods at call time (runtime calls happen well after load).
- Reload: `log` is a fresh instance → `rawget(log,"_c4_guard_wrapped")` is nil → wrap fresh. The previous instance is GC'd. No tail-call/recapture hazard (unlike #79's global function capture; here we wrap a per-load object).

## 6. Risks & mitigations

- **R1: double-wrap within a load** → guarded by the `rawget` marker.
- **R2: regression of #77 (ordinary `dbg_info` logs once) / #79 (reload `_c4_print`)** → preserved: `dbg_info → log:info(wrapped, guard set) → mirror → shadow pass-through → one entry`. Re-asserted by `test_print_redirect.lua` §6/§7 (must stay green).
- **R3: a vendored module that captured a bare function ref (`local w = log.warn`) before wrap would bypass** → none found; vendored code calls via the object (`log:warn`). Note as a residual.
- **R4: load-time vendored log calls before the wrap (e.g. `Metrics:new`)** → those happen during bundle execution before the wrap; they'd still double-log at load only. Minor / acceptable; the offenders (#81's examples) are runtime.
- **R5: performance** → one pcall per log call; negligible.

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

Ship **Option B** (single guard at the log object; remove `_guarded_log`). It fully closes #81, is reload-safe by construction (fresh per-load object), and leaves a simpler logging path than the current #77 state.
