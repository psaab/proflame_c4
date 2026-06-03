# `driver.xml` capability matrix

Research output for [issue #39](https://github.com/psaab/proflame_c4/issues/39). Enumerates every field declared inside `<capabilities>` in `driver.xml` and classifies each by what the official ThermostatV2 SDK explicitly documents (not by reading our own runtime code). Identifies candidates for removal in [issue #41](https://github.com/psaab/proflame_c4/issues/41) pending hardware A/B verification.

**This document is research only.** No fields are removed here.

## How the classifications were built

A Python script fetched `https://snap-one.github.io/docs-driverworks-proxyprotocol-tstat/` on 2026-06-03 and grep'd each `<h4>` capability section for the string `DYNAMIC_CAPABILITIES_CHANGED`. Sections containing that string are SDK-supported for runtime updates; sections that don't (or fields not in the SDK list at all) are not.

This is **more authoritative than the matrix in the earlier draft of this document**, which relied on reading the runtime helpers and projecting. An earlier review by Codex caught that the projection misclassified several fields.

## Classification key

| Class | Meaning |
|---|---|
| `RUNTIME_OK` | SDK section explicitly says "can be changed through a `DYNAMIC_CAPABILITIES_CHANGED` notification" AND `BuildThermostatDynamicCapabilities` already emits it. Candidate for static-XML removal pending hardware verification. |
| `RUNTIME_AVAILABLE` | SDK supports dynamic updates but our driver doesn't currently emit. Prep work (adding the runtime publish) is prerequisite to static removal. |
| `STATIC_PER_SDK` | SDK section explicitly does NOT contain `DYNAMIC_CAPABILITIES_CHANGED`. Field must remain static. |
| `UNDOCUMENTED` | Field is in our `driver.xml` but is NOT in the SDK's capability list at all. Could be legacy/deprecated, vendor-specific, or undocumented. Default to static; investigate before assuming runtime-changeable. |
| `IDENTITY` | Driver/package metadata. Not behavioral; must remain static. |

## Known runtime-emit-but-SDK-static discrepancies

`BuildThermostatDynamicCapabilities` (src/driver.lua:1150) emits `HVAC_MODES` and `HVAC_STATES` keys via `DYNAMIC_CAPABILITIES_CHANGED`. **The SDK explicitly classifies both `hvac_modes` and `hvac_states` as static** (no `DYNAMIC_CAPABILITIES_CHANGED` mention in their sections). The behavior on the proxy of receiving these keys via a dynamic notification is undefined per the SDK. The driver SHOULD use `ALLOWED_HVAC_MODES_CHANGED` (a separate, documented notification) to update which subset of the statically-declared modes is currently allowed — which `SendThermostatAllowedModes` already does. The dynamic-capability emit appears redundant at best, undefined-behavior at worst. Worth filing as a separate cleanup issue.

## Capability matrix

Status as of `2026060203`. Every field in `driver.xml` lines 460-510 is listed; coverage verified (39 scalar capability tags + 1 `<navigator_display_option>` block = 40 declarations).

### Temperature / scale (9 fields)

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `has_extras` | `true` | RUNTIME_OK | `BuildThermostatDynamicCapabilities` → `HAS_EXTRAS = "true"` | SDK marks `has_extras` dynamic |
| `current_temperature_min_c` | `-40` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `current_temperature_max_c` | `60` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `current_temperature_resolution_c` | `0.5` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `current_temperature_min_f` | `-40` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `current_temperature_max_f` | `140` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `current_temperature_resolution_f` | `1` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `can_change_scale` | `True` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `temperature_scale` | `FAHRENHEIT` | UNDOCUMENTED | None | Not in SDK capability list; may be a legacy or vendor-specific field |

### HVAC capability flags (8 fields)

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `can_heat` | `True` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `can_cool` | `False` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `can_do_auto` | `False` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `can_preset` | `False` | RUNTIME_OK | `BuildThermostatDynamicCapabilities` → `CAN_PRESET = "False"` | SDK marks dynamic |
| `can_preset_schedule` | `False` | RUNTIME_OK | `BuildThermostatDynamicCapabilities` → `CAN_PRESET_SCHEDULE = "False"` | SDK marks dynamic |
| `has_outdoor_temperature` | `False` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `split_setpoints` | `False` | UNDOCUMENTED | None | Not in SDK capability list |
| `can_schedule` | `False` | UNDOCUMENTED | None | Not in SDK capability list |

### Setpoint heat range (6 fields)

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `setpoint_heat_min_c` | `15.5` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `setpoint_heat_max_c` | `32.2` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `setpoint_heat_resolution_c` | `0.5` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `setpoint_heat_min_f` | `60` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `setpoint_heat_max_f` | `90` | RUNTIME_AVAILABLE | None | SDK marks dynamic |
| `setpoint_heat_resolution_f` | `1` | RUNTIME_AVAILABLE | None | SDK marks dynamic |

### Mode lists (4 fields)

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `scheduling` | `False` | STATIC_PER_SDK | None | SDK does NOT mark dynamic |
| `hvac_modes` | `Off,Heat` | STATIC_PER_SDK | Driver emits `HVAC_MODES` via `DYNAMIC_CAPABILITIES_CHANGED` — see "Known discrepancies" above; SDK does NOT support this. Use `ALLOWED_HVAC_MODES_CHANGED` (separate notification, already emitted by `SendThermostatAllowedModes`) for runtime mode-set updates. | SDK marks STATIC |
| `hold_modes` | `Low Flame,Medium Flame,High Flame` | RUNTIME_OK | `BuildThermostatDynamicCapabilities` → `HOLD_MODES = FLAME_HOLD_MODES` AND `UpdateHoldModeCapabilities` | SDK marks dynamic |
| `hvac_states` | `Off,Heat` | STATIC_PER_SDK | Driver emits `HVAC_STATES` via `DYNAMIC_CAPABILITIES_CHANGED` — same situation as `hvac_modes` above. | SDK marks STATIC |

### UI capability flags (8 fields)

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `can_set_backlight` | `False` | UNDOCUMENTED | None | Not in SDK capability list |
| `has_time_settings` | `False` | UNDOCUMENTED | None | Not in SDK capability list |
| `can_change_fan_count` | `False` | UNDOCUMENTED | None | Not in SDK capability list |
| `has_emergency_heat` | `False` | UNDOCUMENTED | None | Not in SDK capability list |
| `can_change_hvac_modes` | `True` | UNDOCUMENTED | None | Not in SDK capability list |
| `has_vacation_mode` | `False` | STATIC_PER_SDK | None | SDK does NOT mark dynamic |
| `has_remote_sensor` | `False` | STATIC_PER_SDK | None | SDK does NOT mark dynamic |
| `has_single_setpoint` | `True` | RUNTIME_AVAILABLE | None | SDK marks dynamic |

### Fan modes (3 fields)

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `has_fan_mode` | `True` | UNDOCUMENTED | None | Not in SDK capability list |
| `can_change_fan_modes` | `True` | UNDOCUMENTED | None | Not in SDK capability list |
| `fan_modes` | `Off,Low,Medium,High` | RUNTIME_OK | `BuildThermostatDynamicCapabilities` → `FAN_MODES = "..."` AND `SendThermostatAllowedModes` → `ALLOWED_FAN_MODES_CHANGED` | SDK marks dynamic |

### Setpoint shortcut

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `can_inc_dec_setpoints` | `True` | RUNTIME_AVAILABLE | None | SDK marks dynamic |

### Navigator display

| Field | Current XML | Class | Runtime helper | SDK reference |
|---|---|---|---|---|
| `<navigator_display_option>` | (icon set) | IDENTITY | None | Install-time icon block parsed by Composer |

## Class summary (regenerated from rows above)

Tallied directly from the table rows. Total: 39 scalar fields + 1 `<navigator_display_option>` block = **40 declarations**.

| Class | Count | Fields |
|---|---|---|
| `RUNTIME_OK` | 5 | `has_extras`, `can_preset`, `can_preset_schedule`, `hold_modes`, `fan_modes` |
| `RUNTIME_AVAILABLE` | 19 | 6 `current_temperature_*` + 6 `setpoint_heat_*` + `can_change_scale`, `can_heat`, `can_cool`, `can_do_auto`, `has_outdoor_temperature`, `has_single_setpoint`, `can_inc_dec_setpoints` |
| `STATIC_PER_SDK` | 5 | `scheduling`, `hvac_modes`, `hvac_states`, `has_vacation_mode`, `has_remote_sensor` |
| `UNDOCUMENTED` | 10 | `temperature_scale`, `split_setpoints`, `can_schedule`, `can_set_backlight`, `has_time_settings`, `can_change_fan_count`, `has_emergency_heat`, `can_change_hvac_modes`, `has_fan_mode`, `can_change_fan_modes` |
| `IDENTITY` | 1 | `<navigator_display_option>` |
| **TOTAL** | **40** | |

## Methodology for #41

The existing `scripts/build_restart_matrix_variants.py` (added in PR #42) generates **grouped** removal variants, not per-field. The script defines 7 package variants:

| Variant name | Removes (from `apply_edit` function in the script) |
|---|---|
| `baseline-metadata-only` | nothing — control variant for comparison |
| `remove-hold-modes` | `hold_modes` (1 field) |
| `remove-preset-flags` | `can_preset` + `can_preset_schedule` (2 fields) |
| `remove-fan-hvac-modes` | `fan_modes` + `hvac_modes` + `hvac_states` (3 fields) |
| `remove-temperature-ranges` | 6 `current_temperature_*` + 6 `setpoint_heat_*` + `temperature_scale` + `split_setpoints` (**14 fields total** — script lines 112-128 include the last two, easy to miss when describing this variant) |
| `remove-scheduling-flags` | `scheduling` + `can_schedule` (2 fields) |
| `minimal-runtime-capabilities` | combined removal of all the above non-baseline variants in one package |

This means a single A/B install measures a **group's** behavior, not a per-field effect. For most groups that's fine — the fields cluster naturally (e.g., temperature ranges are visually one block in Navigator). For #41's per-field PRs, the recommended sequence:

1. **Use the existing `remove-preset-flags` variant first** (smallest group, both fields already `False`, both already runtime-emitted via `BuildThermostatDynamicCapabilities`). If Variant A and B render identically and Director behaves the same, file the removal PR for the pair.
2. **Use `remove-hold-modes`** next.
3. **Use `remove-fan-hvac-modes`** — but note this removes `fan_modes` (RUNTIME_OK), `hvac_modes` and `hvac_states` (both STATIC_PER_SDK per matrix). The latter two should NOT be removed without first migrating their runtime emit to `ALLOWED_HVAC_MODES_CHANGED`-only. The current grouped variant tests the wrong thing for those two fields; recommended action is to add a per-field variant or split this group.
4. **Use `remove-scheduling-flags`** to test `scheduling` + `can_schedule` removal. Both are `False` and our driver doesn't emit either at runtime, so this is a low-risk static-XML cleanup.
5. **Add a new variant** to the script for the RUNTIME_AVAILABLE preparation work (e.g., add runtime emits for the 6 `setpoint_heat_*` fields, then test grouped removal via an enhanced `remove-temperature-ranges` variant). This is the largest piece of follow-up work because 19 fields are in this class.

Hyphens vs underscores: the variant **package names** use hyphens (`remove-fan-hvac-modes`); the **edit keys** inside `apply_edit` use underscores (`remove_fan_hvac_modes`). When grep'ing the script or shell-invoking the builder, match the form used at each call site.

## What #39 still needs

- ✅ A documented XML-change matrix (this PR's deliverable, corrected per Codex review)
- ✅ Centralized runtime capability refresh function (`RefreshThermostatUiSurface` from PR #40)
- ✅ PR template/smoke-checklist gate for static XML changes (already in `.github/pull_request_template.md` from PR #28 era)
- ❌ Composer/Navigator test notes identifying which XML field causes Director restart (still requires hardware A/B testing per the methodology above)

The fourth criterion is the only remaining gap; it's gated by controller-side install time. This PR therefore **does not close #39** — the matrix is the research foundation but the hardware observation row in the issue's acceptance criteria stays empty until at least one per-field PR lands with controller observations.

## Suggested follow-up issues to file

1. **`hvac_modes` / `hvac_states` runtime-emit-but-SDK-static** — the driver pushes both via `DYNAMIC_CAPABILITIES_CHANGED` but the SDK doesn't document those keys as dynamic. Use `ALLOWED_HVAC_MODES_CHANGED` only. Low-priority cleanup; the emit is probably silently ignored by the proxy.
2. **Per-field variants in `build_restart_matrix_variants.py`** — the current grouped variants can't isolate single-field effects, which #41's per-field methodology assumes. Either add per-field variants or update #41's PR sequence to use grouped removals throughout.
3. **`UNDOCUMENTED` fields** — 10 fields in our `driver.xml` aren't in the SDK's capability list at all. Some may be legacy fields the SDK dropped, some may be vendor-specific. Researching what each one actually controls (vs. just leaving them static defensively) could surface additional removal candidates or reveal that some are no-ops.
