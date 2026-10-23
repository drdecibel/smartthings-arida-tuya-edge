#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 drdecibel
"""Send the ventilators' device IDs and local keys from tinytuya's
devices.json to the SmartThings hub, so nothing has to be typed in the app.

    python tools/push-keys.py

Leave it running, then in the SmartThings app choose Add device -> Scan
nearby (or just install/update the driver: it asks once at start-up). The
hub broadcasts a request on UDP 47811; this script answers only the hub, on
the local network. Keys are never printed.

Options:
  --devices PATH   devices.json (default: ./devices.json, then ~/Documents, then ~)
  --hub IP         answer only this address (default: the hub the SmartThings
                   CLI knows, or any requester if there is none)
  --all            send every Tuya device, not only ventilators
  --minutes N      give up after N minutes (default 10)
"""

import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path

SETUP_PORT = 47811
REQUEST = b"ARIDA-TUYA-SETUP 1"
VENTILATOR_CATEGORIES = {"fs", "xfj"}


def find_devices_json(explicit):
    if explicit:
        return Path(explicit)
    for candidate in (Path("devices.json"), Path.home() / "Documents" / "devices.json",
                      Path.home() / "devices.json"):
        if candidate.is_file():
            return candidate
    sys.exit("devices.json not found. Run `python -m tinytuya wizard` first, or pass --devices PATH.")


def known_hub():
    """The hub address the SmartThings CLI has connected to (logcat)."""
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".local" / "share")
    for path in (Path(base) / "@smartthings" / "cli" / "Data" / "known_hubs.json",
                 Path.home() / ".local" / "share" / "@smartthings" / "cli" / "known_hubs.json"):
        try:
            hubs = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for address in hubs:
            return address.split(":")[0]
    return None


def is_ventilator(d):
    text = f"{d.get('name', '')} {d.get('product_name', '')}".lower()
    return d.get("category") in VENTILATOR_CATEGORIES or "ventil" in text


def load_units(path, include_all):
    devices = json.loads(path.read_text(encoding="utf-8"))
    units = []
    for d in devices:
        if not d.get("id") or len(d.get("key") or "") != 16:
            continue
        if not include_all and not is_ventilator(d):
            continue
        unit = {"id": d["id"], "key": d["key"], "name": d.get("name") or d.get("product_name")}
        if d.get("ip"):
            unit["ip"] = d["ip"]
        if d.get("version"):
            unit["version"] = str(d["version"])
        units.append(unit)
    return units


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--devices")
    parser.add_argument("--hub")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--minutes", type=float, default=10)
    args = parser.parse_args()

    path = find_devices_json(args.devices)
    units = load_units(path, args.all)
    if not units:
        sys.exit(f"No ventilators with a local key in {path}. Use --all to send every Tuya device.")
    hub = args.hub or known_hub()
    reply = json.dumps({"arida_setup": 1, "units": units}, separators=(",", ":")).encode()

    print(f"Read {len(units)} ventilator(s) from {path}:")
    for u in units:
        print(f"  - {u['name']}")
    print(f"Answering {'the hub at ' + hub if hub else 'any SmartThings hub'} on UDP {SETUP_PORT}.")
    print("Now open the SmartThings app and choose Add device -> Scan nearby.")
    print("(If Windows Firewall asks, allow Python on private networks.)")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", SETUP_PORT))
    except OSError as err:
        sys.exit(f"Cannot listen on UDP {SETUP_PORT}: {err}")
    sock.settimeout(1.0)

    deadline = time.monotonic() + args.minutes * 60
    sent = 0
    done_at = None
    try:
        while time.monotonic() < deadline and (done_at is None or time.monotonic() < done_at):
            try:
                data, addr = sock.recvfrom(256)
            except socket.timeout:
                continue
            if data.strip() != REQUEST:
                continue
            if hub and addr[0] != hub:
                print(f"Ignoring a request from {addr[0]} (not the hub).")
                continue
            sock.sendto(reply, addr)
            sent += 1
            print(f"Sent {len(units)} ventilator(s) to the hub at {addr[0]}.")
            # Stay a little longer for the hub's other requests, then stop.
            done_at = time.monotonic() + 20
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()

    if sent:
        print("Done. The ventilators appear in the SmartThings app within a minute.")
    else:
        print("The hub never asked. Is the PC on the same network as the hub? "
              "Try Add device -> Scan nearby again while this script runs.")
        sys.exit(1)


if __name__ == "__main__":
    main()
