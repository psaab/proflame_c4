#!/usr/bin/env python3
"""Warn when PRs edit Director-sensitive driver.xml surfaces.

Routine package metadata such as <version> and <modified> changes on every .c4z
build. This check focuses on static install-time declarations that should not
change casually when runtime proxy notifications can express the UI behavior.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys


SENSITIVE_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"<\/?capabilities\b",
        r"<can_",
        r"<has_",
        r"<setpoint_",
        r"<current_temperature_",
        r"<temperature_scale>",
        r"<split_setpoints>",
        r"<scheduling>",
        r"<auto_update>",
        r"<minimum_auto_update_version>",
        r"<hold_modes>",
        r"<fan_modes>",
        r"<hvac_",
        r"<preset_",
        r"<\/?proxies\b",
        r"<proxy\b",
        r"<\/?connections\b",
        r"<connection\b",
        r"<\/?commands\b",
        r"<command\b",
        r"<\/?properties\b",
        r"<property\b",
        r"navigator_display_option",
    ]
]

BODY_ACK_PATTERN = re.compile(
    r"("
    r"(?:director|controller)\s+(?:restart|reload|reloaded|restarted)"
    r"|static\s+(?:xml|driver\.xml)"
    r"|driver\.xml\s+(?:capability|capabilities|proxy|proxies|connection|connections|metadata|property|properties)"
    r"|runtime\s+(?:proxy|capability|capabilities|notification|notifications)"
    r")",
    re.IGNORECASE,
)


def run_git_diff(base_ref: str) -> str:
    result = subprocess.run(
        ["git", "diff", "--unified=0", f"{base_ref}...HEAD", "--", "driver.xml"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return ""
    return result.stdout


def sensitive_changed(diff_text: str) -> list[str]:
    changed: list[str] = []
    for line in diff_text.splitlines():
        if not line.startswith(("+", "-")) or line.startswith(("+++", "---")):
            continue
        text = line[1:].strip()
        if any(pattern.search(text) for pattern in SENSITIVE_PATTERNS):
            changed.append(line)
    return changed


def main() -> int:
    base_ref = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("BASE_REF", "origin/main")
    pr_body = os.environ.get("PR_BODY", "")
    diff_text = run_git_diff(base_ref)
    changed = sensitive_changed(diff_text)

    if not changed:
        print("No sensitive static driver.xml surface changes detected.")
        return 0

    print("Sensitive static driver.xml surface changes detected:")
    for line in changed:
        print(line)

    if BODY_ACK_PATTERN.search(pr_body):
        print("PR body acknowledges static XML / Director restart testing.")
        return 0

    print(
        "\nERROR: PR changes static driver.xml capability/proxy/connection/property metadata.\n"
        "Add a PR note describing whether Director restarted/reloaded, or explain why the\n"
        "static XML change is required instead of a runtime proxy capability refresh.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
