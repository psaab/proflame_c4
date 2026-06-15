# Claude SMR — hostile plan-review r1 (against plan r2) — #81

Stance: hostile. Tried to fail the plan. Result below.

## Independently verified (not taken on faith)

1. **Offender surface (Codex must-fix #1):** confirmed the only vendored direct `log:*` caller is `vendor/github_updater.lua:8` (`local log = log`) with calls at lines 37/59/78/134/165/185. `websocket.lua`/`metrics.lua` use bare `print(...)`, already handled by the shadow. Plan r2 corrected. ✓

2. **Bundle ordering (my own hostile concern — the biggest risk):** the wrapper mutates the `log` object's methods; `github_updater` captures `local log = log`. Verified the load order in `src/driver.lua`:
   - `631` logging bundle → `log = Log:new()` created.
   - `643` github_updater bundle → `local log = log` aliases the **already-created** object.
   - `726-728` load-time `log:setLogName/Mode/Level`.
   The wrap (placed **after 728**) mutates the shared instance; github_updater's alias is the same object, and its `log:warn` runs at **runtime** (during an update), long after the wrap. Dynamic method lookup → wrapped method. **No ordering hole.** Had github_updater been bundled before logging, its alias would be nil and it would already be broken (it isn't) — so log-before-alias is an existing invariant. ✓

3. **`_c4_print` available at wrap time:** captured at `src/driver.lua:464` (idempotent, #79), well before line 728. The wrapper's error branch is safe. ✓

4. **Reload safety:** `log = Log:new()` is a fresh instance every chunk load (Codex confirmed via `vendor/logging.lua` return + bundle). `rawget(log,"_c4_guard_wrapped")` on a fresh instance is nil → wrap; marker prevents intra-load re-wrap. No `_c4_print`-style global-recapture/tail-call hazard because we wrap a per-load object, not a persistent global function. ✓

5. **Restore-previous-value nesting:** `dbg_info → _guarded_log (prev=false→true) → wrapped log:info (prev2=true→true→restore true) → _guarded_log restore false`. Correct; no flag corruption. The unconditional `=false` from r1 would have been wrong only on a future `_log`-re-enters-level-method change, but restore-prev is strictly correct now too. ✓

6. **Regression of #77/#79 tests:** `dbg_info` still yields exactly one captured entry (mirror passes through with guard set); `_c4_print` reload invariant untouched. Existing `test_print_redirect.lua` §6/§7 must stay green — added as a hard gate. ✓

## Remaining concerns (non-blocking)

- **N1 (implementation placement):** the wrapper MUST be inserted after the load-time `log` setup (`src/driver.lua:728`), not earlier. Getting this wrong (placing before `log` exists) would no-op silently. Flag for the implementer; the test (direct `log:warn` single-entry) catches it.
- **N2 (residual, accepted):** a future upstream sync that adds a bare-ref capture (`local w = log.warn`) in a vendored module would bypass the object-method wrap. None today. Acceptable; note in code comment.
- **N3 (Option A redundancy):** `_guarded_log` + wrapper both set the guard for `dbg_*`. With restore-prev this is a harmless no-op and buys nil/pcall safety retention. Documented as intentional. Not a defect.

## Verdict

**PLAN-READY (Option A, r2).** The plan is correct, reload-safe by construction, lowest-risk for a cosmetic fix, and all five Codex must-fixes are addressed. One implementation note (N1: placement after line 728) and a test that fails if it's wrong. Code-stage 4-way review (Codex + AGY + Claude SMR + Copilot) on the actual diff will catch any plan→code drift.
