#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 drdecibel
"""Validate config.yml and the device profiles against the constraints the
SmartThings upload API enforces, and against the driver source.

`edge:drivers:package --build-only` does not check any of this; the API only
rejects it at upload time, so it is checked here instead.
"""

from pathlib import Path
import re
import sys

import yaml

# Enforced by the driver upload API.
PACKAGE_KEY_PATTERN = re.compile(r"^[a-zA-Z0-9 _/\-()\[\]{}.]{1,36}$")

ROOT = Path(__file__).resolve().parent.parent
problems = []


def fail(message):
    problems.append(message)


def load(path):
    with path.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


config = load(ROOT / "config.yml")

for field in ("name", "packageKey", "description", "permissions"):
    if not config.get(field):
        fail(f"config.yml is missing {field}")

package_key = config.get("packageKey", "")
if not PACKAGE_KEY_PATTERN.match(package_key):
    fail(
        f"packageKey {package_key!r} ({len(package_key)} characters) does not match "
        f"the API pattern {PACKAGE_KEY_PATTERN.pattern}"
    )

for permission in config.get("permissions", {}):
    if permission not in ("lan", "discovery"):
        fail(f"config.yml declares an unexpected permission: {permission}")

profiles = {}
for path in sorted((ROOT / "profiles").glob("*.yml")):
    profile = load(path)
    name = profile.get("name")
    if not name:
        fail(f"{path.name} has no profile name")
        continue
    profiles[name] = profile
    for component in profile.get("components", []):
        if not component.get("id"):
            fail(f"{path.name} has a component without an id")
        if not component.get("capabilities"):
            fail(f"{path.name} component {component.get('id')} declares no capabilities")

source = (ROOT / "src" / "init.lua").read_text(encoding="utf-8")
constants = (ROOT / "src" / "constants.lua").read_text(encoding="utf-8")

block = re.search(r"C\.PROFILE\s*=\s*\{(.*?)\}", constants, re.S)
referenced = re.findall(r'"([^"]+)"', block.group(1)) if block else []
if not referenced:
    fail("src/constants.lua does not define C.PROFILE")
for name in referenced:
    if name not in profiles:
        fail(f"src/constants.lua uses profile {name!r}, but only {sorted(profiles)} exist")

# Placeholder defaults in the profiles must match what the driver treats as
# "not configured".
for pref, constant in (("ipAddress", "PLACEHOLDER_IP"), ("deviceId", "PLACEHOLDER_ID"),
                       ("localKey", "PLACEHOLDER_KEY"), ("dpMap", "DEFAULT_DP_MAP")):
    value = re.search(rf'C\.{constant}\s*=\s*"([^"]*)"', constants)
    for name, profile in profiles.items():
        prefs = {p["name"]: p for p in profile.get("preferences", [])}
        default = prefs.get(pref, {}).get("definition", {}).get("default")
        if not value or default != value.group(1):
            fail(f"{name}: preference {pref} default {default!r} does not match C.{constant}")

# Every profile must offer the same preferences, or switching profile loses settings.
pref_names = {name: [p["name"] for p in prof.get("preferences", [])] for name, prof in profiles.items()}
if len({tuple(v) for v in pref_names.values()}) > 1:
    fail(f"profiles declare different preferences: {pref_names}")

for name, profile in profiles.items():
    for component in profile.get("components", []):
        if component["id"] != "main" and f'"{component["id"]}"' not in source \
                and f'components.{component["id"]}' not in source:
            fail(f"{name} component {component['id']} is never referenced by src/init.lua")
        for capability in component.get("capabilities", []):
            capability_id = capability.get("id")
            if capability_id and f"capabilities.{capability_id}" not in source:
                fail(
                    f"{name} component {component['id']} declares capability "
                    f"{capability_id}, which src/init.lua never references"
                )
    for pref in profile.get("preferences", []):
        if pref["name"] not in source and pref["name"] not in \
                (ROOT / "src" / "discovery.lua").read_text(encoding="utf-8"):
            fail(f"{name}: preference {pref['name']} is never read by the driver")

if problems:
    for problem in problems:
        print(f"MANIFEST: {problem}")
    sys.exit(1)

print(f"Manifest check: packageKey {package_key!r} "
      f"({len(package_key)} characters) and {len(profiles)} profile(s) are valid.")
