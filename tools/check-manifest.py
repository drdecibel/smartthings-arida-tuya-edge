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
for pref, constant in (("ipAddress", "AUTO_IP"), ("deviceId", "PLACEHOLDER_ID"),
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
            referenced_here = f"capabilities.{capability_id}" in source or (
                "." in capability_id and f'"{capability_id}"' in constants)
            if capability_id and not referenced_here:
                fail(
                    f"{name} component {component['id']} declares capability "
                    f"{capability_id}, which src/init.lua never references"
                )
    for pref in profile.get("preferences", []):
        if pref["name"] not in source and pref["name"] not in \
                (ROOT / "src" / "discovery.lua").read_text(encoding="utf-8"):
            fail(f"{name}: preference {pref['name']} is never read by the driver")

# Custom capabilities: definition, presentation and the driver's labels agree.
import json


def list_items(pres):
    """Every list entry in the presentation, with the attribute or command it uses."""
    for item in pres.get("detailView", []):
        if item.get("displayType") == "list":
            lst = item["list"]
            yield lst["command"]["name"], lst["command"]["alternatives"]
            yield lst["state"]["value"].split(".")[0], lst["state"]["alternatives"]
    for section in ("conditions", "actions"):
        for item in pres.get("automation", {}).get(section, []):
            if item.get("displayType") == "list":
                lst = item["list"]
                yield lst.get("command") or lst["value"].split(".")[0], lst["alternatives"]


for definition in sorted((ROOT / "capabilities").glob("*.json")):
    if definition.name.endswith(".presentation.json"):
        continue
    cap = json.loads(definition.read_text(encoding="utf-8"))
    pres_path = definition.with_name(definition.stem + ".presentation.json")
    if not pres_path.exists():
        fail(f"{definition.name} has no presentation file")
        continue
    pres = json.loads(pres_path.read_text(encoding="utf-8"))
    enums = {}
    for name, attr in cap["attributes"].items():
        enums[name] = attr["schema"]["properties"]["value"].get("enum")
    for name, command in cap.get("commands", {}).items():
        enums[name] = command["arguments"][0]["schema"].get("enum")
    for target, alternatives in list_items(pres):
        keys = sorted(a["key"] for a in alternatives)
        if target not in enums:
            fail(f"{pres_path.name}: list refers to unknown attribute or command {target!r}")
        elif enums[target] is None or keys != sorted(enums[target]):
            fail(f"{pres_path.name}: {target} alternatives {keys} do not match its enum {enums[target]}")
    if pres.get("id") not in constants:
        fail(f"{pres_path.name}: capability id {pres.get('id')!r} is not used in src/constants.lua")
arida = (ROOT / "src" / "arida.lua").read_text(encoding="utf-8")
for key, label in re.findall(r'\{value = "(\w+)", label = "([^"]+)"\}', arida):
    presentation = (ROOT / "capabilities" / "ventilationMode.presentation.json").read_text(encoding="utf-8")
    if f'"key": "{key}", "value": "{label}"' not in presentation:
        fail(f"mode {key} is labelled {label!r} in src/arida.lua but not in the presentation")

if problems:
    for problem in problems:
        print(f"MANIFEST: {problem}")
    sys.exit(1)

print(f"Manifest check: packageKey {package_key!r} "
      f"({len(package_key)} characters) and {len(profiles)} profile(s) are valid.")
