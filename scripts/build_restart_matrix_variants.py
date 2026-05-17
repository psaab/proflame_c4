#!/usr/bin/env python3
"""Build throwaway .c4z variants for the driver.xml restart matrix.

The generated packages are for Controller/Navigator testing only. The script does
not modify the working tree. Each generated package receives a monotonically
increasing version derived from --start-version so test installs can be ordered
unambiguously.
"""

from __future__ import annotations

import argparse
import csv
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "scripts" / "manifest.txt"
PACKAGE_NAME = "proflame_wifi_connect.c4z"
NORMALIZED_MTIME = "202001010000.00"


@dataclass(frozen=True)
class Variant:
    name: str
    purpose: str
    edits: tuple[str, ...]


VARIANTS = [
    Variant(
        "baseline-metadata-only",
        "Control package for normal package metadata change only.",
        (),
    ),
    Variant(
        "remove-hold-modes",
        "Test whether runtime HOLD_MODES can replace static <hold_modes>.",
        ("remove_hold_modes",),
    ),
    Variant(
        "remove-preset-flags",
        "Test whether runtime CAN_PRESET/CAN_PRESET_SCHEDULE can replace static preset flags.",
        ("remove_preset_flags",),
    ),
    Variant(
        "remove-fan-hvac-modes",
        "Test whether runtime fan/HVAC allowed-mode publishing can replace static mode lists.",
        ("remove_fan_hvac_modes",),
    ),
    Variant(
        "remove-temperature-ranges",
        "Test whether runtime capability publishing can replace static temperature/setpoint ranges.",
        ("remove_temperature_ranges",),
    ),
    Variant(
        "remove-scheduling-flags",
        "Test whether static scheduling false flags are required for the base thermostat surface.",
        ("remove_scheduling_flags",),
    ),
    Variant(
        "minimal-runtime-capabilities",
        "Combined candidate for smallest static ThermostatV2 capability surface after individual tests pass.",
        (
            "remove_hold_modes",
            "remove_preset_flags",
            "remove_fan_hvac_modes",
            "remove_temperature_ranges",
            "remove_scheduling_flags",
        ),
    ),
]


def read_manifest() -> list[str]:
    return [line.strip() for line in MANIFEST.read_text().splitlines() if line.strip()]


def current_version() -> int:
    text = (ROOT / "driver.lua").read_text()
    match = re.search(r'^DRIVER_VERSION = "(\d+)"', text, re.MULTILINE)
    if not match:
        raise RuntimeError("Could not read DRIVER_VERSION from driver.lua")
    return int(match.group(1))


def replace_line(text: str, tag: str, replacement: str | None) -> str:
    pattern = re.compile(rf"^[ \t]*<{tag}>.*?</{tag}>\n?", re.MULTILINE)
    if not pattern.search(text):
        print(f"WARNING: tag <{tag}> not found in driver.xml; variant may be a no-op.")
        return text
    if replacement is None:
        return pattern.sub("", text)
    return pattern.sub(replacement + "\n", text)


def apply_edit(xml: str, edit: str) -> str:
    if edit == "remove_hold_modes":
        return replace_line(xml, "hold_modes", None)
    if edit == "remove_preset_flags":
        xml = replace_line(xml, "can_preset", None)
        return replace_line(xml, "can_preset_schedule", None)
    if edit == "remove_fan_hvac_modes":
        for tag in ("fan_modes", "hvac_modes", "hvac_states"):
            xml = replace_line(xml, tag, None)
        return xml
    if edit == "remove_temperature_ranges":
        for tag in (
            "current_temperature_min_c",
            "current_temperature_max_c",
            "current_temperature_resolution_c",
            "current_temperature_min_f",
            "current_temperature_max_f",
            "current_temperature_resolution_f",
            "setpoint_heat_min_c",
            "setpoint_heat_max_c",
            "setpoint_heat_resolution_c",
            "setpoint_heat_min_f",
            "setpoint_heat_max_f",
            "setpoint_heat_resolution_f",
            "temperature_scale",
            "split_setpoints",
        ):
            xml = replace_line(xml, tag, None)
        return xml
    if edit == "remove_scheduling_flags":
        for tag in ("scheduling", "can_schedule"):
            xml = replace_line(xml, tag, None)
        return xml
    raise ValueError(f"Unknown edit: {edit}")


def set_package_version(files_dir: Path, version: int) -> None:
    driver_lua = files_dir / "driver.lua"
    lua_text = driver_lua.read_text()
    lua_text = re.sub(r'^DRIVER_VERSION = "\d+"', f'DRIVER_VERSION = "{version}"', lua_text, flags=re.MULTILINE)
    lua_text = re.sub(r'^BUILD_TIMESTAMP = ".*"', f'BUILD_TIMESTAMP = "restart-matrix-{version}"', lua_text, flags=re.MULTILINE)
    driver_lua.write_text(lua_text)

    driver_xml = files_dir / "driver.xml"
    xml_text = driver_xml.read_text()
    xml_text = re.sub(r"<version>\d+</version>", f"<version>{version}</version>", xml_text, count=1)
    xml_text = re.sub(r"<modified>.*?</modified>", "<modified>Restart Matrix Test</modified>", xml_text, count=1)
    driver_xml.write_text(xml_text)

    documentation = files_dir / "www" / "documentation.html"
    html = documentation.read_text()
    html = re.sub(r"<strong>Version:</strong> \d+<br>", f"<strong>Version:</strong> {version}<br>", html, count=1)
    html = re.sub(r"<li><strong>Version:</strong> \d+</li>", f"<li><strong>Version:</strong> {version}</li>", html, count=1)
    documentation.write_text(html)


def build_zip(files_dir: Path, package: Path, manifest_files: list[str]) -> None:
    for path in files_dir.rglob("*"):
        if path.is_dir():
            path.chmod(0o755)
        else:
            path.chmod(0o644)
    subprocess.run(["find", str(files_dir), "-exec", "touch", "-t", NORMALIZED_MTIME, "{}", "+"], check=True)
    if package.exists():
        package.unlink()
    subprocess.run(["zip", "-X", "-q", str(package), *manifest_files], cwd=files_dir, check=True)


def generated_versions(output_dir: Path) -> set[int]:
    versions: set[int] = set()
    for package in output_dir.glob("*.c4z"):
        match = re.search(r"-(\d+)\.c4z$", package.name)
        if match:
            versions.add(int(match.group(1)))
    return versions


def build_variant(output_dir: Path, manifest_files: list[str], variant: Variant, version: int) -> dict[str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        files_dir = Path(tmp)
        for rel in manifest_files:
            src = ROOT / rel
            dst = files_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

        driver_xml = files_dir / "driver.xml"
        xml = driver_xml.read_text()
        for edit in variant.edits:
            xml = apply_edit(xml, edit)
        driver_xml.write_text(xml)
        set_package_version(files_dir, version)

        package = output_dir / f"{variant.name}-{version}.c4z"
        build_zip(files_dir, package, manifest_files)

    return {
        "variant": variant.name,
        "version": str(version),
        "package": str(package),
        "purpose": variant.purpose,
        "static_xml_edits": ", ".join(variant.edits) or "metadata only",
        "director_result": "",
        "driver_reload_result": "",
        "navigator_result": "",
        "notes": "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default="dist/restart-matrix", help="Directory for generated packages and CSV.")
    parser.add_argument("--start-version", type=int, help="First generated package version. Must be greater than current DRIVER_VERSION.")
    parser.add_argument("--list", action="store_true", help="List variants without building packages.")
    args = parser.parse_args()

    if args.list:
        for variant in VARIANTS:
            print(f"{variant.name}: {variant.purpose}")
        return 0

    current = current_version()
    if args.start_version is None:
        raise SystemExit(f"ERROR: provide --start-version greater than current DRIVER_VERSION ({current}).")
    if args.start_version <= current:
        raise SystemExit(f"ERROR: --start-version must be greater than current DRIVER_VERSION ({current}).")

    manifest_files = read_manifest()
    output_dir = (ROOT / args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    requested_versions = {args.start_version + index for index in range(len(VARIANTS))}
    collisions = requested_versions & generated_versions(output_dir)
    if collisions:
        formatted = ", ".join(str(version) for version in sorted(collisions))
        raise SystemExit(
            "ERROR: generated package versions already exist in "
            f"{output_dir}: {formatted}. Use --start-version above any prior "
            "restart-matrix run that may have been installed on a controller."
        )

    rows = []
    for index, variant in enumerate(VARIANTS):
        rows.append(build_variant(output_dir, manifest_files, variant, args.start_version + index))

    csv_path = output_dir / "restart-matrix-results.csv"
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"Built {len(rows)} restart-matrix packages in {output_dir}")
    print(f"Record Controller/Navigator results in {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
